// Bound-session picker vm-tests (issue #321): panel.js booted in a vm
// sandbox whose chrome.runtime.sendMessage answers the panel API like the
// service worker would. Pins: the picker renders hub.bind.get state
// (dedicated default), the named row visibility, the hub.sessions fill,
// the exact hub.bind payloads per mode (incl. the sticky bare
// {mode:'current'}), and the invalid/failed save paths. Also proves the
// DAP section itself never touches chrome.storage ('UI holds no keys').
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const panelDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'panel');
const src = readFileSync(join(panelDir, 'panel.js'), 'utf8');

/** Boots panel.js with a scripted panel-API responder. */
function boot({ binding = null, sessions = [], bindResult = { ok: true } } = {}) {
  const elements = new Map();
  const el = (id) => ({
    style: {},
    textContent: '',
    value: '',
    checked: false,
    hidden: false,
    dataset: {},
    selectedOptions: [],
    children: [],
    lastChild: null,
    innerHTML: '',
    classList: { add() {}, remove() {} },
    listeners: {},
    addEventListener(type, fn) { this.listeners[type] = fn; },
    prepend() {},
    appendChild(child) { this.children.push(child); },
  });
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, el(id));
      return elements.get(id);
    },
    createElement: () => ({ textContent: '', className: '', value: '' }),
  };
  const sent = [];
  const respond = (msg) => {
    switch (msg?.type) {
      case 'hub.bind.get': return { ok: true, binding };
      case 'hub.sessions': return { ok: true, sessions };
      case 'hub.bind': return bindResult;
      default: return { ok: false }; // status etc.
    }
  };
  const sandbox = {
    console: { log() {}, error() {} },
    document,
    fetch: () => Promise.resolve({ ok: false }),
    location: { replace() {} },
    setTimeout,
    URL,
    Date,
    chrome: {
      runtime: {
        connect: () => ({ onMessage: { addListener() {} }, postMessage() {} }),
        sendMessage: (msg) => {
          sent.push(msg);
          return Promise.resolve(respond(msg));
        },
      },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'panel.js' });
  const el2 = (id) => document.getElementById(id);
  return {
    el: el2,
    sent,
    binds: () => sent.filter((m) => m.type === 'hub.bind'),
    click: (id) => el2(id).listeners.click(),
    change: (id) => el2(id).listeners.change(),
  };
}

const tick = (ms = 10) => new Promise((r) => setTimeout(r, ms));

/** vm-realm objects carry a foreign prototype — clone for deepEqual. */
const plain = (v) => JSON.parse(JSON.stringify(v));

test('no stored binding → dedicated default checked, named row hidden, default status', async () => {
  const { el } = boot({ binding: null });
  await tick();
  assert.equal(el('dapMode_dedicated').checked, true, 'dedicated radio checked');
  assert.equal(el('dapMode_current').checked, false);
  assert.equal(el('dapMode_named').checked, false);
  assert.equal(el('dapBindNamedRow').hidden, true, 'named row hidden');
  assert.equal(el('dapBindStatus').textContent, 'routing: dedicated (default)');
});

test('stored named binding renders: named checked, row shown, status names the session', async () => {
  const { el } = boot({ binding: { mode: 'named', sessionId: 's2' } });
  await tick();
  assert.equal(el('dapMode_named').checked, true);
  assert.equal(el('dapMode_dedicated').checked, false);
  assert.equal(el('dapBindNamedRow').hidden, false, 'named row shown');
  assert.equal(el('dapBindSession').dataset.boundId, 's2');
  assert.equal(el('dapBindStatus').textContent, 'routing: named → s2');
});

test('dedicated binding renders its title and session id (write-only no more)', async () => {
  const { el } = boot({
    binding: { mode: 'dedicated', sessionId: 'inbox-1', title: 'DAP Inbox' },
  });
  await tick();
  assert.equal(el('dapMode_dedicated').checked, true);
  assert.equal(
    el('dapBindStatus').textContent,
    'routing: dedicated → DAP Inbox (inbox-1)',
    'the bound title is visible where the mail lands',
  );
});

test('mode change toggles the named row: hidden for dedicated/current, shown for named', async () => {
  const { el, change } = boot();
  await tick();
  const setMode = (mode) => {
    for (const m of ['dedicated', 'current', 'named']) el(`dapMode_${m}`).checked = m === mode;
    change(`dapMode_${mode}`);
  };
  setMode('current');
  assert.equal(el('dapBindNamedRow').hidden, true);
  setMode('named');
  assert.equal(el('dapBindNamedRow').hidden, false);
  setMode('dedicated');
  assert.equal(el('dapBindNamedRow').hidden, true);
});

test('session select fills from hub.sessions and honors the bound selection', async () => {
  const { el } = boot({
    binding: { mode: 'named', sessionId: 's2' },
    sessions: [
      { id: 's1', messages: 3 },
      { id: 's2', messages: 0, running: true },
    ],
  });
  await tick();
  const opts = el('dapBindSession').children;
  assert.equal(opts.length, 2);
  assert.deepEqual(

    opts.map((o) => [o.value, o.textContent]),
    [
      ['s1', 's1 (3 msgs)'],
      ['s2', 's2 (0 msgs, running)'],
    ],
  );
  assert.equal(el('dapBindSession').value, 's2', 'bound id preselected');
});

test('save dedicated (first bind) posts {mode:"dedicated", title:"DAP Inbox"}', async () => {
  const { el, binds, click } = boot({ binding: null });
  await tick();
  click('saveDapBind');
  await tick();
  assert.deepEqual(plain(binds()), [{ type: 'hub.bind', mode: 'dedicated', title: 'DAP Inbox' }]);
  assert.equal(el('dapBindStatus').textContent, 'routing: dedicated → DAP Inbox');
});

test('save dedicated rebind keeps the remembered session id (no re-mint)', async () => {
  const { el, binds, click } = boot({
    binding: { mode: 'dedicated', sessionId: 'inbox-1', title: 'DAP Inbox' },
  });
  await tick();
  click('saveDapBind');
  await tick();
  assert.deepEqual(
    plain(binds()),
    [{ type: 'hub.bind', mode: 'dedicated', sessionId: 'inbox-1' }],
  );
  assert.equal(
    el('dapBindStatus').textContent,
    'routing: dedicated → DAP Inbox (inbox-1)',
  );
});

test('save named posts the picked sessionId plus the option title', async () => {
  const { el, binds, click } = boot({
    sessions: [{ id: 's1', messages: 3 }],
  });
  await tick();
  // Radio-group semantics: checking named unchecks dedicated.
  el('dapMode_named').checked = true;
  el('dapMode_dedicated').checked = false;
  el('dapBindSession').value = 's1';
  el('dapBindSession').selectedOptions = [{ textContent: 's1 (3 msgs)' }];
  click('saveDapBind');
  await tick();
  assert.deepEqual(
    plain(binds()),
    [{ type: 'hub.bind', mode: 'named', sessionId: 's1', title: 's1 (3 msgs)' }],
  );
  assert.equal(el('dapBindStatus').textContent, 'routing: named → s1');
});

test('save current posts the bare sticky payload {mode:"current"}', async () => {
  // issue #321: 'current' must round-trip — the SW persists {mode:'current'}
  // so the choice stays sticky instead of snapping back to dedicated.
  const { el, binds, click } = boot({ binding: null });
  await tick();
  el('dapMode_current').checked = true;
  el('dapMode_dedicated').checked = false;
  click('saveDapBind');
  await tick();
  assert.deepEqual(plain(binds()), [{ type: 'hub.bind', mode: 'current' }]);
  assert.equal(el('dapBindStatus').textContent, 'routing: current');
});

test('named save with no session picked → guidance, nothing sent', async () => {
  const { el, binds, click } = boot({ sessions: [] });
  await tick();
  el('dapMode_named').checked = true;
  el('dapMode_dedicated').checked = false;
  el('dapBindSession').value = '';
  click('saveDapBind');
  await tick();
  assert.deepEqual(plain(binds()), [], 'no hub.bind may leave the panel');
  assert.equal(el('dapBindStatus').textContent, 'pick a session for named mode');
});

test('failed save surfaces the SW error in the status line', async () => {
  const { el, binds, click } = boot({
    bindResult: { ok: false, error: 'no hub connection to bind' },
  });
  await tick();
  click('saveDapBind');
  await tick();
  assert.equal(binds().length, 1, 'the save was attempted');
  assert.equal(
    el('dapBindStatus').textContent,
    'save failed: no hub connection to bind',
  );
});

test('the DAP section never reads chrome.storage — UI holds no keys', async () => {
  const start = src.indexOf('// --- DAP inbound-mail routing');
  const end = src.indexOf('// -- Advanced: Settings-gated');
  assert.ok(start > 0 && end > start, 'DAP section boundaries found');
  const section = src
    .slice(start, end)
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
  assert.equal(section.includes('chrome.storage'), false, 'no storage reads');
  assert.ok(
    section.includes("call({ type: 'hub.bind.get' })"),
    'reads go through the hub.bind.get message (routing fields only)',
  );
});
