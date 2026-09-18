// Issue #470 AC1/AC2: the SW fetch bridge — page → embed_relay.js → SW pump
// → fetch → back, driven end-to-end across two vm sandboxes wired the way the
// real extension wires them (the relay's chrome.runtime.connect lands on the
// fetch_bridge onConnect handler through a two-sided fake Port pair).
//
// AC1: a request through the bridge returns status + body.
// AC2: a streaming response delivers chunks in order, exactly one end frame —
//      the tail chunk is never dropped.
// E2:  an upstream failure becomes one clean err frame, not a hang.
// E4:  a dying port aborts the upstream fetch.
// AC6: ordinary page traffic and foreign-window messages never reach the SW.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

/**
 * A relay-side Port and the SW-side Port it is wired to, like the two ends of
 * a real chrome.runtime.connect pair: postMessage on one side fans out to the
 * other side's message listeners; disconnect() fires the other side's
 * disconnect listeners.
 */
function connectPair(onConnectHandler) {
  const relayMsg = [], relayDisc = [], swMsg = [], swDisc = [];
  const relayPort = {
    name: 'fa.http.stream',
    onMessage: { addListener: (fn) => relayMsg.push(fn) },
    onDisconnect: { addListener: (fn) => relayDisc.push(fn) },
    postMessage: (frame) => swMsg.forEach((fn) => fn(frame)),
    disconnect: () => swDisc.forEach((fn) => fn()),
  };
  const swPort = {
    name: 'fa.http.stream',
    onMessage: { addListener: (fn) => swMsg.push(fn) },
    onDisconnect: { addListener: (fn) => swDisc.push(fn) },
    postMessage: (frame) => relayMsg.forEach((fn) => fn(frame)),
    disconnect: () => relayDisc.forEach((fn) => fn()),
  };
  onConnectHandler(swPort);
  return {
    relayPort,
    swPost: (frame) => relayMsg.forEach((fn) => fn(frame)),
    disconnectRelayPort: () => swDisc.forEach((fn) => fn()),
  };
}

/** Boot fetch_bridge.js; returns its onConnect handler + fetch signals seen. */
function bootBridge(fetchImpl) {
  const signals = [];
  let onConnect;
  const sandbox = {
    console,
    btoa,
    atob,
    AbortController,
    setInterval,
    clearInterval,
    setTimeout,
    fetch: async (url, init) => {
      signals.push(init?.signal);
      return fetchImpl(url, init);
    },
    chrome: { runtime: { onConnect: { addListener: (fn) => (onConnect = fn) } } },
    FA_KEEPALIVE_MS: 20,
  };
  vm.runInNewContext(src('sw/fetch_bridge.js'), sandbox, { filename: 'fetch_bridge.js' });
  assert.equal(typeof onConnect, 'function', 'fetch_bridge registers its port handler');
  return { onConnect, signals };
}

/** Boot embed_relay.js with a fake page window whose chrome.runtime.connect
 *  hands each port to the REAL fetch_bridge onConnect handler. */
function bootRelay(onConnect) {
  const winListeners = {};
  const pageReplies = [];
  const win = {
    addEventListener: (type, fn) => (winListeners[type] = fn),
    postMessage: (msg) => pageReplies.push(msg),
    location: { origin: 'https://fa1.dev' },
  };
  const chrome = {
    runtime: {
      connect: () => connectPair(onConnect).relayPort,
    },
  };
  const sandbox = { window: win, chrome };
  vm.runInNewContext(src('content/embed_relay.js'), sandbox, { filename: 'embed_relay.js' });
  return {
    fromPage(msg) {
      winListeners.message({ source: win, data: msg });
    },
    fromOtherWindow(msg) {
      winListeners.message({ source: {}, data: msg });
    },
    frames: () => pageReplies.filter((m) => m.__faEmbedRes === 1).map((m) => m.frame),
    pongs: () => pageReplies.filter((m) => m.__faEmbedRes === 1 && m.pong).length,
  };
}

const jsonResponse = (body) => ({
  status: 200,
  headers: { entries: () => Object.entries({ 'content-type': 'application/json' }) },
  body: {
    getReader: () => {
      const enc = new TextEncoder();
      let done = false;
      return {
        read: async () => {
          if (done) return { done: true };
          done = true;
          return { done: false, value: enc.encode(body) };
        },
      };
    },
  },
});

const flush = () => new Promise((r) => setImmediate(r));

test('AC1: bridged fetch returns status + body through the SW', async () => {
  const { onConnect } = bootBridge(async () => jsonResponse('{"ok":true}'));
  const relay = bootRelay(onConnect);
  relay.fromPage({
    __faEmbed: 1,
    kind: 'stream',
    reqId: 'r1',
    req: {
      url: 'https://api.z.ai/api/coding/paas/v4/chat/completions',
      method: 'POST',
      headers: { Authorization: 'Bearer k' },
      bodyB64: btoa('hello'),
    },
  });
  await flush();
  const frames = relay.frames();
  const head = frames.find((f) => f.t === 'head');
  assert.equal(head.status, 200);
  assert.equal(head.headers['content-type'], 'application/json');
  const body = frames.filter((f) => f.t === 'chunk').map((f) => atob(f.b64)).join('');
  assert.equal(body, '{"ok":true}');
  assert.equal(frames.at(-1).t, 'end', 'explicit end frame — the tail never drops');
});

test('AC2: SSE stream delivers ordered chunks then exactly one end frame', async () => {
  const enc = new TextEncoder();
  const chunks = ['data: {"delta":"a"}\n\n', 'data: {"delta":"b"}\n\n', 'data: [DONE]\n\n'].map((s) => enc.encode(s));
  const expected = ['data: {"delta":"a"}\n\n', 'data: {"delta":"b"}\n\n', 'data: [DONE]\n\n'];
  const { onConnect } = bootBridge(async () => ({
    status: 200,
    headers: { entries: () => Object.entries({ 'content-type': 'text/event-stream' }) },
    body: {
      getReader: () => {
        let i = 0;
        return { read: async () => (i < chunks.length ? { done: false, value: chunks[i++] } : { done: true }) };
      },
    },
  }));
  const relay = bootRelay(onConnect);
  relay.fromPage({ __faEmbed: 1, kind: 'stream', reqId: 'r1', req: { url: 'https://p/v1/chat/completions' } });
  await flush();
  const frames = relay.frames();
  assert.equal(frames.filter((f) => f.t === 'head').length, 1);
  assert.deepEqual(
    frames.filter((f) => f.t === 'chunk').map((f) => atob(f.b64)),
    ['data: {"delta":"a"}\n\n', 'data: {"delta":"b"}\n\n', 'data: [DONE]\n\n'],
    'chunks arrive in order, byte-exact',
  );
  assert.equal(frames.filter((f) => f.t === 'end').length, 1);
  assert.equal(frames.at(-1).t, 'end', 'no dropped tail chunk');
});

test('E2: upstream fetch failure is one clean err frame, not a hang', async () => {
  const { onConnect } = bootBridge(async () => {
    throw new TypeError('Failed to fetch');
  });
  const relay = bootRelay(onConnect);
  relay.fromPage({ __faEmbed: 1, kind: 'stream', reqId: 'r1', req: { url: 'https://revoked.host/v1' } });
  await flush();
  const frames = relay.frames();
  assert.equal(frames.length, 1);
  assert.match(frames[0].error, /Failed to fetch/);
});

test('E2 keepalive: a stalling upstream still emits Port activity, then a '
    + 'clean end', async () => {
  // An upstream that emits one chunk, then stalls longer than the
  // keepalive interval: the frames keep flowing (the real SW stays alive),
  // and the stream still ends cleanly when the upstream resumes.
  let releaseReader;
  const stalled = new Promise((resolve) => { releaseReader = resolve; });
  let reads = 0;
  const { onConnect } = bootBridge(async () => ({
    status: 200,
    headers: { entries: () => Object.entries({}) },
    body: {
      getReader: () => ({
        read: async () => {
          if (reads++ === 0) {
            return { done: false, value: new TextEncoder().encode('data: 1\n\n') };
          }
          await stalled;
          return { done: true };
        },
      }),
    },
  }));
  const relay = bootRelay(onConnect);
  relay.fromPage({ __faEmbed: 1, kind: 'stream', reqId: 'r1', req: { url: 'https://slow.host/v1' } });
  await flush();
  const before = relay.frames().filter((f) => f.t === 'keepalive').length;
  await new Promise((r) => setTimeout(r, 60));
  const during = relay.frames().filter((f) => f.t === 'keepalive').length;
  releaseReader();
  await flush();
  const frames = relay.frames();
  assert.ok(during > before, 'keepalive frames flowed while upstream stalled');
  assert.equal(frames.filter((f) => f.t === 'end').length, 1);
  assert.equal(frames.at(-1).t, 'end', 'stream still ends cleanly');
});

test('E4: relay port death aborts the upstream fetch', async () => {
  let abortToPromise;
  const { onConnect, signals } = bootBridge(async (_url, init) => {
    abortToPromise = new Promise((resolve) => {
      init.signal.addEventListener('abort', () => resolve({ name: 'AbortError' }));
    });
    return {
      status: 200,
      headers: { entries: () => Object.entries({}) },
      body: { getReader: () => ({ read: () => abortToPromise.then(() => ({ done: true })) }) },
    };
  });
  const relay = bootRelay(onConnect);
  relay.fromPage({ __faEmbed: 1, kind: 'stream', reqId: 'r1', req: { url: 'https://x/v1' } });
  await flush();
  assert.equal(relay.frames().filter((f) => f.t === 'head').length, 1);
  // OWA nukes the frame: the page abort tears the relay's port down and the
  // SW pump aborts the upstream fetch.
  relay.fromPage({ __faEmbed: 1, kind: 'abort', reqId: 'r1' });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(signals.length, 1);
  assert.equal(signals[0].aborted, true, 'upstream fetch aborted, no retries into the corpse');
});

test('AC6 gating: ordinary page traffic and foreign windows never reach the SW', () => {
  let fetches = 0;
  const { onConnect } = bootBridge(async () => {
    fetches++;
    throw new Error('must not fetch');
  });
  const relay = bootRelay(onConnect);
  relay.fromPage({ hello: 'ordinary page traffic' });
  relay.fromOtherWindow({ __faEmbed: 1, kind: 'stream', reqId: 'x', req: { url: 'https://x' } });
  relay.fromPage({ __faEmbed: 1, kind: 'ping', reqId: 'p' });
  assert.equal(fetches, 0, 'no SW fetch for non-embed traffic');
  assert.equal(relay.pongs(), 1, 'exactly one pong for the embed ping');
});
