// cdp.js smoke tests: chrome.debugger is a recorder stub; the classic-script
// source is eval'd in a vm sandbox the same way the SW's importScripts loads it
// (globals preset, faSw namespace accumulates). No real browser — CI covers it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const swDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'sw');

/** vm-realm objects carry a foreign prototype — clone to plain for deepEqual. */
const plain = (v) => JSON.parse(JSON.stringify(v));

/** Recorder chrome.debugger stub: commands fail until attach, like real Chrome. */
function debuggerStub({ attachError, reply = () => ({}) } = {}) {
  const calls = [];
  const fireDetach = {};
  const live = new Set(); // tabIds with an attached debugger
  const chrome = {
    debugger: {
      attach: async (target, version) => {
        calls.push(['attach', target.tabId, version]);
        if (attachError) throw new Error(attachError);
        live.add(target.tabId);
        return 'target-1';
      },
      sendCommand: async (target, method, params) => {
        calls.push(['cmd', target.tabId, method, params]);
        if (!live.has(target.tabId)) throw new Error('Not attached');
        return reply(method, params);
      },
      detach: async (target) => { calls.push(['detach', target.tabId]); live.delete(target.tabId); },
      onDetach: { addListener: (fn) => { fireDetach.fn = fn; } },
    },
  };
  return { chrome, calls, fireDetach: (tabId) => fireDetach.fn({ tabId }) };
}

const boot = (opts) => {
  const stub = debuggerStub(opts);
  const sandbox = { chrome: stub.chrome, console, setTimeout, clearTimeout };
  vm.runInNewContext(readFileSync(join(swDir, 'cdp.js'), 'utf8'), sandbox, { filename: 'cdp.js' });
  return { ...stub, cdp: sandbox.faSw.cdp };
};

test('trustedClick attaches once and clicks the element center', async () => {
  const { cdp, calls } = boot({ reply: (m) => (m === 'Runtime.evaluate' ? { result: { value: { x: 30, y: 40, w: 10, h: 20 } } } : {}) });
  await cdp.ensure(5); // ops.domOp ensures before the trusted call
  assert.deepEqual(plain(await cdp.trustedClick(5, '#go')), { selector: '#go' });
  assert.deepEqual(calls[0], ['attach', 5, '1.3']);
  assert.deepEqual(
    calls.filter(([, , m]) => m === 'Input.dispatchMouseEvent').map(([, , , p]) => plain(p)),
    [
      { type: 'mousePressed', x: 30, y: 40, button: 'left', clickCount: 1 },
      { type: 'mouseReleased', x: 30, y: 40, button: 'left', clickCount: 1 },
    ],
  );
});

test('attach is cached per tab', async () => {
  const { cdp, calls } = boot({ reply: () => ({ result: { value: { x: 1, y: 2, w: 3, h: 4 } } }) });
  await cdp.ensure(7);
  await cdp.ensure(7);
  await cdp.trustedClick(7, '#a');
  assert.equal(calls.filter(([kind]) => kind === 'attach').length, 1);
  assert.deepEqual(plain(cdp.status()), { attached: [7] });
});

test('onDetach evicts the cache; the next call re-attaches', async () => {
  const { cdp, calls, fireDetach } = boot({ reply: () => ({ result: { value: { x: 1, y: 1, w: 1, h: 1 } } }) });
  await cdp.ensure(9);
  fireDetach(9);
  assert.deepEqual(plain(cdp.status()), { attached: [] });
  await cdp.ensure(9);
  assert.equal(calls.filter(([kind]) => kind === 'attach').length, 2);
});

test('E23: another debugger client maps to denied with a content-path hint', async () => {
  const { cdp } = boot({ attachError: 'Another client is already attached' });
  await assert.rejects(() => cdp.ensure(3), (e) => e.code === 'denied' && /content path/.test(e.message));
});

test('session torn down mid-command evicts and maps to no_tab', async () => {
  const { cdp } = boot({
    reply: (m) => {
      if (m === 'Page.captureScreenshot') throw new Error('Not attached');
      return { result: { value: 1 } };
    },
  });
  await cdp.ensure(4);
  await assert.rejects(() => cdp.captureTab(4), (e) => e.code === 'no_tab');
});

test('rect returns the element center; null value is node_vanished', async () => {
  const { cdp, calls } = boot({ reply: (m, p) => ({ result: { value: p.expression.includes('#hit') ? { x: 8, y: 9, w: 2, h: 2 } : null } }) });
  await cdp.ensure(6);
  assert.deepEqual(plain(await cdp.rect(6, '#hit')), { x: 8, y: 9, w: 2, h: 2 });
  assert.match(calls.find(([, , m]) => m === 'Runtime.evaluate')[3].expression, /getBoundingClientRect/);
  await assert.rejects(() => cdp.rect(6, '#miss'), (e) => e.code === 'node_vanished');
});

test('trustedType focuses, types keyDown/char/keyUp per char, Enter on submit', async () => {
  const { cdp, calls } = boot({ reply: (m) => (m === 'Runtime.evaluate' ? { result: { value: true } } : {}) });
  await cdp.ensure(4);
  assert.deepEqual(plain(await cdp.trustedType(4, '#q', 'hi', true)), { typed: 2 });
  const keys = calls.filter(([, , m]) => m === 'Input.dispatchKeyEvent').map(([, , , p]) => `${p.type}:${p.text ?? p.key}`);
  assert.deepEqual(keys, ['keyDown:h', 'char:h', 'keyUp:h', 'keyDown:i', 'char:i', 'keyUp:i', 'keyDown:\r', 'keyUp:Enter']);
  const focus = calls.find(([, , m]) => m === 'Runtime.evaluate');
  assert.match(focus[3].expression, /#q/);
  assert.match(focus[3].expression, /focus/);
});

test('trustedType with a missing selector is node_vanished', async () => {
  const { cdp } = boot({ reply: (m) => (m === 'Runtime.evaluate' ? { result: { value: false } } : {}) });
  await cdp.ensure(4);
  await assert.rejects(() => cdp.trustedType(4, '#nope', 'x', false), (e) => e.code === 'node_vanished');
});

test('trustedPressKey adds char only for a single printable char', async () => {
  const { cdp, calls } = boot({});
  await cdp.ensure(2);
  await cdp.trustedPressKey(2, 'a');
  await cdp.trustedPressKey(2, 'Enter');
  assert.deepEqual(
    calls.filter(([, , m]) => m === 'Input.dispatchKeyEvent').map(([, , , p]) => plain(p)),
    [
      { type: 'keyDown', key: 'a', code: '', text: 'a' },
      { type: 'char', key: 'a', code: '', text: 'a' },
      { type: 'keyUp', key: 'a', code: '' },
      { type: 'keyDown', key: 'Enter', code: 'Enter' },
      { type: 'keyUp', key: 'Enter', code: 'Enter' },
    ],
  );
});

test('captureTab screenshots any tab without activation', async () => {
  const { cdp, calls } = boot({ reply: (m) => (m === 'Page.captureScreenshot' ? { data: 'QUJD' } : {}) });
  await cdp.ensure(11);
  assert.deepEqual(plain(await cdp.captureTab(11)), { pngBase64: 'QUJD', mimeType: 'image/png' });
  assert.deepEqual(plain(calls.find(([, , m]) => m === 'Page.captureScreenshot')), ['cmd', 11, 'Page.captureScreenshot', { format: 'png' }]);
  assert.ok(!calls.some(([, , m]) => m === 'Page.bringToFront'));
});

test('detachAll detaches every cached tab and clears state', async () => {
  const { cdp, calls } = boot({ reply: () => ({ result: { value: 1 } }) });
  await cdp.ensure(1);
  await cdp.ensure(2);
  assert.equal(await cdp.detachAll(), 2);
  assert.deepEqual(calls.filter(([kind]) => kind === 'detach').map(([, tabId]) => tabId), [1, 2]);
  assert.deepEqual(plain(cdp.status()), { attached: [] });
});
