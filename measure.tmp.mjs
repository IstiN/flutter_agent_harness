import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
import { spawn } from 'node:child_process';

const server = spawn('python3', ['-m', 'http.server', '8931', '--bind', '127.0.0.1'], { cwd: 'site', stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const page = await browser.newPage();
await page.goto('http://127.0.0.1:8931/index.html', { waitUntil: 'load' });
// binary-search the min viewport width where .nav-inner content fits without overflow
let lo = 360, hi = 1400;
for (let i = 0; i < 12; i++) {
  const mid = (lo + hi) / 2;
  await page.setViewportSize({ width: Math.round(mid), height: 800 });
  const overflow = await page.evaluate(() => {
    const inner = document.querySelector('.nav-inner');
    return inner.scrollWidth > inner.clientWidth + 1;
  });
  if (overflow) lo = mid; else hi = mid;
}
console.log('nav row needs >=', Math.round(hi), 'px (first width without overflow)');
// header heights
await page.setViewportSize({ width: 1280, height: 800 });
console.log('header height @1280:', await page.evaluate(() => document.querySelector('.nav').getBoundingClientRect().height));
await page.setViewportSize({ width: 360, height: 640 });
await page.waitForTimeout(100);
console.log('header height @360 (wrapped):', await page.evaluate(() => document.querySelector('.nav').getBoundingClientRect().height));
// page-level horizontal scroll check at 360 for all inventory pages
const pages = ['index.html','privacy.html','app-store/index.html','widgets/index.html','oauth/openrouter.html','oauth/openrouter-native.html','oauth/aiin.html'];
for (const p of pages) {
  await page.goto('http://127.0.0.1:8931/' + p, { waitUntil: 'load' });
  await page.setViewportSize({ width: 360, height: 640 });
  await page.waitForTimeout(200);
  const r = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: window.innerWidth }));
  console.log(p, r.sw <= r.iw ? 'OK' : `SCROLL overflow sw=${r.sw} iw=${r.iw}`);
}
// anchor occlusion check @360
await page.goto('http://127.0.0.1:8931/index.html', { waitUntil: 'load' });
await page.setViewportSize({ width: 360, height: 640 });
await page.waitForTimeout(300);
const links = await page.$$eval('.nav-links a[href^="#"]', as => as.map(a => a.getAttribute('href')));
for (const href of links) {
  await page.click(`.nav-links a[href="${href}"]`);
  await page.waitForTimeout(900); // smooth scroll
  const vis = await page.evaluate((h) => {
    const sec = document.querySelector(h);
    if (!sec) return 'missing';
    const head = sec.querySelector('h1,h2') || sec;
    const r = head.getBoundingClientRect();
    const navH = document.querySelector('.nav').getBoundingClientRect().height;
    return { top: Math.round(r.top), navH: Math.round(navH), occluded: r.top < navH - 2 };
  }, href);
  console.log(href, JSON.stringify(vis));
}
await browser.close();
server.kill();
