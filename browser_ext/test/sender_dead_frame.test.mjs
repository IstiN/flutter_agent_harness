// Issue #470 AC4: sender hygiene in the SW — a destroyed frame/tab must not
// turn into a retry storm.
//
//  - ops.js sendToContent: a zombie tab (frame dead, tab object alive) is
//    dropped after SEND_MISS_CAP consecutive misses with exactly ONE warn
//    line; further sends are cheap probes (no inject retry); a closed tab
//    yields a clean no_tab; any answer resets the counter.
//  - main.js reply/push paths: a sendResponse to a dead frame and a
//    postMessage to a dead panel port are swallowed — zero uncaught
//    rejections across the whole file.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const swDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'sw');
const src = (name) => readFileSync(join(swDir, name), 'utf8');

const uncaught = [];
process.on('unhandledRejection', (e) => uncaught.push(e));
const tick = () => new Promise((r) => setImmediate(r));

function bootOps({ sendError: sendErr0, getTabError: getErr0 } = {}) {
  // Mutable hooks: tests can flip tab-closed / failure mid-scenario.
  let sendError = sendErr0;
  let getTabError = getErr0;
  const calls = { sendMessage: 0, executeScript: 0, warns: [] };
  const tab = { id: 5, url: 'https://outlook.cloud.microsoft/', active: false };
  const chrome = {
    tabs: {
      get: async (id) => {
        const err = getTabError?.();
        if (err || id !== tab.id) throw new Error(`No tab with id: ${id}`);
        return { ...tab };
      },
      query: async () => [tab],
      sendMessage: async (id) => {
        calls.sendMessage++;
        const err = sendError?.();
        if (err) throw err;
        return { pv: 1, ok: true, result: {} };
      },
    },
    scripting: {
      executeScript: async () => {
        calls.executeScript++;
      },
    },
  };
  const sandbox = {
    chrome,
    console: {
      warn: (...a) => calls.warns.push(a.join(' ')),
      log: () => {},
      error: () => {},
    },
    URL,
    setTimeout: () => 0,
    clearTimeout: () => {},
    faSw: { trackCreated: async () => {}, taskEnd: async () => {} },
  };
  vm.runInNewContext(src('ops.js'), sandbox, { filename: 'ops.js' });
  return {
    dispatch: sandbox.faSw.dispatch,
    calls,
    chrome,
    tab,
    set getTabError(fn) { getTabError = fn; },
  };
}

test('AC4: dead frame — drop after 3 consecutive misses with ONE warn', async () => {
  const { dispatch, calls } = bootOps({
    sendError: () => new Error('Frame with ID 0 does not exist in tab 5.'),
  });
  for (let i = 0; i < 3; i++) {
    const out = await dispatch('read_dom', { tabId: 5 });
    assert.equal(out.ok, false);
  }
  assert.equal(calls.warns.length, 1, 'exactly one warn line');
  assert.match(calls.warns[0], /unreachable 3×/);
  assert.equal(calls.executeScript, 2, 'inject+retry only before the cap');
});

test('AC4: capped tab — further sends are cheap probes, warn stays at one', async () => {
  const { dispatch, calls } = bootOps({
    sendError: () => new Error('Frame with ID 0 does not exist in tab 5.'),
  });
  for (let i = 0; i < 3; i++) await dispatch('read_dom', { tabId: 5 });
  const before = { sends: calls.sendMessage, injects: calls.executeScript, warns: calls.warns.length };
  for (let i = 0; i < 5; i++) {
    const out = await dispatch('read_dom', { tabId: 5 });
    assert.equal(out.ok, false);
  }
  assert.equal(calls.warns.length, before.warns, 'no new warn lines while capped');
  assert.equal(calls.executeScript, before.injects, 'no inject retries into the corpse');
  assert.ok(calls.sendMessage > before.sends, 'probe still attempts one cheap send');
});

test('AC4: tab closed while capped — clean no_tab, no send attempted', async () => {
  const boot = bootOps({ sendError: () => new Error('Frame with ID 0 does not exist in tab 5.') });
  const { dispatch, calls } = boot;
  for (let i = 0; i < 3; i++) await dispatch('read_dom', { tabId: 5 });
  boot.getTabError = () => new Error('No tab with id: 5'); // the tab is gone now
  const sendsBefore = calls.sendMessage;
  const out = await dispatch('read_dom', { tabId: 5 });
  assert.equal(out.ok, false);
  assert.equal(out.code, 'no_tab');
  assert.equal(calls.sendMessage, sendsBefore, 'no sendMessage into a closed tab');
});

test('AC4: an answer resets the counter — revived tab is served again', async () => {
  let fail = true;
  const { dispatch, calls } = bootOps({
    sendError: () => (fail ? new Error('Frame with ID 0 does not exist in tab 5.') : null),
  });
  await dispatch('read_dom', { tabId: 5 });
  await dispatch('read_dom', { tabId: 5 });
  fail = false; // the page answers again
  const out = await dispatch('read_dom', { tabId: 5 });
  assert.equal(out.ok, true);
  assert.equal(calls.warns.length, 0, 'never reached the cap — no warn');
  // Two fresh misses after the reset: still below the cap, no warn, injects run.
  fail = true;
  await dispatch('read_dom', { tabId: 5 });
  await dispatch('read_dom', { tabId: 5 });
  assert.equal(calls.warns.length, 0);
  assert.equal(calls.executeScript, 4, 'inject+retry ran for every uncapped miss (2+2)');
});

/** Boot main.js with enough stubbed chrome to survive; returns its handlers. */
function bootMain() {
  let onMessage, onConnect;
  let statusCb = null;
  const ports = new Set();
  const chrome = {
    sidePanel: { setPanelBehavior: async () => {} },
    runtime: {
      onMessage: { addListener: (fn) => (onMessage = fn) },
      onConnect: {
        addListener: (fn) =>
          (onConnect = (port) => {
            ports.add(port);
            fn(port);
          }),
      },
      sendMessage: async () => {},
    },
    alarms: {
      onAlarm: { addListener: () => {} },
      create: () => {},
      clear: () => {},
    },
    tabs: {
      onCreated: { addListener: () => {} },
      onRemoved: { addListener: () => {} },
    },
    storage: {
      local: {
        get: async (keys) => {
          if (getThrows) throw new Error('storage exploded');
          return {};
        },
        set: async (o) => {
          if (setThrows) throw new Error('storage exploded');
        },
        remove: async () => {},
      },
    },
  };
  let getThrows = false;
  let setThrows = false;
  const sandbox = {
    chrome,
    console: { warn: () => {}, log: () => {}, error: () => {} },
    importScripts: () => {},
    crypto,
    faSw: {
      KEEPALIVE_ALARM: 'ka',
      bridge: { onStatus: (fn) => (statusCb = fn), onMail: () => {}, onBrowserReq: () => {}, status: () => ({}) },
      dispatch: async () => ({ ok: true }),
      status: () => ({}),
      init: async () => {},
      beginTask: async () => {},
      onTabCreated: () => {},
      onTabRemoved: () => {},
    },
  };
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.runInNewContext(src('main.js'), sandbox, { filename: 'main.js' });
  return {
    onMessage,
    onConnect,
    chrome,
    driveStatus: (s) => statusCb?.(s),
    setGetThrows: (v) => (getThrows = v),
    setSetThrows: (v) => (setThrows = v),
  };
}

test('AC4: reply to a dead asker throws nothing — one answer attempt, swallowed', async () => {
  const m = bootMain();
  let attempts = 0;
  const deadSendResponse = () => {
    attempts++;
    throw new Error('Attempting to use a disconnected port object');
  };
  m.onMessage({ type: 'status' }, {}, deadSendResponse);
  await tick();
  assert.equal(attempts, 1, 'the reply was attempted exactly once');
  assert.equal(uncaught.length, 0, 'zero uncaught rejections');
});

test('AC4: async handler failure reaches the asker as {ok:false}, never unhandled', async () => {
  const m = bootMain();
  m.setSetThrows(true);
  const replies = [];
  m.onMessage({ type: 'provider.save', baseUrl: 'x', apiKey: 'k', model: 'm' }, {}, (r) => replies.push(r));
  await tick();
  await tick();
  assert.equal(replies.length, 1);
  assert.equal(replies[0].ok, false);
  assert.match(replies[0].error, /storage exploded/);
  assert.equal(uncaught.length, 0);
});

test('AC4: push to a dead panel port is swallowed and the port pruned', async () => {
  const m = bootMain();
  const seen = [];
  const deadAttempts = { n: 0 };
  const onDisc = { addListener: () => {} };
  m.onConnect({ postMessage: () => { deadAttempts.n++; throw new Error('dead port'); }, name: 'fa-panel', onDisconnect: onDisc });
  const live = { postMessage: (msg) => seen.push(msg), name: 'fa-panel', onDisconnect: onDisc };
  m.onConnect(live);
  assert.equal(seen.length, 1, 'fresh port got the boot snapshot');
  // The SW broadcasts on bridge status changes (pushPanels).
  m.driveStatus({ phase: 'connected' });
  m.driveStatus({ phase: 'connected' });
  await tick();
  assert.equal(seen.length, 3, 'the live port receives every broadcast');
  assert.equal(deadAttempts.n, 1, 'the dead port is attempted once, then pruned');
  assert.equal(uncaught.length, 0, 'dead ports never surface as uncaught errors');
});
