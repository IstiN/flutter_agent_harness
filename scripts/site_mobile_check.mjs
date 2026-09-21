#!/usr/bin/env node
// Site mobile E2E (gh-756): fa1.dev must be fully usable at 360px.
//
// Asserts, in a real headless Chromium (Playwright, pinned 1.49.1 — the same
// pin the Pages workflow uses for the boot smoke):
//   AC1/AC4  every inventory page has documentElement.scrollWidth <= innerWidth
//            at 360x640, 390x844, 768x1024, 641x800 and 1280x800 (desktop);
//   AC2      header collapses into a disclosure menu: tap/Esc open-close,
//            aria-expanded/aria-controls, every header link reachable, sticky
//            bar height constant while open, Esc (not backdrop tap) refocuses;
//   AC3      every header anchor jump lands with the section heading visible
//            (not under the header) at 360px and at desktop width;
//   AC5/REG  desktop 1280px full-page screenshots byte-compare against the
//            committed goldens in test/site/goldens/site-mobile/ (REG-D1);
//   E2/E3/E5 landscape panel fits, rotate-to-desktop auto-closes,
//            prefers-reduced-motion keeps the menu functional;
//   E6       no-JS degrades to the wrapped-links layout, never a dead button.
//
// Link counts are read from the page, never hard-coded: the header link set
// is content (main added a Blog link in #758 and the leg went red exactly
// because of a stale `=== 10`). The floor of 10 is the ticket's stated
// inventory; a cross-mode equality (menu vs wrapped) catches vanished links.
//
// Serves site/ with a plain `python3 -m http.server` fixture — the no-server
// static case. Viewport screenshots land in $SHOTS_DIR (CI artifact) when set.
//
// Usage:
//   node scripts/site_mobile_check.mjs            (CI: npm i playwright@1.49.1 + install chromium)
//   CHROMIUM_PATH=/usr/bin/chromium node scripts/site_mobile_check.mjs   (system browser)
//   node scripts/site_mobile_check.mjs --update-goldens                  (re-bake AC5 goldens,
//     same convention as `flutter test --update-goldens` for the store shots)
//     ⚠️ bake ONLY with the pinned Playwright Chromium (no CHROMIUM_PATH):
//     CI byte-compares against that browser; system-Chromium goldens fail.
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  ({ chromium } = require('playwright-core'));
}

const UPDATE_GOLDENS = process.argv.includes('--update-goldens');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const GOLDENS = path.join(root, 'test', 'site', 'goldens', 'site-mobile');
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
// The menu collapse breakpoint is 960px (measured: the 11-link row fits
// from ~945px). Keep this in sync with site/styles.css.
const MENU_MAX_WIDTH = 960;

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

// Wait for the smooth scroll started by an anchor click to come to rest —
// removes the fixed-sleep flake class on loaded CI runners.
async function waitScrollSettled(page, budgetMs = 2500) {
  let last = -1;
  let same = 0;
  const t0 = Date.now();
  while (Date.now() - t0 < budgetMs) {
    const y = await page.evaluate(() => Math.round(window.scrollY));
    if (y === last) {
      same++;
      if (same >= 2) return;
    } else {
      same = 0;
    }
    last = y;
    await page.waitForTimeout(100);
  }
}

// python3 -m http.server readiness poll — a fixed sleep raced the port bind
// on loaded runners and failed the whole leg with a navigation error.
async function waitReady(port, budgetMs = 5000) {
  const t0 = Date.now();
  while (Date.now() - t0 < budgetMs) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/index.html`);
      if (r.ok) return true;
    } catch { /* not bound yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

// Preferred port first; if it is taken (stale server on a dev box), fall
// back to an OS-assigned port parsed from http.server's own banner.
async function startServer() {
  const candidates = [Number(process.env.SITE_CHECK_PORT || 8937), 0];
  for (const port of candidates) {
    const proc = spawn(
      'python3', ['-m', 'http.server', String(port), '--bind', '127.0.0.1'],
      { cwd: path.join(root, 'site'), stdio: ['ignore', 'ignore', 'pipe'] },
    );
    let bound = port;
    if (!bound) {
      bound = await new Promise((resolve) => {
        let buf = '';
        const onData = (d) => {
          if (bound) return; // banner seen — handler is detached below anyway
          buf += String(d);
          const m = buf.match(/http:\/\/127\.0\.0\.1:(\d+)/);
          if (m) {
            bound = Number(m[1]);
            resolve(bound);
          }
        };
        proc.stderr.on('data', onData);
        setTimeout(() => resolve(0), 3000);
      });
    }
    // Drain from here on (port-0 mode detaches the banner parser first):
    // http.server logs every request to stderr — an unread pipe fills
    // (~64KB), blocks the server's writes and times out all pages.
    proc.stderr.removeAllListeners('data');
    proc.stderr.resume();
    if (bound && await waitReady(bound)) return { proc, base: `http://127.0.0.1:${bound}` };
    try { proc.kill(); } catch { /* already gone */ }
  }
  throw new Error('static site server failed to start');
}

async function main() {
  const { proc: server, base: BASE } = await startServer();
  const cleanup = () => { try { server.kill(); } catch { /* already gone */ } };
  process.on('exit', cleanup);

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

  // ── AC2: disclosure menu — tap/Esc, a11y, all links, constant bar height ─
  let menuLinkCount = 0;
  console.log('AC2 — header disclosure menu');
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    // Collapsed menu mode also covers the 641-960 band: the link row only
    // fits from ~945px (measured), so 768 renders the burger too.
    for (const [w, h] of [[360, 640], [390, 844], [768, 1024]]) {
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
      // Every header link must be reachable; count is content-driven
      // (>= 10 = the ticket's stated inventory: 8 sections + 2 external),
      // so adding a nav link on main cannot go red again.
      const linkInfos = await page.$$eval('#nav-menu a', (as) =>
        as.map((a) => ({ href: a.getAttribute('href') || '', vis: a.offsetParent !== null })));
      menuLinkCount = linkInfos.length;
      ok(`@${w} all header links reachable (found ${menuLinkCount})`,
        menuLinkCount >= 10 &&
        linkInfos.every((l) => l.href.length > 0 && l.vis));
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

      // Esc closes and returns focus to the toggle (keyboard dismissal).
      await page.keyboard.press('Escape');
      await page.waitForTimeout(120);
      ok(`@${w} Esc closes`, (await toggle.getAttribute('aria-expanded')) === 'false');
      ok(`@${w} Esc returns focus to toggle`,
        await page.evaluate(() => document.activeElement === document.querySelector('.nav-toggle')));

      // Backdrop (click outside the header) closes — pointer dismissal must
      // NOT yank focus to the toggle (touch users never asked for it).
      await toggle.click();
      await page.waitForTimeout(120);
      await page.mouse.click(Math.round(w / 2), h - 40);
      await page.waitForTimeout(120);
      ok(`@${w} backdrop closes`, (await toggle.getAttribute('aria-expanded')) === 'false');
      ok(`@${w} backdrop leaves focus alone`,
        await page.evaluate(() => document.activeElement !== document.querySelector('.nav-toggle')));

      // Tapping a menu link closes the menu and lands on the section.
      await toggle.click();
      await page.waitForTimeout(120);
      await page.locator('#nav-menu a[href="#faq"]').click();
      await waitScrollSettled(page);
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

    // E6: no-JS — wrapped links stay, never a dead button. Checked at 360px
    // AND in the 641-960 band (the no-JS wrap guard spans the whole
    // collapse range; the mid-width row would otherwise overflow there).
    const ctxN = await browser.newContext({ javaScriptEnabled: false });
    const pageN = await ctxN.newPage();
    for (const [w, h] of [[360, 640], [768, 1024]]) {
      await pageN.setViewportSize({ width: w, height: h });
      await pageN.goto(`${BASE}/index.html`, { waitUntil: 'load' });
      ok(`E6 no-JS @${w}: no visible toggle`, !(await pageN.locator('.nav-toggle').isVisible()));
      const wrapped = await pageN.$$eval('.nav-links a, .nav-ext a', (as) =>
        as.map((a) => ({ vis: a.offsetParent !== null, w: Math.round(a.getBoundingClientRect().width) })));
      ok(`E6 no-JS @${w}: all ${wrapped.length} links visible (wrapped)`,
        wrapped.length === menuLinkCount && wrapped.length >= 10 &&
        wrapped.every((l) => l.vis && l.w > 0));
      const noscroll = await pageN.evaluate(() =>
        document.documentElement.scrollWidth <= window.innerWidth);
      ok(`E6 no-JS @${w}: no horizontal page scroll`, noscroll);
    }
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
        const collapsed = w <= MENU_MAX_WIDTH; // menu collapse breakpoint (measured: 960px)
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
        await waitScrollSettled(page);
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

  // ── AC5/REG-D1: desktop goldens byte-compare ─────────────────────────────
  // Full-page 1280px captures of index/privacy against committed goldens.
  // Animations neutralized (reduced-motion context: the site renders the
  // terminal reel statically, reveals render visible, the caret is frozen).
  // Goldens are only valid for the PINNED Playwright Chromium CI runs —
  // system-Chromium captures rasterize the font stacks differently; baking
  // under CHROMIUM_PATH is refused above.
  if (process.env.CHROMIUM_PATH) {
    console.log('  note CHROMIUM_PATH set — golden byte-compares are only guaranteed '
      + 'against the pinned Playwright Chromium; expect REG diffs here.');
  }
  console.log('AC5/REG-D1 — desktop screenshot goldens');
  {
    for (const p of ['index.html', 'privacy.html']) {
      const goldenPath = path.join(GOLDENS, `${p.replace(/[/.]/g, '_')}.png`);
      const ctx = await browser.newContext({ reducedMotion: 'reduce' });
      const page = await ctx.newPage();
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.goto(`${BASE}/${p}`, { waitUntil: 'load' });
      await page.waitForTimeout(500);
      const actual = await page.screenshot({ fullPage: true, animations: 'disabled' });
      await ctx.close();
      if (UPDATE_GOLDENS) {
        if (process.env.CHROMIUM_PATH) {
          console.error(
            'REFUSING to re-bake goldens under CHROMIUM_PATH: CI byte-compares\n' +
            'against the pinned Playwright Chromium (no CHROMIUM_PATH). System\n' +
            'Chromium rasterizes the site\'s system font stacks differently and\n' +
            'would bake goldens that fail the leg. Install the pinned browser\n' +
            '(`npm i playwright@1.49.1 && npx playwright install chromium`) and\n' +
            're-run --update-goldens without CHROMIUM_PATH.');
          process.exit(2);
        }
        mkdirSync(GOLDENS, { recursive: true });
        writeFileSync(goldenPath, actual);
        console.log(`  ok   golden re-baked: ${path.relative(root, goldenPath)} (${actual.length} bytes)`);
        checks++;
        continue;
      }
      let expected;
      try {
        expected = readFileSync(goldenPath);
      } catch {
        ok(`${p} desktop golden byte-compare`, false,
          `golden missing: ${path.relative(root, goldenPath)} — re-bake with --update-goldens`);
        continue;
      }
      const same = expected.equals(actual);
      if (!same && SHOTS) {
        mkdirSync(SHOTS, { recursive: true });
        writeFileSync(path.join(SHOTS, `REG-${p.replace(/\//g, '_')}@1280x800.png`), actual);
      }
      ok(`${p} desktop golden byte-compare (${expected.length} bytes)`, same,
        same ? '' : `differs from ${path.relative(root, goldenPath)} — if the desktop change is intended, re-bake with --update-goldens (pinned Playwright Chromium, NO CHROMIUM_PATH)`);
    }
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
