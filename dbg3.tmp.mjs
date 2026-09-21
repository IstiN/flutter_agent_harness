import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
import { spawn } from 'node:child_process';
const server = spawn('python3', ['-m', 'http.server', '8936', '--bind', '127.0.0.1'], { cwd: 'site', stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const page = await browser.newPage();
for (const w of [641, 700, 768, 800, 844, 900, 960]) {
  await page.setViewportSize({ width: w, height: 800 });
  await page.goto('http://127.0.0.1:8936/index.html', { waitUntil: 'load' });
  await page.waitForTimeout(150);
  console.log(w, await page.evaluate(() => {
    const ext = document.querySelector('.nav-ext');
    const r = ext.getBoundingClientRect();
    const lastA = ext.querySelector('a:last-child').getBoundingClientRect();
    return `ext x=${Math.round(r.x)} right=${Math.round(lastA.right)} navH=${Math.round(document.querySelector('.nav').getBoundingClientRect().height)} scrollW=${document.documentElement.scrollWidth}`;
  }));
}
await browser.close(); server.kill();
