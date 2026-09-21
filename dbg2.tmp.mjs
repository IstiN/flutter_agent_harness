import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
import { spawn } from 'node:child_process';
const server = spawn('python3', ['-m', 'http.server', '8935', '--bind', '127.0.0.1'], { cwd: 'site', stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const page = await browser.newPage();
await page.setViewportSize({ width: 768, height: 800 });
await page.goto('http://127.0.0.1:8935/index.html', { waitUntil: 'load' });
await page.waitForTimeout(200);
console.log(await page.evaluate(() => {
  const inner = document.querySelector('.nav-inner');
  const out = [];
  inner.childNodes.forEach(c => {
    if (c.nodeType !== 1) return;
    const r = c.getBoundingClientRect();
    const cs = getComputedStyle(c);
    out.push(`${c.tagName}.${c.className} x=${Math.round(r.x)} w=${Math.round(r.width)} h=${Math.round(r.height)} wrap=${cs.flexWrap} display=${cs.display} shrink=${cs.flexShrink}`);
  });
  inner.querySelectorAll('.nav-links a').forEach(a => {
    const r = a.getBoundingClientRect();
    out.push(`  link "${a.textContent}" x=${Math.round(r.x)} w=${Math.round(r.width)} top=${Math.round(r.top)}`);
  });
  return out.join('\n');
}));
await browser.close(); server.kill();
