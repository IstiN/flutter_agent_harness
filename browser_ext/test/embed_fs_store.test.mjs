// Issue #470 AC3: the embedded index must ship fs_store.js.
//
// The build-time gate is scripts/check_embed_assets.py (wired into
// scripts/build_office_addin.sh after the office.js/CSP injection). These
// tests drive the gate itself against fixture app dirs — tag missing, file
// missing, symbol wrong — and assert the source templates every embedded
// build is assembled from carry the tag and the real symbols.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const guard = join(root, 'scripts', 'check_embed_assets.py');

const INDEX = '<html><head></head><body><script src="flutter_bootstrap.js" async></script>\n</body></html>';
const TAGGED = INDEX.replace('</body>', '  <script src="fs_store.js"></script>\n</body>');
const HELPER = 'window.__fahFsGetAll = function() {};\nwindow.__fahFsSet = function() {};\n';

function fixture({ tag = true, file = true, symbol }) {
  const dir = join(tmpdir(), `fa-embed-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'index.html'), tag ? TAGGED : INDEX);
  if (file) {
    writeFileSync(join(dir, 'fs_store.js'), symbol === undefined ? HELPER : symbol);
  }
  return dir;
}

function runGuard(dir) {
  try {
    const out = execFileSync('python3', [guard, 'check', dir], { encoding: 'utf8' });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status, out: `${e.stdout ?? ''}${e.stderr ?? ''}` };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('gate passes a staged app dir that ships tag + file + symbol', () => {
  const dir = fixture({});
  const r = runGuard(dir);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /OK/);
});

test('gate fails when index.html lacks the fs_store.js tag (the #470 grounding)', () => {
  const dir = fixture({ tag: false });
  const r = runGuard(dir);
  assert.notEqual(r.code, 0);
  assert.match(r.out, /fs_store\.js tag/);
  assert.match(r.out, /::error/, 'CI annotation');
});

test('gate fails when fs_store.js is missing next to index.html (tag would 404)', () => {
  const dir = fixture({ file: false });
  const r = runGuard(dir);
  assert.notEqual(r.code, 0);
  assert.match(r.out, /fs_store\.js file/);
});

test('gate fails when the helper lacks the probed symbol', () => {
  const dir = fixture({ symbol: 'window.__other = 1;\n' });
  const r = runGuard(dir);
  assert.notEqual(r.code, 0);
  assert.match(r.out, /__fahFsGetAll/);
});

test('source of truth: the flutter web template ships the tag and all helpers', () => {
  const template = readFileSync(join(root, 'flutter_app', 'web', 'index.html'), 'utf8');
  assert.match(template, /<script src="fs_store\.js"><\/script>/);
  const helper = readFileSync(join(root, 'flutter_app', 'web', 'fs_store.js'), 'utf8');
  for (const fn of ['__fahFsOpen', '__fahFsGetAll', '__fahFsSet', '__fahFsRemove']) {
    assert.match(helper, new RegExp(`window\\.${fn}`), `${fn} defined`);
  }
});
