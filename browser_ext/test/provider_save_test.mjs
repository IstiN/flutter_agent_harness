// gh-2425: provider.save must not drop the stored contextWindow/cap/headers,
// must accept contextWindow + custom headers from the panel, and must answer
// provider.get with every field EXCEPT the apiKey (the key stays write-only
// in the UI — same principle as hub.bind.get).
//
// Drive behavior through the real runtime.onMessage table (main.js booted in
// a vm with a storage-backed chrome stub), like dap_enrollment_test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = readFileSync(join(root, 'sw', 'main.js'), 'utf8');
const plain = (value) => JSON.parse(JSON.stringify(value));

const tick = () => new Promise((r) => setTimeout(r, 0));

function boot(initialProvider) {
  const data = {};
  if (initialProvider) data.faProvider = plain(initialProvider);
  const boots = [];
  let onMessage;
  const agent = {
    boot(config) {
      boots.push(plain(config));
      return Promise.resolve();
    },
    getState: () => ({}),
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
    console: { log() {}, warn() {}, error() {} },
    importScripts() {},
    faAgent: agent,
    faSw: {
      bridge,
      KEEPALIVE_ALARM: 'keepalive',
      dispatch: () => ({}),
      status: () => ({}),
      init: () => Promise.resolve(),
      beginTask() {},
      taskEnd() {},
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
            return Promise.resolve(
              Object.fromEntries(names.filter((k) => k in data).map((k) => [k, data[k]])),
            );
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
    async send(message) {
      return new Promise((resolve) => onMessage(message, {}, resolve));
    },
  };
}

test('gh-2425: a plain save keeps the stored contextWindow/cap/headers', async () => {
  const h = boot({
    baseUrl: 'https://a/v1',
    apiKey: 'stored-key',
    model: 'old-model',
    contextWindow: 264000,
    contextWindowCap: 128000,
    headers: { 'x-project': 'codemie-42' },
  });
  const reply = await h.send({ type: 'provider.save', baseUrl: 'https://b/v1', apiKey: 'new-key', model: 'big-model' });
  assert.equal(reply.ok, true);
  const stored = h.data.faProvider;
  assert.equal(stored.baseUrl, 'https://b/v1');
  assert.equal(stored.model, 'big-model');
  assert.equal(stored.apiKey, 'new-key');
  assert.equal(stored.contextWindow, 264000, 'window override survives the save');
  assert.equal(stored.contextWindowCap, 128000, 'cap survives the save');
  assert.deepEqual(plain(stored.headers), { 'x-project': 'codemie-42' }, 'headers survive the save');
  assert.equal(h.boots.length, 1, 'the agent reboots once');
  assert.equal(h.boots[0].provider.contextWindow, 264000, 'boot config carries the window');
  assert.deepEqual(plain(h.boots[0].provider.headers), { 'x-project': 'codemie-42' });
});

test('gh-2425: an explicit contextWindow in the save wins, string-encoded too', async () => {
  const h = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 128000 });
  await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 264000 });
  assert.equal(h.data.faProvider.contextWindow, 264000);

  const h2 = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 128000 });
  await h2.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: '264000' });
  assert.equal(h2.data.faProvider.contextWindow, 264000, 'the panel sends strings');

  const h3 = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 128000 });
  await h3.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: '  1000000 ' });
  assert.equal(h3.data.faProvider.contextWindow, 1000000, 'blank-padded strings parse');

  const h4 = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 128000 });
  await h4.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 'not-a-number' });
  assert.equal(h4.data.faProvider.contextWindow, 128000, 'garbled input keeps the stored value');

  const h5 = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: 128000 });
  await h5.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', contextWindow: '' });
  assert.equal(h5.data.faProvider.contextWindow, 128000, 'a blank field means keep, not clear');
});

test('gh-2425: header lines are parsed to an object — multiple entries, garbage skipped', async () => {
  const h = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm' });
  const reply = await h.send({
    type: 'provider.save',
    baseUrl: 'https://a/v1',
    apiKey: 'k',
    model: 'm',
    headers: 'X-Copilot-Integration-Id: vscode-chat\nauthorization: Bearer abc\nnot-a-header-line\n\n x-empty: ',
  });
  assert.equal(reply.ok, true);
  assert.deepEqual(plain(h.data.faProvider.headers), {
    'x-copilot-integration-id': 'vscode-chat',
    authorization: 'Bearer abc',
  }, 'name: value per line; colon-less and empty-value lines dropped; names lowercased');

  // An object payload (the v2 UI protocol shape) is stored as-is (sanitized).
  const h2 = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm' });
  await h2.send({
    type: 'provider.save',
    baseUrl: 'https://a/v1',
    apiKey: 'k',
    model: 'm',
    headers: { 'x-a': '1', 'x-drop': 42, '': 'nope', 'x-keep': 'yes' },
  });
  assert.deepEqual(plain(h2.data.faProvider.headers), { 'x-a': '1', 'x-keep': 'yes' });
});

test('gh-2425: a save without headers keeps the stored headers; empty string keeps too', async () => {
  const h = boot({ baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', headers: { 'x-stored': 'yes' } });
  await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm' });
  assert.deepEqual(plain(h.data.faProvider.headers), { 'x-stored': 'yes' });

  await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'k', model: 'm', headers: '' });
  assert.deepEqual(plain(h.data.faProvider.headers), { 'x-stored': 'yes' }, 'blank header text = keep');
});

test('gh-2425: provider.get answers every field except the apiKey', async () => {
  const h = boot({
    baseUrl: 'https://a/v1',
    apiKey: 'sekret',
    model: 'm',
    contextWindow: 264000,
    contextWindowCap: 128000,
    headers: { 'x-project': 'p' },
  });
  const reply = await h.send({ type: 'provider.get' });
  assert.equal(reply.ok, true);
  assert.equal(reply.provider.baseUrl, 'https://a/v1');
  assert.equal(reply.provider.model, 'm');
  assert.equal(reply.provider.contextWindow, 264000);
  assert.equal(reply.provider.contextWindowCap, 128000);
  assert.deepEqual(plain(reply.provider.headers), { 'x-project': 'p' });
  assert.equal('apiKey' in reply.provider, false, 'the key never crosses into the UI');
  assert.equal(JSON.stringify(reply).includes('sekret'), false, 'the key bytes never leave the worker');
});

test('gh-2425: provider.get with nothing stored answers an empty provider', async () => {
  const h = boot();
  const reply = await h.send({ type: 'provider.get' });
  assert.equal(reply.ok, true);
  assert.equal(reply.provider.baseUrl, '');
  assert.equal(reply.provider.model, '');
  assert.deepEqual(plain(reply.provider.headers), {});
});

test('gh-2425: a model-less save keeps the stored model (merge contract parity)', async () => {
  // The Dart settings_put merge keeps stored values for empty incoming
  // fields; the v1 save must not regress to wiping them either.
  const h = boot({ baseUrl: 'https://a/v1', apiKey: 'stored-key', model: 'glm-5' });
  const reply = await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: '', model: '' });
  assert.equal(reply.ok, true);
  assert.equal(h.data.faProvider.model, 'glm-5');
  assert.equal(h.data.faProvider.apiKey, 'stored-key', 'a key the user did not retype is not wiped');
});

// gh-2425 rework review (PRT_kwDOTXdlLc68lzcU, BLOCKING): the per-key union
// made header deletions impossible — a stored authorization header kept
// riding every request to a NEW endpoint after the user deleted its line.
test('gh-2425 rework: a save with a reduced header set REPLACES the stored set — deletions stick', async () => {
  const h = boot({
    baseUrl: 'https://a/v1',
    apiKey: 'stored-key',
    model: 'm',
    headers: { authorization: 'Bearer secret-token', 'x-old': '1' },
  });
  // The user deleted the authorization + x-old lines and typed one new header.
  await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'new-key', model: 'm', headers: 'x-new: yes' });
  assert.deepEqual(
    plain(h.data.faProvider.headers),
    { 'x-new': 'yes' },
    'replace-by-presence: stored keys the incoming set drops are gone (Dart settings_put parity)',
  );

  // The documented blank-keeps-stored behavior still holds after a replacement.
  await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'new-key', model: 'm', headers: '' });
  assert.deepEqual(plain(h.data.faProvider.headers), { 'x-new': 'yes' }, 'blank header text still means keep');
});

// gh-2425 rework review (PRT_kwDOTXdlLc68lzfa, SUGGESTION): the Dart reader
// only accepts positive ints (storedIntSetting int.tryParse + the
// windowSettingsFromStored > 0 guard) — a stored float/negative override
// never applies, so storing it silently is a save-succeeded-does-nothing trap.
test('gh-2425 rework: non-integral / non-positive contextWindow input falls back to stored', async () => {
  const bads = ['264000.5', '-5', '0', 264000.5, -5, 0];
  for (const bad of bads) {
    const h = boot({ baseUrl: 'https://a/v1', apiKey: 'stored-key', model: 'm', contextWindow: 128000 });
    await h.send({ type: 'provider.save', baseUrl: 'https://a/v1', apiKey: 'new-key', model: 'm', contextWindow: bad });
    assert.equal(
      h.data.faProvider.contextWindow,
      128000,
      `contextWindow ${JSON.stringify(bad)} is dropped (Dart parity), stored value survives`,
    );
    assert.equal(
      h.boots[0].provider.contextWindow,
      128000,
      `boot config carries the surviving window, not ${JSON.stringify(bad)}`,
    );
  }
});

test('gh-2425 rework: provider.get drops a non-integral stored window (read-back parity)', async () => {
  // Storage garbage from a pre-fix save must read like the Dart reader reads
  // it: dropped (UI answers the 0 = no-override encoding).
  const h = boot({ baseUrl: 'https://a/v1', apiKey: 'stored-key', model: 'm', contextWindow: 264000.5 });
  const reply = await h.send({ type: 'provider.get' });
  assert.equal(reply.ok, true);
  assert.equal(reply.provider.contextWindow, 0, 'a stored double is dropped, not echoed into the panel');
});
