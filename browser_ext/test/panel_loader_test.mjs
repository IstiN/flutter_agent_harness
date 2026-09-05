// panel.js v2.1 app-hosting loader tests (issue #30 AC1): panel.js runs in a
// vm sandbox with a stub document/location/fetch/chrome; faPanel.decide is
// driven directly and the fetch bootstrap is exercised end to end.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const panelDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'panel');

/** vm-realm objects carry a foreign prototype — clone to plain for deepEqual. */
const plain = (v) => JSON.parse(JSON.stringify(v));
const src = readFileSync(join(panelDir, 'panel.js'), 'utf8');

const NOTICE_TEXT =
  'fa app bundle not built — run scripts/build_browser_ext.sh --with-app — showing basic panel.';

/** Sandbox with recording stubs; boots panel.js exactly like the browser would. */
function boot({ fetchRes = { ok: true }, fetchError = null, redirect } = {}) {
  const classLists = new Map(); // element id -> list of classList ops
  const elements = new Map();
  const el = (id) => ({
    style: {},
    textContent: '',
    value: '',
    dataset: {},
    classList: {
      ops: [],
      add(c) { this.ops.push(`add:${c}`); },
      remove(c) { this.ops.push(`remove:${c}`); },
    },
    addEventListener() {},
  });
  const document = {
    getElementById(id) {
      if (!elements.has(id)) {
        elements.set(id, el(id));
        classLists.set(id, elements.get(id).classList.ops);
      }
      return elements.get(id);
    },
    createElement: () => ({ textContent: '', className: '' }),
  };
  const replaced = [];
  const sandbox = {
    console,
    document,
    fetch: fetchError ? () => Promise.reject(fetchError) : () => Promise.resolve(fetchRes),
    location: { replace: (url) => replaced.push(url) },
    chrome: {
      runtime: {
        connect: () => ({ onMessage: { addListener() {} } }),
        sendMessage: () => Promise.resolve({ ok: false }),
      },
    },
  };
  if (redirect !== undefined) sandbox.__faRedirect = redirect;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'panel.js' });
  return { sandbox, elements, classLists, replaced };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test('decide(true) → app mode, navigates to app/index.html via injected redirect', () => {
  const target = [];
  const { sandbox, replaced } = boot({ redirect: (url) => target.push(url) });
  assert.deepEqual(plain(sandbox.faPanel.decide(true)), { mode: 'app' });
  assert.deepEqual(target, ['app/index.html']);
  assert.deepEqual(replaced, [], 'injected redirect must win over location.replace');
});

test('decide(true) without injection falls back to location.replace', () => {
  const { sandbox, replaced } = boot();
  assert.deepEqual(plain(sandbox.faPanel.decide(true)), { mode: 'app' });
  assert.deepEqual(replaced, ['app/index.html']);
});

test('decide(false) → fallback mode, notice text set, legacy chat revealed, no redirect', () => {
  const { sandbox, elements, classLists, replaced } = boot();
  assert.deepEqual(plain(sandbox.faPanel.decide(false)), { mode: 'fallback' });
  assert.equal(elements.get('notice').textContent, NOTICE_TEXT);
  assert.deepEqual(classLists.get('notice'), ['remove:hidden'], 'notice not revealed');
  assert.deepEqual(classLists.get('legacy'), ['remove:hidden'], 'legacy chat not revealed');
  assert.deepEqual(replaced, [], 'fallback must not navigate');
});

test('bootstrap: HEAD 2xx routes to the app', async () => {
  const target = [];
  const { sandbox } = boot({ redirect: (url) => target.push(url), fetchRes: { ok: true } });
  await tick();
  assert.deepEqual(target, ['app/index.html']);
  assert.equal(typeof sandbox.faPanel?.decide, 'function', 'faPanel.decide exported');
});

test('bootstrap: HEAD failure (non-2xx or fetch error) falls back to the chat UI', async () => {
  for (const opts of [{ fetchRes: { ok: false } }, { fetchError: new Error('net') }]) {
    const { elements, classLists, replaced } = boot(opts);
    await tick();
    assert.equal(elements.get('notice').textContent, NOTICE_TEXT);
    assert.deepEqual(classLists.get('legacy'), ['remove:hidden']);
    assert.deepEqual(replaced, []);
  }
});
