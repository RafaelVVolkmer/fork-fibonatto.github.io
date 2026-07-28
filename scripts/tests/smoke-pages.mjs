// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

import { chromium } from "playwright";

const baseUrl = process.argv[2];
if (!baseUrl) {
  throw new Error("Usage: node smoke-pages.mjs URL");
}

const origin = new URL(baseUrl);
const response = await fetch(origin, { redirect: "follow" });
if (!response.ok) {
  throw new Error(`GitHub Pages returned HTTP ${response.status}`);
}

const html = await response.text();
if (/\{\{[A-Z_]+\}\}/u.test(html)) {
  throw new Error("Published HTML still contains template placeholders");
}

const scriptMatch = html.match(/assets\/app\/app\.[0-9a-f]+\.js/u);
if (!scriptMatch) {
  throw new Error("Published HTML does not reference the hashed JavaScript asset");
}

const scriptUrl = new URL(scriptMatch[0], response.url);
const scriptResponse = await fetch(scriptUrl);
if (!scriptResponse.ok) {
  throw new Error(`JavaScript asset returned HTTP ${scriptResponse.status}`);
}
const script = await scriptResponse.text();

const wasmMatch = script.match(/app\.[0-9a-f]+\.wasm/u);
if (!wasmMatch) {
  throw new Error("Published JavaScript does not reference the hashed WASM asset");
}

const wasmUrl = new URL(`assets/app/${wasmMatch[0]}`, response.url);
const wasmResponse = await fetch(wasmUrl);
if (!wasmResponse.ok) {
  throw new Error(`WebAssembly asset returned HTTP ${wasmResponse.status}`);
}
const wasmBytes = new Uint8Array(await wasmResponse.arrayBuffer());
const expectedMagic = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
if (!expectedMagic.every((byte, index) => wasmBytes[index] === byte)) {
  throw new Error("Published WebAssembly asset has an invalid header");
}

const metadataChecks = [
  [".metadata/cosign.status.json", "subject", "release.sha256"],
  [".metadata/sbom.spdx.json", "spdxVersion", "SPDX-"],
  [".metadata/sbom.cyclonedx.json", "bomFormat", "CycloneDX"],
];

for (const [path, property, expected] of metadataChecks) {
  const metadataUrl = new URL(path, response.url);
  const metadataResponse = await fetch(metadataUrl);
  if (!metadataResponse.ok) {
    throw new Error(`${path} returned HTTP ${metadataResponse.status}`);
  }

  const metadata = await metadataResponse.json();
  if (!String(metadata[property]).startsWith(expected)) {
    throw new Error(`${path} does not contain a valid ${property}`);
  }
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
const pageErrors = [];
page.on("pageerror", (error) => pageErrors.push(error.message));

await page.goto(response.url, { waitUntil: "networkidle", timeout: 60_000 });
await page.waitForFunction(() => document.body.textContent?.trim().length > 0, null, {
  timeout: 30_000,
});

await page.goto(new URL("#/blog", response.url).href, {
  waitUntil: "networkidle",
  timeout: 60_000,
});
await page.waitForFunction(() => window.location.hash === "#/blog", null, {
  timeout: 10_000,
});

if (pageErrors.length > 0) {
  throw new Error(`Browser page errors: ${pageErrors.join(" | ")}`);
}

await browser.close();
console.log(`GitHub Pages smoke test passed: ${response.url}`);
