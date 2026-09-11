// Playwright e2e for the Outlook taskpane (issue #89 black-box slice): the
// COMPILED build/pages/root/outlook artifact served statically; Office.js is
// mocked via addInitScript BEFORE any page script. Chromium + WebKit — the
// engines Outlook taskpanes realistically run on (WebView2 / WKWebView).
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  workers: 1, // one shared static server + real browsers; parallel workers fight over CPU
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: 'line',
  webServer: {
    command:
      'python3 -m http.server 8799 --bind 127.0.0.1 --directory ../../build/pages/root/outlook',
    port: 8799,
    reuseExistingServer: true,
    timeout: 30_000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: { args: ['--no-sandbox', '--disable-dev-shm-usage'] },
      },
    },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
});
