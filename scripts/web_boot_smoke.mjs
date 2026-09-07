#!/usr/bin/env node
// Web boot smoke: the Flutter demo must mount and run Dart main() with a
// clean console. Guards the fa1.dev deploy (Pages) against the whole class
// of "site loads but the app dies at boot" regressions — e.g. a JS-interop
// probe throwing a null-check inside the extension detection, which shipped
// once and killed every fresh visitor while all Dart tests stayed green.
//
// Usage:
//   node scripts/web_boot_smoke.mjs [app-url]
//   (default http://127.0.0.1:8788/app/ — the Pages artifact's demo path)
// Prereqs (CI steps do this): `npm i --no-save playwright` plus
// `npx playwright install chromium` (add --with-deps on a bare runner).
//
// Pass criteria, all required:
//   1. no page errors and no console.error messages during boot;
//   2. the Flutter view mounts (flutter-view / flt-glass-pane present);
//   3. the app's own boot log line "[fah] starting runApp" appears —
//      Dart main() actually ran, not just HTML loading.
import { chromium } from 'playwright';

const url = process.argv[2] ?? 'http://127.0.0.1:8788/app/';
const errors = [];
const bootLog = [];

const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  page.on('console', (m) => {
    const text = m.text();
    if (m.type() === 'error') errors.push(`console.error: ${text}`);
    if (text.includes('[fah]')) bootLog.push(text);
  });

  try {
    await page.goto(url, { waitUntil: 'load', timeout: 60_000 });
    await page.waitForSelector('flutter-view, flt-glass-pane', {
      state: 'attached',
      timeout: 60_000,
    });
  } catch (e) {
    errors.push(`flutter view never mounted: ${e.message.split('\n')[0]}`);
  }
  // Let async boot steps (WASM runtime, stores, runApp) land; boot-time
  // errors tend to surface within seconds of the first frame.
  await page.waitForTimeout(10_000);

  const problems = [];
  if (errors.length > 0) {
    problems.push(`console/page errors during boot:\n  ${errors.join('\n  ')}`);
  }
  if (!bootLog.some((t) => t.includes('starting runApp'))) {
    problems.push(
      'Dart main() did not run: no "[fah] starting runApp" boot log. '
        + `Captured boot log:\n  ${bootLog.join('\n  ') || '(none)'}`,
    );
  }
  if (problems.length > 0) {
    console.error(`WEB BOOT SMOKE FAILED (${url})\n${problems.join('\n')}`);
    process.exit(1);
  }
  console.log(
    `web boot smoke passed (${url}): flutter view mounted, `
      + `${bootLog.length} boot log lines, 0 console errors`,
  );
} finally {
  await browser.close();
}
