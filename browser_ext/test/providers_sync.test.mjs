// sw/bridge.js providers-sync + keyless llm relay tests (issue #34 item 3):
// bridge.js runs in a vm sandbox against a WebSocket stub; hello carries the
// providers-sync capability, sync frames land in chrome.storage.local
// (merged through the Dart agent when present, acked in copy mode), proxy
// mode NEVER lets key bytes touch storage (UT-S1), and sendLlm correlates
// llmRes frames — a dropped link rejects with "desktop link is down" (E26).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const swDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'sw');
const src = readFileSync(join(swDir, 'bridge.js'), 'utf8');

const tick = () => new Promise((r) => setTimeout(r, 0));

/** Storage stub: local persists into `map`, session is absent (mem fallback). */
function storageStub(map) {
  return {
    local: {
      async get(keys) {
        const out = {};
        for (const k of [].concat(keys ?? [])) if (k in map) out[k] = map[k];
        return out;
      },
      async set(o) { Object.assign(map, JSON.parse(JSON.stringify(o))); },
      async remove(keys) { for (const k of [].concat(keys)) delete map[k]; },
    },
  };
}

/** Sandbox with a WebSocket stub; every sent frame is recorded in `sent`. */
function boot({ faAgent } = {}) {
  const map = {}; // chrome.storage.local backing
  const sent = [];
  const sockets = [];
  class WsStub {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      sockets.push(this);
    }
    send(data) { sent.push(JSON.parse(data)); }
    close() { this.readyState = 3; }
  }
  const sandbox = {
    console,
    crypto: webcrypto,
    WebSocket: WsStub,
    chrome: { storage: storageStub(map), alarms: { create() {} } },
    setTimeout,
    clearTimeout,
    // The ping keepalive would hold the node process open for its full
    // 20s interval after the tests finish — stub it out; ping timing is
    // not under test here.
    setInterval: () => 0,
    clearInterval: () => {},
    Date,
    JSON,
    Promise,
    Error,
    Map,
    Set,
    Array,
    Object,
  };
  if (faAgent) sandbox.faAgent = faAgent;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'bridge.js' });
  return { sandbox, map, sent, sockets };
}

/** Feed one wire frame the way the browser would (MessageEvent.data). */
const feed = (ws, frame) => ws.onmessage({ data: JSON.stringify(frame) });

/** Pair + finish the handshake; returns the open socket. */
async function connected({ sandbox, sockets }, url = 'ws://127.0.0.1:8777/ws') {
  await sandbox.faSw.bridge.connect(url, 'tok');
  const ws = sockets.at(-1);
  ws.readyState = 1;
  await ws.onopen();
  feed(ws, { v: 1, id: 'w1', op: 'welcome', mailbox: 'mb' });
  return ws;
}

test('hello advertises the providers-sync capability', async () => {
  const ctx = boot();
  await ctx.sandbox.faSw.bridge.connect('ws://x', 'tok');
  const ws = ctx.sockets.at(-1);
  ws.readyState = 1;
  await ws.onopen();
  const hello = ctx.sent.find((f) => f.op === 'hello');
  assert.ok(hello, 'hello sent');
  assert.ok(hello.caps.includes('providers-sync'), 'caps include providers-sync');
});

test('copy-mode sync: merged doc stored, keys ride once, acked echoes the sync frame id', async (t) => {
  const ctx = boot({
    faAgent: {
      // Stand-in for the Dart providersMerge: keeps the local edit alive.
      async providersMerge(prev, next) {
        t.diagnostic?.('merge called');
        ctx.mergedWith = { prev, next };
        return {
          ...next,
          providers: [
            ...next.providers,
            { name: 'mine', baseUrl: 'http://x', modelId: 'm', provenance: 'local' },
          ],
        };
      },
    },
  });
  const ws = await connected(ctx);
  const syncId = 'sync-42';
  feed(ws, {
    v: 1, id: syncId, op: 'providersSync',
    sync: {
      version: 1, mode: 'copy', host: 'desk',
      providers: [{ name: 'p1', apiType: 'openai', baseUrl: 'https://a/v1', modelId: 'gpt', provenance: 'synced-from-cli@desk' }],
      keys: { p1: 'sk-COPY-SECRET' },
    },
  });
  await tick();
  const doc = ctx.map.faProviders;
  assert.equal(doc.mode, 'copy');
  assert.equal(doc.keys.p1, 'sk-COPY-SECRET', 'copy keys land in storage');
  assert.ok(doc.providers.some((p) => p.name === 'mine'), 'local entry survived merge (UT-S2)');
  assert.equal(ctx.mergedWith.prev, undefined, 'no prior doc passed');
  const ack = ctx.sent.find((f) => f.op === 'acked');
  assert.ok(ack, 'copy mode acked');
  assert.equal(ack.id, syncId, 'ack echoes the sync frame id');
});

test('re-pair without the agent (scaffold SW): raw sync lands as-is, still acked in copy mode', async () => {
  const ctx = boot(); // no faAgent
  const ws = await connected(ctx);
  feed(ws, {
    v: 1, id: 's2', op: 'providersSync',
    sync: { version: 1, mode: 'copy', host: 'desk', providers: [{ name: 'p1', baseUrl: 'https://a', modelId: 'm', provenance: 'synced-from-cli@desk' }], keys: { p1: 'k' } },
  });
  await tick();
  assert.equal(ctx.map.faProviders.providers.length, 1);
  assert.ok(ctx.sent.some((f) => f.op === 'acked' && f.id === 's2'));
});

test('UT-S1: proxy-mode keys NEVER touch storage (byte-scan over everything stored)', async () => {
  const ctx = boot();
  const ws = await connected(ctx);
  feed(ws, {
    v: 1, id: 's3', op: 'providersSync',
    sync: {
      version: 1, mode: 'proxy', host: 'desk',
      providers: [{ name: 'p1', apiType: 'openai', baseUrl: 'https://a/v1', modelId: 'gpt', provenance: 'synced-from-cli@desk' }],
      keys: { p1: 'sk-BYTESCAN-SECRET-xyz' },
    },
  });
  await tick();
  const everything = JSON.stringify(ctx.map);
  assert.ok(!everything.includes('sk-BYTESCAN-SECRET-xyz'), 'no key byte anywhere in storage');
  assert.equal(ctx.map.faProviders.mode, 'proxy');
  assert.equal(ctx.map.faProviders.keys, undefined, 'keys field dropped');
  assert.ok(ctx.map.faProviders.providers[0].provenance.startsWith('synced-from-cli@'));
  assert.ok(!ctx.sent.some((f) => f.op === 'acked'), 'proxy mode does not ack');
});

test('sendLlm streams deltas over llmReq/llmRes and resolves on done', async () => {
  const ctx = boot();
  const ws = await connected(ctx);
  const deltas = [];
  const done = ctx.sandbox.faSw.bridge.sendLlm(
    { baseUrl: 'https://a/v1', model: 'gpt', messages: [{ role: 'user', content: 'hi' }] },
    (d) => deltas.push(d),
  );
  await tick();
  const req = ctx.sent.find((f) => f.op === 'llmReq');
  assert.ok(req, 'llmReq sent');
  assert.equal(req.req.model, 'gpt');
  const id = req.id;
  feed(ws, { v: 1, id, op: 'llmRes', delta: 'he' });
  feed(ws, { v: 1, id, op: 'llmRes', delta: 'llo' });
  feed(ws, { v: 1, id, op: 'llmRes', done: true });
  await done;
  assert.deepEqual(deltas, ['he', 'llo']);
});

test('sendLlm rejects on an error frame and ignores frames for unknown ids', async () => {
  const ctx = boot();
  const ws = await connected(ctx);
  const p = ctx.sandbox.faSw.bridge.sendLlm({ model: 'm', messages: [] }, () => {});
  await tick();
  const id = ctx.sent.find((f) => f.op === 'llmReq').id;
  feed(ws, { v: 1, id: 'other', op: 'llmRes', done: true }); // unknown id — no-op
  feed(ws, { v: 1, id, op: 'llmRes', error: 'upstream 401' });
  await assert.rejects(p, /upstream 401/);
});

test('E26: sendLlm while disconnected rejects "desktop link is down"; a mid-stream drop rejects cleanly', async () => {
  const ctx = boot();
  await assert.rejects(
    ctx.sandbox.faSw.bridge.sendLlm({ model: 'm', messages: [] }, () => {}),
    /desktop link is down/,
  );
  const ws = await connected(ctx);
  const p = ctx.sandbox.faSw.bridge.sendLlm({ model: 'm', messages: [] }, () => {});
  await tick();
  ws.onclose(); // link drops mid-stream
  await assert.rejects(p, /desktop link is down/);
});
