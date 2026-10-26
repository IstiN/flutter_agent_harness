// Composer enrollment through the existing service-worker DAP runtime.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = readFileSync(join(root, 'sw', 'main.js'), 'utf8');
const plain = (value) => JSON.parse(JSON.stringify(value));

function boot(hub) {
  const data = {};
  const boots = [];
  const logs = [];
  let onMessage;
  const agent = {
    boot(config) {
      boots.push(plain(config));
      return Promise.resolve();
    },
    getState: () => ({ hub }),
    getStateForTest: () => ({}),
    onEvent() {},
  };
  const bridge = {
    status: () => ({}),
    onStatus() {},
    onMail() {},
    onBrowserReq() {},
    onKeepalive() {},
    connect() {},
  };
  const sandbox = {
    console: {
      log: (...args) => logs.push(args.join(' ')),
      warn: (...args) => logs.push(args.join(' ')),
      error: (...args) => logs.push(args.join(' ')),
    },
    importScripts() {},
    faAgent: agent,
    faSw: {
      bridge,
      KEEPALIVE_ALARM: 'keepalive',
      dispatch: () => ({}),
      status: () => ({}),
      beginTask() {},
      taskEnd() {},
      init: () => Promise.resolve(),
      onTabCreated() {},
      onTabRemoved() {},
    },
    chrome: {
      tabs: {
        onCreated: { addListener() {} },
        onRemoved: { addListener() {} },
      },
      storage: {
        local: {
          get(keys) {
            const names = Array.isArray(keys) ? keys : [keys];
            return Promise.resolve(Object.fromEntries(names.filter((k) => k in data).map((k) => [k, data[k]])));
          },
          set(values) {
            Object.assign(data, values);
            return Promise.resolve();
          },
          remove(keys) {
            for (const key of Array.isArray(keys) ? keys : [keys]) delete data[key];
            return Promise.resolve();
          },
        },
      },
      runtime: {
        onMessage: { addListener(fn) { onMessage = fn; } },
        onConnect: { addListener() {} },
      },
      sidePanel: { setPanelBehavior: () => Promise.resolve() },
      alarms: {
        create() {},
        clear() {},
        onAlarm: { addListener() {} },
      },
    },
    setTimeout,
    clearTimeout,
    Date,
    URL,
    crypto: { randomUUID: () => 'test-task' },
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'sw/main.js' });
  return {
    data,
    boots,
    logs,
    async send(message) {
      return new Promise((resolve) => onMessage(message, {}, resolve));
    },
  };
}

test('hub.join persists scoped enrollment and boots the existing worker client', async () => {
  const channel = 'public-channel';
  const h = boot({ phase: 'connected', channels: [channel] });
  const reply = await h.send({
    type: 'hub.join',
    url: 'wss://hub.fa1.dev/ws',
    channel,
    clientSecret: 'test-extension-credential',
    name: 'extension-agent',
  });
  assert.deepEqual(plain(reply), { ok: true });
  assert.equal(h.boots.length, 1);
  assert.equal(h.boots[0].dap.url, 'wss://hub.fa1.dev/ws');
  assert.equal(h.boots[0].dap.enrollment.channel, channel);
  assert.equal(h.data.faDap.enrollment.clientSecret, 'test-extension-credential');
  assert.equal('pub' in h.data.faDap.enrollment, false, 'public join stays keyless');
  assert.equal(h.logs.some((line) => line.includes('test-extension-credential')), false);
});

test('hub.bind preserves enrollment and manual hub.save leaves it', async () => {
  const channel = 'private-channel';
  const h = boot({ phase: 'connected', channels: [channel] });
  await h.send({
    type: 'hub.join',
    url: 'wss://hub.fa1.dev/ws',
    channel,
    clientSecret: 'test-extension-credential',
    pub: 'channel-pub',
    priv: 'channel-priv',
  });
  await h.send({ type: 'hub.bind', mode: 'current' });
  assert.equal(h.data.faDap.enrollment.channel, channel);
  assert.equal(h.data.faDap.enrollment.priv, 'channel-priv');

  await h.send({ type: 'hub.save', url: 'wss://hub.fa1.dev/ws', name: 'manual' });
  assert.equal('enrollment' in h.data.faDap, false);
});

test('worker rejection is honest without reflecting the credential', async () => {
  const h = boot({ phase: 'unauthorized' });
  const reply = await h.send({
    type: 'hub.join',
    url: 'wss://hub.fa1.dev/ws',
    channel: 'public-channel',
    clientSecret: 'do-not-reflect',
  });
  assert.equal(reply.ok, false);
  assert.equal(JSON.stringify(reply).includes('do-not-reflect'), false);
  assert.equal(h.logs.some((line) => line.includes('do-not-reflect')), false);
});
