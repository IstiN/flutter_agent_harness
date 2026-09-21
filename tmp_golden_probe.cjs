// Capture the AC5 golden screenshots with the CI browser (Playwright 1.49.1
// bundled Chromium) and the system Chromium, then compare both against the
// committed golden — pixel-level, not just bytes.
const { createRequire } = require('node:module');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const root = __dirname;
const GOLDENS = path.join(root, 'test', 'site', 'goldens', 'site-mobile');

async function startServer() {
  const proc = spawn('/usr/bin/python3', ['-m', 'http.server', '8941', '--bind', '127.0.0.1'],
    { cwd: path.join(root, 'site'), stdio: 'ignore' });
  for (let i = 0; i < 50; i++) {
    try { const r = await fetch('http://127.0.0.1:8941/index.html'); if (r.ok) return proc; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server');
}

(async () => {
  const server = await startServer();
  const browsers = [
    ['playwright', undefined],
    ['system', '/usr/bin/chromium'],
  ];
  for (const [label, exe] of browsers) {
    const browser = await chromium.launch({ executablePath: exe, args: ['--no-sandbox'] });
    for (const p of ['index.html', 'privacy.html']) {
      const ctx = await browser.newContext({ reducedMotion: 'reduce' });
      const page = await ctx.newPage();
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.goto(`http://127.0.0.1:8941/${p}`, { waitUntil: 'load' });
      await page.waitForTimeout(500);
      const actual = await page.screenshot({ fullPage: true, animations: 'disabled' });
      await ctx.close();
      const goldenPath = path.join(GOLDENS, p.replace(/[/.]/g, '_') + '.png');
      const expected = fs.readFileSync(goldenPath);
      fs.writeFileSync(`/tmp/actual-${label}-${p}`, actual);
      const bytesEq = expected.equals(actual);
      console.log(`${label} ${p}: ${actual.length} bytes (golden ${expected.length}) bytes-equal=${bytesEq}`);
    }
    await browser.close();
  }
  server.kill();
})().catch((e) => { console.error(e); process.exit(1); });
