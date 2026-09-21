#!/usr/bin/env node
// Site mobile E2E (gh-756): fa1.dev must be fully usable at 360px.
//
// Asserts, in a real headless Chromium (Playwright, pinned 1.49.1 — the same
// pin the Pages workflow uses for the boot smoke):
//   AC1/AC4  every inventory page has documentElement.scrollWidth <= innerWidth
//            at 360x640, 390x844, 768x1024, 641x800 and 1280x800 (desktop);
//   AC2      header collapses into a disclosure menu: tap/Esc open-close,
//            aria-expanded/aria-controls, all 10 links reachable, sticky bar
//            height constant while open;
//   AC3      every header anchor jump lands with the section heading visible
//            (not under the header) at 360px and at desktop width;
//   E2/E3/E5 landscape panel fits, rotate-to-desktop auto-closes,
//            prefers-reduced-motion keeps the menu functional;
//   E6       no-JS degrades to the wrapped-links layout, never a dead button.
//
// Serves site/ with a plain `python3 -m http.server` fixture — the no-server
// static case. Screenshot goldens land in $SHOTS_DIR (CI artifact) when set.
//
// Usage:
//   node scripts/site_mobile_check.mjs            (CI: npm i playwright@1.49.1 + install chromium)
//   CHROMIUM_PATH=/usr/bin/chromium node scripts/site_mobile_check.mjs   (system browser)
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  ({ chromium } = require('playwright-core'));
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.SITE_CHECK_PORT || 8937);
const BASE = `http://127.0.0.1:${PORT}`;
const SHOTS = process.env.SHOTS_DIR || '';
const PAGES = [
  'index.html',
  'privacy.html',
  'app-store/index.html',
  'widgets/index.html',
  'oauth/openrouter.html',
  'oauth/openrouter-native.html',
  'oauth/aiin.html',
];
const VIEWPORTS = [
  [360, 640],
  [390, 844],
  [768, 1024],
  [641, 800],
  [1280, 800],
];

let failures = 0;
let checks = 0;
function ok(name, cond, detail = '') {
  checks++;
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

async function shot(page, name) {
  if (!SHOTS) return;
  mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: path.join(SHOTS, `${name}.png`), fullPage: false });
}

async function launch() {
  const executablePath = process.env.CHROMIUM_PATH || undefined;
  return chromium.launch({
    executablePath,
    args: ['--no-sandbox'],
  });
}

async function main() {
  const server = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1'], {
    cwd: path.join(root, 'site'),
    stdio: 'ignore',
  });
  const cleanup = () => { try { server.kill(); } catch { /* already gone */ } };
  process.on('exit', cleanup);
  await new Promise((r) => setTimeout(r, 900));

  const browser = await launch();

  // ── AC1/AC4: zero horizontal page scroll, every page, every viewport ────
  console.log('AC1/AC4 — horizontal page scroll guard');
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    for (const [w, h] of VIEWPORTS) {
      await page.setViewportSize({ width: w, height: h });
      for (const p of PAGES) {
        await page.goto(`${BASE}/${p}`, { waitUntil: 'load' });
        await page.waitForTimeout(w <= 390 ? 250 : 100);
        const m = await page.evaluate(() => ({
          sw: document.documentElement.scrollWidth,
          iw: window.innerWidth,
        }));
        ok(`${p} @${w}x${h} scrollWidth<=innerWidth`, m.sw <= m.iw,
          `scrollWidth=${m.sw} innerWidth=${m.iw}`);
        await shot(page, `${p.replace(/\//g, '_')}@${w}x${h}`);
      }
    }
    await ctx.close();
  }

  // ── AC2: disclosure menu — tap/Esc, a11y, 10 links, constant bar height ──
  console.log('AC2 — header disclosure menu');
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    for (const [w, h] of [[360, 640], [390, 844]]) {
      await page.setViewportSize({ width: w, height: h });
      await page.goto(`${BASE}/index.html`, { waitUntil: 'load' });
      await page.waitForTimeout(200);

      const toggle = page.locator('.nav-toggle');
      const toggleThere = await toggle.count() > 0;
      ok(`@${w} menu toggle visible`, toggleThere && await toggle.isVisible());
      if (!toggleThere) continue; // regression: report and move to the next viewport
      ok(`@${w} toggle starts closed`, (await toggle.getAttribute('aria-expanded')) === 'false');
      ok(`@${w} aria-controls points at menu`,
        (await toggle.getAttribute('aria-controls')) === 'nav-menu');

      const barBefore = await page.evaluate(() =>
        Math.round(document.querySelector('.nav').getBoundingClientRect().height));

      await toggle.click();
      await page.waitForTimeout(120);
      ok(`@${w} tap opens (aria-expanded)`, (await toggle.getAttribute('aria-expanded')) === 'true');
      const barOpen = await page.evaluate(() =>
        Math.round(document.querySelector('.nav').getBoundingClientRect().height));
      ok(`@${w} sticky bar height constant while open`, barOpen === barBefore,
        `${barBefore} -> ${barOpen}`);
      const links = page.locator('#nav-menu a');
      ok(`@${w} all 10 links reachable`, (await links.count()) === 10 &&
        (await links.first().isVisible()) && (await links.last().isVisible()));
      await shot(page, `menu-open@${w}x${h}`);

      // Landscape guard (E2): panel must not eat the viewport.
      await page.setViewportSize({ width: 844, height: 390 });
      await page.waitForTimeout(120);
      const panelFits = await page.evaluate(() => {
        const menu = document.getElementById('nav-menu');
        const r = menu.getBoundingClientRect();
        return r.height <= window.innerHeight;
      });
      ok(`@844x390 landscape panel fits viewport`, panelFits);
      const barLand = await page.evaluate(() =>
        Math.round(document.querySelector('.nav').getBoundingClientRect().height));
      ok(`@844x390 sticky bar height constant`, barLand === barBefore, `${barBefore} -> ${barLand}`);
      await page.setViewportSize({ width: w, height: h });
      await page.waitForTimeout(120);

      // Esc closes and returns focus to the toggle.
      await page.keyboard.press('Escape');
      await page.waitForTimeout(120);
      ok(`@${w} Esc closes`, (await toggle.getAttribute('aria-expanded')) === 'false');
      ok(`@${w} Esc returns focus to toggle`,
        await page.evaluate(() => document.activeElement === document.querySelector('.nav-toggle')));

      // Backdrop (click outside the header) closes.
      await toggle.click();
      await page.waitForTimeout(120);
      await page.mouse.click(Math.round(w / 2), h - 40);
      await page.waitForTimeout(120);
      ok(`@${w} backdrop closes`, (await toggle.getAttribute('aria-expanded')) === 'false');

      // Tapping a menu link closes the menu and lands on the section.
      await toggle.click();
      await page.waitForTimeout(120);
      await page.locator('#nav-menu a[href="#faq"]').click();
      await page.waitForTimeout(900); // smooth scroll
      ok(`@${w} link tap closes menu`, (await toggle.getAttribute('aria-expanded')) === 'false');
      ok(`@${w} link tap navigates`, page.url().includes('#faq'));

      // E3: rotate to desktop width while open → auto-close, no stale overlay.
      await toggle.click();
      await page.waitForTimeout(120);
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.waitForTimeout(150);
      ok(`@${w}→1280 rotate auto-closes`, (await toggle.getAttribute('aria-expanded')) === 'false');
      ok(`@${w}→1280 toggle hidden on desktop`, !(await toggle.isVisible()));
      ok(`@${w}→1280 links inline on desktop`,
        await page.evaluate(() => {
          const r = document.querySelector('.nav-links a').getBoundingClientRect();
          return r.top < 60 && r.height > 0; // inside the one-row bar
        }));
    }
    await ctx.close();

    // E5: prefers-reduced-motion — menu still opens/closes instantly.
    const ctxR = await browser.newContext({ reducedMotion: 'reduce' });
    const pageR = await ctxR.newPage();
    await pageR.setViewportSize({ width: 360, height: 640 });
    await pageR.goto(`${BASE}/index.html`, { waitUntil: 'load' });
    const rToggle = pageR.locator('.nav-toggle');
    if (await rToggle.count() === 0) {
      ok('E5 reduced-motion: menu opens', false, 'no .nav-toggle in DOM');
    } else {
      await rToggle.click();
      await pageR.waitForTimeout(80);
      ok('E5 reduced-motion: menu opens', (await rToggle.getAttribute('aria-expanded')) === 'true');
      await pageR.keyboard.press('Escape');
      await pageR.waitForTimeout(80);
      ok('E5 reduced-motion: Esc closes', (await rToggle.getAttribute('aria-expanded')) === 'false');
    }
    await ctxR.close();

    // E6: no-JS — wrapped links stay, never a dead button.
    const ctxN = await browser.newContext({ javaScriptEnabled: false });
    const pageN = await ctxN.newPage();
    await pageN.setViewportSize({ width: 360, height: 640 });
    await pageN.goto(`${BASE}/index.html`, { waitUntil: 'load' });
    ok('E6 no-JS: no visible toggle', !(await pageN.locator('.nav-toggle').isVisible()));
    ok('E6 no-JS: all 10 links visible (wrapped)',
      (await pageN.locator('.nav-links a').count()) === 8 &&
      (await pageN.locator('.nav-ext a').count()) === 2 &&
      (await pageN.locator('.nav-links a').first().isVisible()));
    const noscroll = await pageN.evaluate(() =>
      document.documentElement.scrollWidth <= window.innerWidth);
    ok('E6 no-JS: no horizontal page scroll', noscroll);
    await ctxN.close();
  }

  // ── AC3: anchors land with the heading visible, not under the header ─────
  console.log('AC3 — anchor occlusion');
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    for (const [w, h] of [[360, 640], [1280, 800]]) {
      await page.setViewportSize({ width: w, height: h });
      await page.goto(`${BASE}/index.html`, { waitUntil: 'load' });
      await page.waitForTimeout(200);
      const hrefs = await page.$$eval('#nav-menu a[href^="#"]', (as) =>
        as.map((a) => a.getAttribute('href')));
      for (const href of hrefs) {
        await page.evaluate(() => window.scrollTo(0, 0));
        const collapsed = w < 641; // menu breakpoint (measured: row fits above 640)
        if (collapsed) {
          // Close the menu first if a previous iteration left it open.
          if ((await page.locator('.nav-toggle').getAttribute('aria-expanded')) === 'true') {
            await page.keyboard.press('Escape');
            await page.waitForTimeout(100);
          }
          await page.locator('.nav-toggle').click();
          await page.waitForTimeout(120);
          await page.locator(`#nav-menu a[href="${href}"]`).click();
        } else {
          await page.click(`.nav-links a[href="${href}"]`);
        }
        await page.waitForTimeout(w < 640 ? 1100 : 900); // smooth scroll
        const r = await page.evaluate((sel) => {
          const sec = document.querySelector(sel);
          const head = sec.querySelector('h1,h2') || sec;
          const b = head.getBoundingClientRect();
          const nav = document.querySelector('.nav').getBoundingClientRect();
          return { top: Math.round(b.top), navBottom: Math.round(nav.bottom) };
        }, href);
        ok(`${href} @${w} heading below header`, r.top >= r.navBottom - 1,
          `top=${r.top} navBottom=${r.navBottom}`);
      }
    }
    await ctx.close();
  }

  await browser.close();
  cleanup();

  console.log(`\n${checks - failures}/${checks} checks passed`);
  if (failures) {
    console.error(`SITE MOBILE CHECK FAILED — ${failures} failure(s)`);
    process.exit(1);
  }
  console.log('site mobile check passed');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
