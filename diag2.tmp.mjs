import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
import { spawn } from 'node:child_process';
const server = spawn('python3', ['-m', 'http.server', '8933', '--bind', '127.0.0.1'], { cwd: 'site', stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const page = await browser.newPage();
await page.setViewportSize({ width: 360, height: 640 });
for (const p of ['index.html', 'privacy.html']) {
  await page.goto('http://127.0.0.1:8933/' + p, { waitUntil: 'load' });
  await page.waitForTimeout(300);
  const culprits = await page.evaluate(() => {
    function clippedByAncestor(el) {
      let a = el.parentElement;
      while (a) {
        const o = getComputedStyle(a).overflowX;
        if (o === 'auto' || o === 'hidden' || o === 'scroll' || o === 'clip') return true;
        a = a.parentElement;
      }
      return false;
    }
    const out = [];
    document.querySelectorAll('body *').forEach(el => {
      const r = el.getBoundingClientRect();
      if (r.right > window.innerWidth + 1 && r.width > 0 && !clippedByAncestor(el)) {
        out.push(`${el.tagName}.${el.className} right=${Math.round(r.right)} text=${(el.textContent||'').trim().slice(0,60)}`);
      }
    });
    return out.slice(0, 15);
  });
  console.log('==', p);
  culprits.forEach(c => console.log('  ', c));
}
await browser.close(); server.kill();
