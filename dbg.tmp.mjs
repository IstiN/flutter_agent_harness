import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
import { spawn } from 'node:child_process';
const server = spawn('python3', ['-m', 'http.server', '8934', '--bind', '127.0.0.1'], { cwd: 'site', stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const page = await browser.newPage();
await page.setViewportSize({ width: 360, height: 640 });
await page.goto('http://127.0.0.1:8934/index.html', { waitUntil: 'load' });
await page.waitForTimeout(200);
await page.locator('.nav-toggle').click();
await page.waitForTimeout(100);
console.log('after open, activeElement:', await page.evaluate(() => document.activeElement && document.activeElement.className));
await page.keyboard.press('Escape');
await page.waitForTimeout(100);
console.log('after Esc, activeElement:', await page.evaluate(() => document.activeElement && (document.activeElement.className || document.activeElement.tagName)));
console.log('data-open still present:', await page.evaluate(() => document.querySelector('.nav').hasAttribute('data-open')));
// bar heights across widths
for (const w of [360, 390, 641, 700, 768, 844, 891, 960, 1280]) {
  await page.setViewportSize({ width: w, height: 800 });
  await page.waitForTimeout(150);
  const info = await page.evaluate(() => {
    const nav = document.querySelector('.nav');
    const inner = document.querySelector('.nav-inner');
    const links = document.querySelector('.nav-links');
    const r = links.getBoundingClientRect();
    return { navH: Math.round(nav.getBoundingClientRect().height * 10) / 10,
             innerH: Math.round(inner.getBoundingClientRect().height * 10) / 10,
             linksTop: Math.round(r.top), linksBottom: Math.round(r.bottom),
             scrollW: document.documentElement.scrollWidth, iw: window.innerWidth };
  });
  console.log(w, JSON.stringify(info));
}
await browser.close(); server.kill();
