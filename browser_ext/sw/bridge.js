(() => { // Classic-SW module scope: nothing leaks into the shared importScripts global (a top-level const here once collided with main.js and killed SW boot).
// WebSocket transport for the fa bridge — client side of wire protocol v1
// (see local://bridge_contract.md). Owns: hello handshake, reconnect backoff,
// offline mail queue, msgId dedupe, ping keepalive, status events.
const KEEPALIVE_ALARM = 'fa-bridge-keepalive';
const BACKOFF_BASE_MS = 1000;
const BACKOFF_MAX_MS = 30000;
const QUEUE_CAP = 100;
const DEDUPE_CAP = 512;
const PING_MS = 20000;
const QKEY = 'faQueue';

// chrome.storage.session is Chrome 102+; fall back to memory (queue then
// survives reconnects but not SW death).
const session = chrome.storage.session ?? memSession();

const state = {
  ws: null,
  cfg: null, // {url, token} once paired
  agentId: null,
  phase: 'unpaired', // unpaired | connecting | connected | reconnecting | disconnected
  attempt: 0,
  nextAttemptAt: 0,
  retryTimer: null,
  pingTimer: null,
  lastPong: 0,
  lastError: null,
  mailbox: null,
  server: null,
  queue: [],
  acks: new Map(), // mail frame id -> {resolve, reject}
  seen: new Set(),
  seenOrder: [],
  statusSubs: [],
  mailSubs: [],
  reqHandler: null,
  llmWaiters: new Map(), // llmReq frame id -> {onDelta, resolve, reject}
};

function memSession() {
  const m = new Map();
  return {
    async get(k) { return { [k]: m.get(k) }; },
    async set(o) { for (const [k, v] of Object.entries(o)) m.set(k, v); },
  };
}

const frameId = () =>
  `${Date.now()}-${[...crypto.getRandomValues(new Uint8Array(4))].map((b) => b.toString(16).padStart(2, '0')).join('')}`;

const send = (obj) => {
  if (state.ws?.readyState === 1) state.ws.send(JSON.stringify(obj));
};

const saveQueue = () => session.set({ [QKEY]: state.queue }).catch(() => {});

/** Stable instance id, generated once and persisted. */
async function agentId() {
  if (state.agentId) return state.agentId;
  const { faAgentId } = await chrome.storage.local.get('faAgentId');
  state.agentId = faAgentId || crypto.randomUUID();
  if (!faAgentId) await chrome.storage.local.set({ faAgentId: state.agentId });
  return state.agentId;
}

function snapshot() {
  return {
    phase: state.phase,
    bridgeUrl: state.cfg?.url ?? null,
    agentId: state.agentId,
    mailbox: state.mailbox,
    server: state.server,
    reason: state.lastError,
    queueLen: state.queue.length,
  };
}

function emit() {
  const s = snapshot();
  for (const cb of state.statusSubs) cb(s);
}

function rejectAcks(reason) {
  for (const { reject } of state.acks.values()) reject(new Error(reason));
  state.acks.clear();
}

function stopPing() {
  clearInterval(state.pingTimer);
  state.pingTimer = null;
}

function startPing() {
  stopPing();
  state.pingTimer = setInterval(() => {
    if (state.phase !== 'connected') return stopPing();
    // Stale link (no pong for two intervals): force close, reconnect path takes over.
    if (Date.now() - state.lastPong > PING_MS * 2) return state.ws?.close();
    send({ v: 1, id: frameId(), op: 'ping' });
  }, PING_MS);
}

/** Terminal failure: stop retrying, surface reason (e.g. bad_token). */
function permanent(reason) {
  rejectLlmWaiters();
  state.phase = 'disconnected';
  state.lastError = reason;
  stopPing();
  clearTimeout(state.retryTimer);
  state.retryTimer = null;
  if (state.ws) {
    const ws = state.ws;
    state.ws = null;
    ws.onclose = ws.onmessage = ws.onerror = null;
    ws.close();
  }
  rejectAcks(reason);
  emit();
}

function scheduleRetry() {
  // Clamp BEFORE shift: 1s doubling capped at 30s.
  const delay = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** state.attempt);
  state.attempt++;
  state.nextAttemptAt = Date.now() + delay;
  state.retryTimer = setTimeout(openSocket, delay);
}

function onSocketClose() {
  rejectLlmWaiters();
  state.ws = null;
  stopPing();
  if (!state.cfg || state.phase === 'disconnected') return; // deliberate or terminal
  state.phase = 'reconnecting';
  state.lastError = state.lastError || 'connection lost';
  emit();
  scheduleRetry();
}

function openSocket() {
  if (!state.cfg) return;
  clearTimeout(state.retryTimer);
  state.retryTimer = null;
  if (state.ws && state.ws.readyState <= 1) return; // already open/opening
  state.phase = state.attempt > 0 ? 'reconnecting' : 'connecting';
  emit();
  const ws = new WebSocket(state.cfg.url);
  state.ws = ws;
  ws.onopen = async () => {
    send({
      v: 1,
      id: frameId(),
      op: 'hello',
      agentId: await agentId(),
      name: 'fa — browser agent',
      proto: 1,
      token: state.cfg.token,
      caps: ['tabs', 'dom', 'cdp', 'providers-sync'],
    });
  };
  ws.onmessage = (ev) => handleFrame(ev.data);
  ws.onclose = onSocketClose;
  ws.onerror = () => {}; // onclose always follows
}

function onWelcome(f) {
  state.attempt = 0;
  state.nextAttemptAt = 0;
  state.phase = 'connected';
  state.mailbox = f.mailbox ?? null;
  state.server = f.server ?? null;
  state.lastError = null;
  state.lastPong = Date.now();
  startPing();
  emit();
  // Drain outbox oldest-first (E18).
  for (const item of [...state.queue]) {
    send({ v: 1, id: item.id, op: 'mail', to: item.to, text: item.text, kind: item.kind });
  }
}

function onErrorFrame(f) {
  if (f.code === 'bad_token') return permanent('bad token — run /browser connect again');
  if (f.code === 'proto') return permanent(`protocol error: ${f.error || 'version mismatch'}`);
  state.lastError = f.error || f.code || 'server error';
  emit();
}

/** Bounded LRU dedupe for inbound msgIds (AC18). Returns true when fresh. */
function seenAdd(msgId) {
  if (state.seen.has(msgId)) return false;
  state.seen.add(msgId);
  state.seenOrder.push(msgId);
  while (state.seenOrder.length > DEDUPE_CAP) state.seen.delete(state.seenOrder.shift());
  return true;
}

/** Reject every pending llm relay waiter — the link is gone. */
function rejectLlmWaiters(reason = 'desktop link is down') {
  for (const waiter of state.llmWaiters.values()) waiter.reject(new Error(reason));
  state.llmWaiters.clear();
}

/** Providers sync push (issue #34 item 3): store the registry + ack copy mode. */
async function onProvidersSync(f) {
  const sync = f.sync ?? {};
  // UT-S1: proxy mode NEVER carries keys into storage — the field is
  // dropped here before anything else runs. Copy mode rides its `keys`
  // field once; the server wipes its staged copy when we ack below.
  const stored = {
    version: sync.version ?? 1,
    mode: sync.mode,
    host: sync.host,
    providers: Array.isArray(sync.providers) ? sync.providers : [],
  };
  if (sync.mode === 'copy' && sync.keys && typeof sync.keys === 'object') {
    stored.keys = sync.keys;
  }
  // The agent owns merge semantics: provenance-`local` entries (panel
  // edits, .fahx imports) survive re-pairs (UT-S2). Scaffold mode (no
  // agent.js) has no local entries to protect — sync lands as-is.
  const prev = (await chrome.storage.local.get('faProviders')).faProviders;
  let doc = stored;
  try {
    const merged = await globalThis.faAgent?.providersMerge?.(prev, stored);
    if (merged && typeof merged === 'object') doc = merged;
  } catch {
    // A merge failure must not block the sync or the ack.
  }
  await chrome.storage.local.set({ faProviders: doc });
  if (sync.mode === 'copy') send({ v: 1, id: f.id, op: 'acked' }); // echo wipes server staging
}

async function handleFrame(raw) {
  let f;
  try { f = JSON.parse(raw); } catch { return; }
  if (f.v !== 1) return permanent(`protocol version mismatch (got v=${f.v})`);
  switch (f.op) {
    case 'welcome': return onWelcome(f);
    case 'pong': return void (state.lastPong = Date.now());
    case 'error': return onErrorFrame(f);
    case 'providersSync': return onProvidersSync(f);
    case 'llmRes': {
      const waiter = state.llmWaiters.get(f.id);
      if (!waiter) return;
      if (f.error !== undefined) {
        state.llmWaiters.delete(f.id);
        return waiter.reject(new Error(f.error || 'relay failed'));
      }
      if (f.done) {
        state.llmWaiters.delete(f.id);
        return waiter.resolve();
      }
      return waiter.onDelta?.(f.delta ?? '');
    }
    case 'acked': {
      const ackId = f.ackId ?? f.id;
      const waiter = state.acks.get(ackId);
      if (!waiter) return;
      state.acks.delete(ackId);
      state.queue = state.queue.filter((m) => m.id !== ackId);
      saveQueue();
      return waiter.resolve();
    }
    case 'mail':
      if (seenAdd(f.msgId ?? f.id)) for (const cb of state.mailSubs) cb(f);
      return;
    case 'browserReq':
      if (state.reqHandler) return state.reqHandler(f);
      return browserRes(f.id, { ok: false, error: 'no dispatcher registered', code: 'no_target' });
    default: return;
  }
}

/** chrome.alarms tick: re-arm ping after SW restart, retry within backoff budget. */
function onKeepalive() {
  if (!state.cfg) return;
  if (state.phase === 'connected') {
    if (!state.pingTimer) startPing();
    return;
  }
  if (Date.now() >= state.nextAttemptAt) openSocket();
}

const bridge = {
  KEEPALIVE_ALARM,

  /** Pair with a server: store cfg, open socket, start hello handshake. */
  async connect(url, token) {
    if (state.ws) {
      const ws = state.ws;
      state.ws = null;
      ws.onclose = ws.onmessage = ws.onerror = null;
      ws.close();
    }
    rejectLlmWaiters(); // a re-pair never leaves stale relay waiters hanging
    clearTimeout(state.retryTimer);
    state.retryTimer = null;
    state.cfg = { url, token };
    state.attempt = 0;
    state.phase = 'connecting';
    state.lastError = null;
    state.mailbox = state.server = null;
    const o = await session.get(QKEY);
    if (Array.isArray(o?.[QKEY])) state.queue = o[QKEY];
    emit();
    openSocket();
  },

  /** Tear down everything (unpair). Queue is dropped with the pairing. */
  async disconnect() {
    state.cfg = null;
    permanent('unpaired');
    state.phase = 'unpaired';
    state.lastError = null;
    state.queue = [];
    await saveQueue();
    emit();
  },

  /**
   * Queue (cap 100) and send a mail frame; resolves on server ack.
   * ponytail: full queue drops the OLDEST mail — mailbox semantics favour
   * keeping the newest; switch to reject-newest if the agent prefers.
   */
  async sendMail(to, text, kind = 'text') {
    if (!state.cfg) {
      throw Object.assign(new Error('unpaired — connect first'), { code: 'no_target' });
    }
    const item = { id: frameId(), to, text, kind };
    state.queue.push(item);
    while (state.queue.length > QUEUE_CAP) {
      const dropped = state.queue.shift();
      state.acks.get(dropped.id)?.reject(new Error('outbox full — dropped oldest'));
      state.acks.delete(dropped.id);
      state.lastError = 'outbox full — dropped oldest mail';
    }
    saveQueue();
    if (state.phase === 'connected') {
      send({ v: 1, id: item.id, op: 'mail', to, text, kind });
    }
    return new Promise((resolve, reject) => state.acks.set(item.id, { resolve, reject }));
  },

  /**
   * Keyless LLM relay (issue #34 item 3): sends one llmReq frame and
   * correlates the streamed llmRes frames. `onDelta` fires per text
   * chunk; the promise resolves on `done` and rejects on `error` or a
   * dropped link ("desktop link is down"). All frame glue lives here —
   * callers stream deltas and await.
   */
  sendLlm(req, onDelta) {
    if (state.phase !== 'connected') {
      return Promise.reject(new Error('desktop link is down'));
    }
    const id = frameId();
    return new Promise((resolve, reject) => {
      state.llmWaiters.set(id, { onDelta, resolve, reject });
      send({ v: 1, id, op: 'llmReq', req });
    });
  },

  /** Subscribe to inbound fabric mail. */
  onMail(cb) { state.mailSubs.push(cb); },

  /** Subscribe to connection status snapshots (panel). */
  onStatus(cb) { state.statusSubs.push(cb); },

  /** Register the single browserReq handler (ops dispatcher). */
  onBrowserReq(cb) { state.reqHandler = cb; },

  /** Answer a browserReq exactly once. `out` is {ok, result?} or {ok:false, error, code?}. */
  browserRes(reqId, out) {
    send({ v: 1, id: reqId, op: 'browserRes', ...out });
  },

  /** Status snapshot for the panel / tests. */
  status: snapshot,

  onKeepalive,
};

// Classic-SW module glue (see tabs.js).
globalThis.faSw = Object.assign(globalThis.faSw ?? {}, { bridge, KEEPALIVE_ALARM });
})();
