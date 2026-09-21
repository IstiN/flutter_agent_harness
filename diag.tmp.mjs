import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
import { spawn } from 'node:child_process';
const server = spawn('python3', ['-m', 'http.server', '8932', '--bind', '127.0.0.1'], { cwd: 'site', stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const page = await browser.newPage();
for (const p of ['index.html', 'privacy.html']) {
  await page.goto('http://127.0.0.1:8932/' + p, { waitUntil: 'load' });
  await page.setViewportSize({ width: 360, height: 640 });
  await page.waitForTimeout(300);
  const wide = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll('*').forEach(el => {
      const r = el.getBoundingClientRect();
      if (r.width > window.innerWidth + 1 && r.height > 0) {
        out.push(`${el.tagName}.${String(el.className).split(' ')[0]} w=${Math.round(r.width)} left=${Math.round(r.left)}`);
      }
    });
    return out.slice(0, 20);
  });
  console.log('==', p);
  wide.forEach(w => console.log('  ', w));
}
await browser.close(); server.kill();
