// Playwright e2e for the browser extension (issue #34 item 2) — drives the
// unpacked browser_ext/ in a REAL Chrome (same flags as the dart harness in
// test/browser_ext/chrome_driver.dart) and asserts the v2 ACs end to end.
//
// Chrome resolution: $CHROME_PATH (CI installs Chrome for Testing there),
// then the usual PATH names. Every spec skips LOUDLY with that reason when
// no binary exists — mirrors the dart suite's loud-failure stance without
// failing machines that only run the dart suites.
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  workers: 1, // every spec spawns its own Chrome; parallel workers fight over CPU
  retries: 0,
  timeout: 240_000, // residency waits on real SW idling + alarm revival
  expect: { timeout: 20_000 },
  globalSetup: './global-setup.ts',
  reporter: 'line',
  use: {
    // headless:false here so Playwright adds no headless flag of its own;
    // the real mode comes from --headless=new below (the only headless mode
    // that loads extensions). The harness in helpers.ts passes the same
    // options explicitly — this block covers any direct chromium.launch.
    launchOptions: {
      headless: false,
      executablePath: process.env.CHROME_PATH || undefined,
      args: [
        '--headless=new',
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--disable-gpu',
      ],
    },
  },
  projects: [{ name: 'chromium' }],
});
