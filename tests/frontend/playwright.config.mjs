// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.mjs",

  timeout: 30_000,
  expect: {
    timeout: 10_000,
  },

  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,

  reporter: process.env.CI
    ? [
        ["list"],
        [
          "html",
          {
            outputFolder: "playwright-report",
            open: "never",
          },
        ],
      ]
    : "list",

  use: {
    baseURL: "http://127.0.0.1:4173",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },

  webServer: {
    command: "python3 -m http.server 4173 --directory ../../dist",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: !process.env.CI,
    timeout: 15_000,
  },
});

// EOF
