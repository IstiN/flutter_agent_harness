// ops.js trusted-routing tests: full dispatch table driven against a stubbed
// chrome (debugger + tabs + scripting). Sources load in a vm sandbox exactly
// like the SW's importScripts: faSw presets stand in for the pieces ops.js
// destructures at load time (tabs.js is not loaded here).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const swDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'sw');
const src = (name) => readFileSync(join(swDir, name), 'utf8');

/** vm-realm objects carry a foreign prototype — clone to plain for deepEqual. */
const plain = (v) => JSON.parse(JSON.stringify(v));

/** Stubbed chrome + faSw presets; loads cdp.js then ops.js; returns dispatch + call log. */
function boot({ tab = { id: 5, url: 'https://example.com/', active: false }, attachError } = {}) {
  const calls = [];
  const chrome = {
    debugger: {
      attach: async (t, v) => {
        calls.push(['attach', t.tabId, v]);
        if (attachError) throw new Error(attachError);
        return 't1';
      },
      sendCommand: async (t, m, p) => {
        calls.push(['cmd', t.tabId, m, p]);
        if (m === 'Runtime.evaluate') return { result: { value: /"#gone"/.test(p.expression) ? null : { x: 10, y: 20, w: 4, h: 4 } } };
        if (m === 'Page.captureScreenshot') return { data: 'UE5H' };
      },
      detach: async (t) => calls.push(['detach', t.tabId]),
      onDetach: { addListener: () => {} },
    },
    tabs: {
      get: async (id) => {
        if (id !== tab.id) throw new Error(`No tab with id: ${id}`);
        return { ...tab };
      },
      query: async () => [tab],
      update: async (id, props) => { calls.push(['tabs.update', id, props]); return { ...tab, ...props, id }; },
      captureVisibleTab: async () => { calls.push(['captureVisibleTab']); return 'data:image/png;base64,REFUQQ=='; },
      sendMessage: async (id, msg) => { calls.push(['sendMessage', id, msg.op]); return { pv: 1, ok: true, result: { clicked: true } }; },
    },
    scripting: { executeScript: async () => calls.push(['executeScript']) },
  };
  const sandbox = {
    chrome,
    console,
    URL,
    setTimeout: () => 0, // withCap's 30s cap never arms under test
    clearTimeout: () => {},
    faSw: {
      trackCreated: async () => {},
      taskEnd: async () => calls.push(['taskEnd']),
    },
  };
  vm.runInNewContext(src('cdp.js'), sandbox, { filename: 'cdp.js' });
  vm.runInNewContext(src('ops.js'), sandbox, { filename: 'ops.js' });
  return { dispatch: sandbox.faSw.dispatch, calls };
}

test('trusted click rides CDP and pins path "cdp"', async () => {
  const { dispatch, calls } = boot();
  const r = await dispatch('click', { tabId: 5, selector: '#go', trusted: true });
  assert.equal(r.ok, true);
  assert.deepEqual(plain(r.result), { selector: '#go', path: 'cdp' });
  assert.ok(calls.some(([kind, id]) => kind === 'attach' && id === 5));
  assert.ok(calls.some(([, , m, p]) => m === 'Input.dispatchMouseEvent' && p.type === 'mousePressed'));
  assert.ok(!calls.some(([kind]) => kind === 'sendMessage'));
});

test('default click stays on the content path and pins path "dom"', async () => {
  const { dispatch, calls } = boot();
  const r = await dispatch('click', { tabId: 5, selector: '#go' });
  assert.deepEqual(plain(r.result), { clicked: true, path: 'dom' });
  assert.ok(calls.some(([kind, , op]) => kind === 'sendMessage' && op === 'click'));
  assert.ok(!calls.some(([kind]) => kind === 'attach'));
});

test('E23: another client owns the tab → denied, quiet path not silently used', async () => {
  const { dispatch, calls } = boot({ attachError: 'Another client is already attached' });
  const r = await dispatch('click', { tabId: 5, selector: '#go', trusted: true });
  assert.equal(r.ok, false);
  assert.equal(r.code, 'denied');
  assert.match(r.error, /content path/);
  assert.ok(!calls.some(([kind]) => kind === 'sendMessage'));
});

test('rect miss on trusted click → node_vanished', async () => {
  const { dispatch } = boot();
  const r = await dispatch('click', { tabId: 5, selector: '#gone', trusted: true });
  assert.equal(r.ok, false);
  assert.equal(r.code, 'node_vanished');
});

test('trusted op on an unknown tabId → no_tab before any attach', async () => {
  const { dispatch, calls } = boot();
  const r = await dispatch('click', { tabId: 99, selector: '#x', trusted: true });
  assert.equal(r.code, 'no_tab');
  assert.ok(!calls.some(([kind]) => kind === 'attach'));
});

test('trusted type forwards text + submit as CDP key events', async () => {
  const { dispatch, calls } = boot();
  const r = await dispatch('type', { tabId: 5, selector: '#q', text: 'a', submit: true, trusted: true });
  assert.equal(r.result.path, 'cdp');
  const types = calls.filter(([, , m]) => m === 'Input.dispatchKeyEvent').map(([, , , p]) => p.type);
  assert.deepEqual(types, ['keyDown', 'char', 'keyUp', 'keyDown', 'keyUp']); // char pair + Enter pair
});

test('trusted press_key rides CDP with path pin', async () => {
  const { dispatch, calls } = boot();
  const r = await dispatch('press_key', { tabId: 5, key: 'ArrowDown', trusted: true });
  assert.equal(r.ok, true);
  assert.deepEqual(plain(r.result), { key: 'ArrowDown', path: 'cdp' });
  assert.ok(calls.some(([, , m, p]) => m === 'Input.dispatchKeyEvent' && p.key === 'ArrowDown'));
});

test('trusted screenshot captures the background tab without activating it (AC16)', async () => {
  const { dispatch, calls } = boot(); // tab.active: false
  const r = await dispatch('screenshot', { tabId: 5, trusted: true });
  assert.deepEqual(plain(r.result), { pngBase64: 'UE5H', mimeType: 'image/png', path: 'cdp' });
  assert.ok(calls.some(([, , m]) => m === 'Page.captureScreenshot'));
  assert.ok(!calls.some(([kind]) => kind === 'tabs.update')); // never activates the tab
  assert.ok(!calls.some(([kind]) => kind === 'captureVisibleTab'));
});

test('untrusted screenshot keeps the visible-tab path with path "dom"', async () => {
  const { dispatch, calls } = boot();
  const r = await dispatch('screenshot', { tabId: 5 });
  assert.equal(r.result.path, 'dom');
  assert.ok(calls.some(([kind, , props]) => kind === 'tabs.update' && props.active === true)); // activates when inactive
  assert.ok(calls.some(([kind]) => kind === 'captureVisibleTab'));
});

test('task_end detaches debugger sessions and runs tab cleanup', async () => {
  const { dispatch, calls } = boot();
  await dispatch('click', { tabId: 5, selector: '#go', trusted: true }); // leaves one attach
  const r = await dispatch('task_end', {});
  assert.equal(r.ok, true);
  assert.deepEqual(plain(r.result), { cleaned: true });
  assert.deepEqual(calls.filter(([kind]) => kind === 'detach').map(([, id]) => id), [5]);
  assert.ok(calls.some(([kind]) => kind === 'taskEnd'));
});
