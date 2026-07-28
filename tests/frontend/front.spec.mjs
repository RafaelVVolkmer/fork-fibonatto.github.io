// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

import { expect, test } from "@playwright/test";

function observeBrowser(page) {
  const failures = [];

  page.on("pageerror", (error) => {
    failures.push(`pageerror: ${error.message}`);
  });

  page.on("console", (message) => {
    if (message.type() === "error") {
      failures.push(`console: ${message.text()}`);
    }
  });

  page.on("response", (response) => {
    const url = new URL(response.url());

    if (url.hostname === "127.0.0.1" && response.status() >= 400) {
      failures.push(`HTTP ${response.status()}: ${response.url()}`);
    }
  });

  return failures;
}

test("loads WebAssembly and renders the home page", async ({ page }) => {
  const failures = observeBrowser(page);
  const wasmResponsePromise = page.waitForResponse((response) =>
    /\.wasm(?:$|\?)/u.test(response.url()),
  );

  const response = await page.goto("/");

  expect(response).not.toBeNull();
  expect(response.ok()).toBe(true);

  const wasmResponse = await wasmResponsePromise;
  expect(wasmResponse.ok()).toBe(true);

  await expect(page).toHaveTitle("Bonatto - Home");
  await expect(page.locator("#header-nav")).toBeVisible();
  await expect(page.locator("#feed")).toContainText("About");
  await expect(page.locator("footer[data-site-footer='1']")).toBeVisible();

  await expect(page.locator("#feed .img-placeholder")).toHaveCount(0);
  await expect(page.locator("#feed img")).toHaveCount(1);

  const profileLoaded = await page.locator("#feed img").evaluate(
    (image) => image.complete && image.naturalWidth > 0,
  );

  expect(profileLoaded).toBe(true);
  expect(failures).toEqual([]);
});

test("navigates through the rendered interface", async ({ page }) => {
  const failures = observeBrowser(page);

  await page.goto("/");
  await page.locator("#nav-blog").click();

  await expect(page).toHaveURL(/#\/blog$/u);
  await expect(page).toHaveTitle("Bonatto - Blog");
  await expect(page.locator("#feed")).toContainText("Blog Index");

  const articles = page.locator('#feed a[href^="#/post/"]');
  await expect(articles.first()).toBeVisible();
  expect(await articles.count()).toBeGreaterThan(0);

  await articles.first().click();

  await expect(page).toHaveURL(/#\/post\/.+/u);
  await expect(page.locator("#feed")).not.toBeEmpty();

  await page.goBack();

  await expect(page).toHaveURL(/#\/blog$/u);
  await expect(page.locator("#feed")).toContainText("Blog Index");

  await page.locator("#nav-title").click();

  await expect(page).toHaveURL(/#\/$/u);
  await expect(page).toHaveTitle("Bonatto - Home");
  await expect(page.locator("#feed")).toContainText("About");
  expect(failures).toEqual([]);
});

test("persists the selected theme", async ({ page }) => {
  const failures = observeBrowser(page);

  await page.goto("/");
  await page.evaluate(() => {
    localStorage.removeItem("site-theme");
  });
  await page.reload();

  const toggle = page.locator("#theme-toggle");

  await expect(toggle).toHaveText("dark");
  await expect(page.locator("html")).not.toHaveClass(/dark-theme/u);

  await toggle.click();

  await expect(toggle).toHaveText("light");
  await expect(page.locator("html")).toHaveClass(/dark-theme/u);
  expect(await page.evaluate(() => localStorage.getItem("site-theme"))).toBe(
    "dark",
  );

  await page.reload();

  await expect(page.locator("html")).toHaveClass(/dark-theme/u);
  await expect(page.locator("#theme-toggle")).toHaveText("light");
  expect(failures).toEqual([]);
});

test("renders an invalid route as not found", async ({ page }) => {
  const failures = observeBrowser(page);

  await page.goto("/#/route-that-does-not-exist");

  await expect(page).toHaveTitle("Bonatto - 404");
  await expect(page.locator("#feed")).toContainText("404 - NOT FOUND");
  await expect(page.locator("#feed")).toContainText(
    "The page you are looking for does not exist",
  );
  expect(failures).toEqual([]);
});

test("avoids horizontal overflow on a mobile viewport", async ({ page }) => {
  const failures = observeBrowser(page);

  await page.setViewportSize({
    width: 390,
    height: 844,
  });
  await page.goto("/");
  await expect(page.locator("#feed")).toBeVisible();

  const hasHorizontalOverflow = await page.evaluate(
    () =>
      document.documentElement.scrollWidth >
      document.documentElement.clientWidth,
  );

  expect(hasHorizontalOverflow).toBe(false);

  await page.locator("#nav-blog").click();
  await expect(page.locator("#feed")).toContainText("Blog Index");

  const blogHasHorizontalOverflow = await page.evaluate(
    () =>
      document.documentElement.scrollWidth >
      document.documentElement.clientWidth,
  );

  expect(blogHasHorizontalOverflow).toBe(false);
  expect(failures).toEqual([]);
});

test("updates SEO metadata after navigation", async ({ page }) => {
  const failures = observeBrowser(page);

  await page.goto("/");
  await page.locator("#nav-blog").click();

  await expect(page).toHaveTitle("Bonatto - Blog");
  await expect(page.locator('meta[name="description"]')).toHaveAttribute(
    "content",
    /Blog archive/u,
  );
  await expect(page.locator('meta[property="og:url"]')).toHaveAttribute(
    "content",
    /#\/blog$/u,
  );
  await expect(page.locator('meta[property="og:title"]')).toHaveAttribute(
    "content",
    "Bonatto - Blog",
  );
  expect(failures).toEqual([]);
});

test("navigation controls are semantic and keyboard operable", async ({
  page,
}) => {
  const failures = observeBrowser(page);

  await page.goto("/");

  for (const selector of ["#nav-title", "#nav-blog", "#theme-toggle"]) {
    const element = page.locator(selector);

    await expect(element).toBeVisible();
    expect(await element.evaluate((node) => node.tagName)).toMatch(
      /^(?:A|BUTTON)$/u,
    );
  }

  await page.locator("#nav-blog").focus();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/#\/blog$/u);

  await page.locator("#theme-toggle").focus();
  await page.keyboard.press("Space");
  await expect(page.locator("html")).toHaveClass(/dark-theme/u);
  expect(failures).toEqual([]);
});

test("navigation does not contain empty controls", async ({ page }) => {
  const failures = observeBrowser(page);

  await page.goto("/");

  const controls = page.locator("#nav-right-group > *");
  expect(await controls.count()).toBeGreaterThanOrEqual(2);

  for (const control of await controls.all()) {
    await expect(control).not.toHaveText(/^\s*$/u);
  }
  expect(failures).toEqual([]);
});

// EOF
