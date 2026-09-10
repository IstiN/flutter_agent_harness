// Service worker entry (classic script — MV3 classic SW; dart2js agent.js is
// classic too, so importScripts works for everything). Owns: pairing storage,
// bridge wiring, panel API, and the embedded fa agent (self-contained mode).
//
// Load order matters: tabs.js before ops.js (namespace destructure), agent.js
// is optional (scaffold checkouts without a dart build stay fully functional).
importScripts('./tabs.js', './bridge.js', './ops.js', './cdp.js');
// Service workers have no `window`, but package:cryptography's web backend
// probes window.crypto (WebCrypto itself IS available here via self.crypto).
// Alias it before the dart2js bundle initializes any crypto lazily.
self.window = self;
try {
  importScripts('./agent.js'); // dart2js output; absent → scaffold mode
} catch {
  console.warn('[fa] sw/agent.js not built — embedded agent disabled');
}
const { bridge, KEEPALIVE_ALARM } = globalThis.faSw;
const { dispatch } = globalThis.faSw;
const tabs = globalThis.faSw;

const PANEL_PORT = 'fa-panel';
const AGENT_ALARM = 'fa-agent-keepalive';
const ports = new Set();
const agent = globalThis.faAgent ?? null;

const store = {
  get: (keys) => chrome.storage.local.get(keys),
  set: (o) => chrome.storage.local.set(o),
  remove: (keys) => chrome.storage.local.remove(keys),
};

function pushPanels(msg) {
  for (const port of ports) port.postMessage(msg);
}

function snapshot() {
  return {
    ...bridge.status(),
    task: tabs.status(),
    ...(agent ? { agent: agent.getState() } : {}),
  };
}

// Browser op table for the embedded agent (same ops as the wire protocol).
globalThis.__faOps = (op, args) => dispatch(op, args || {});

// The toolbar icon opens the side panel (docs/browser-extension.md "Load
// it" step 3). Without this the action click is a silent no-op: no
// default_popup, no onClicked handler — the headless suite never noticed
// because it opens panel.html by URL.
chrome.sidePanel
  .setPanelBehavior({ openPanelOnActionClick: true })
  .catch((e) => console.error('fa: setPanelBehavior failed', e));

// Bridge disconnect ends the task (contract AC17: cleanup on task_end OR disconnect).
let wasConnected = false;
bridge.onStatus((s) => {
  pushPanels({ type: 'status', status: snapshot() });
  if (s.phase === 'connected') {
    wasConnected = true;
    tabs.beginTask(crypto.randomUUID()); // task id = connection session uuid
  } else if (wasConnected) {
    wasConnected = false;
    tabs.taskEnd();
  }
});

bridge.onMail((m) => {
  pushPanels({ type: 'mail', from: m.from, text: m.text, msgId: m.msgId });
  // Test-only inbound-mail log for the headless CI suite: polls it to prove
  // fabric→browser delivery (no panel needed). Routing fields only; capped.
  const mailLog = (globalThis.__faMailLog ??= []);
  mailLog.push({ from: m.from, text: m.text, ts: m.ts ?? Date.now() });
  if (mailLog.length > 50) mailLog.shift();
  agent?.pushMail(m.from, m.text); // bridge mail reaches the embedded agent
});

bridge.onBrowserReq(async (req) => {
  const out = await dispatch(req.req ?? req.op, req.args || {}); // browser op name arrives as `req` (envelope op is "browserReq")
  bridge.browserRes(req.id, out); // exactly one answer per browserReq
});

// Embedded agent events → panel push; keepalive re-arm on run start/end (E8).
let agentRunning = false;
function armAgentAlarm(running) {
  if (running === agentRunning) return;
  agentRunning = running;
  if (running) chrome.alarms.create(AGENT_ALARM, { periodInMinutes: 0.5 });
  else chrome.alarms.clear(AGENT_ALARM);
}

if (agent) {
  agent.onEvent((ev) => {
    if (ev?.type === 'status') armAgentAlarm(!!ev.running);
    pushPanels({ type: 'agent', event: ev });
  });
}

// Panel API (request/response over runtime messaging).
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    switch (msg?.type) {
      case 'status':
        return { ok: true, status: snapshot() };
      case 'pair': {
        if (!msg.url || !msg.token) return { ok: false, error: 'bridge url and token are required' };
        await store.set({ bridgeUrl: msg.url, token: msg.token });
        bridge.connect(msg.url, msg.token);
        return { ok: true };
      }
      case 'unpair':
        await store.remove(['bridgeUrl', 'token']);
        await bridge.disconnect();
        return { ok: true };
      case 'sendTest':
        try {
          await bridge.sendMail(msg.to || 'main', msg.text || '');
          return { ok: true };
        } catch (e) {
          return { ok: false, error: String(e.message || e) };
        }
      case 'agent.send':
        if (!agent) return { ok: false, error: 'agent not built (missing sw/agent.js)' };
        agent.sendUser(String(msg.text ?? ''));
        return { ok: true };
      case 'agent.decide':
        if (!agent) return { ok: false, error: 'agent not built (missing sw/agent.js)' };
        agent.decide(String(msg.id ?? ''), !!msg.allow);
        return { ok: true };
      case 'provider.save': {
        const provider = {
          baseUrl: String(msg.baseUrl ?? '').trim(),
          apiKey: String(msg.apiKey ?? ''),
          model: String(msg.model ?? '').trim(),
        };
        await store.set({ faProvider: provider, ...(msg.approvalMode ? { faApproval: msg.approvalMode } : {}) });
        // boot() rebuilds the whole config — pass the stored hub + approval
        // back so saving the provider never drops the hub connection.
        const cur = await store.get(['faApproval', 'faDap']);
        agent?.boot({ provider, approvalMode: cur.faApproval, dap: cur.faDap });
        return { ok: true };
      }
      case 'hub.save': {
        // faDap {url, name, secret?, boundSession?, savedConnections?}; empty
        // url = no hub presence. Identity keys are generated + stored inside
        // the Dart agent (faDapKey) on first start. The session binding
        // (boundSession) is edited via hub.bind — saving the connection
        // preserves it. savedConnections (the multi-hub bookmark list) is
        // managed by hub.connections.set / hub.switch — always preserved.
        // secret = the hub password; an empty field keeps the stored one.
        const url = String(msg.url ?? '').trim();
        const name = String(msg.name ?? '').trim();
        const prev = (await store.get(['faDap'])).faDap;
        const boundSession = prev && prev.boundSession ? { boundSession: prev.boundSession } : {};
        const savedConnections = prev && Array.isArray(prev.savedConnections) ? { savedConnections: prev.savedConnections } : {};
        const enteredSecret = String(msg.secret ?? '');
        const keptSecret = prev && typeof prev.secret === 'string' ? prev.secret : '';
        const next = { url, name, ...boundSession, ...savedConnections };
        const effectiveSecret = enteredSecret || keptSecret;
        if (effectiveSecret) next.secret = effectiveSecret;
        if (url) await store.set({ faDap: next });
        else await store.remove(['faDap']);
        console.log('[dap-hub] connection saved:', url || '(cleared)', 'saved list:', (next.savedConnections ?? []).length);
        const cur = await store.get(['faProvider', 'faApproval']);
        agent?.boot({ provider: cur.faProvider, approvalMode: cur.faApproval, dap: url ? next : null });
        return { ok: true };
      }
      case 'hub.connections.set': {
        // Multi-hub bookmarks: overwrite faDap.savedConnections wholesale
        // (the page owns list editing). Each entry: {url, name, secret?} —
        // an entry WITHOUT a secret key means an open hub (secret cleared
        // on switch); a non-empty secret rides along. Inert for the live
        // agent — no reboot.
        const cur = (await store.get(['faDap'])).faDap;
        if (!cur || !cur.url) return { ok: false, error: 'no hub connection' };
        const list = (Array.isArray(msg.list) ? msg.list : [])
          .map((e) => {
            const entry = { url: String(e?.url ?? '').trim(), name: String(e?.name ?? '').trim() };
            if (typeof e?.secret === 'string' && e.secret) entry.secret = e.secret;
            return entry;
          })
          .filter((e) => e.url);
        const next = { ...cur, savedConnections: list };
        await store.set({ faDap: next });
        console.log('[dap-hub] saved connections list set:', list.length);
        return { ok: true, count: list.length };
      }
      case 'hub.switch': {
        // Make a bookmarked connection active: same path as hub.save, but
        // the secret comes from the entry — an entry without a secret key
        // is an open hub, so the stored password is CLEARED (keep-secret
        // semantics would leak the previous hub's password into it).
        const target = String(msg.url ?? '').trim();
        const prev = (await store.get(['faDap'])).faDap;
        const list = prev && Array.isArray(prev.savedConnections) ? prev.savedConnections : [];
        const entry = list.find((e) => e && e.url === target);
        if (!entry) return { ok: false, error: 'connection not bookmarked: ' + target };
        const next = {
          url: entry.url,
          name: String(entry.name ?? ''),
          ...(prev.boundSession ? { boundSession: prev.boundSession } : {}),
          ...(entry.secret ? { secret: entry.secret } : {}),
          savedConnections: list,
        };
        await store.set({ faDap: next });
        console.log('[dap-hub] switched active connection →', entry.url);
        const cur = await store.get(['faProvider', 'faApproval']);
        agent?.boot({ provider: cur.faProvider, approvalMode: cur.faApproval, dap: next });
        return { ok: true };
      }
      case 'hub.bind': {
        // Inbound-mail routing (faDap.boundSession): {mode: current|dedicated|named, sessionId?, title?}.
        // Merged into faDap — the url/name stay untouched; no binding clears the key.
        const cur = (await store.get(['faDap'])).faDap;
        if (!cur || !cur.url) return { ok: false, error: 'no hub connection to bind' };
        const mode = String(msg.mode ?? 'current');
        const next = { url: String(cur.url), name: String(cur.name ?? '') };
        if (cur.secret) next.secret = cur.secret; // the hub password survives rebinds
        if (mode === 'dedicated' || mode === 'named') {
          next.boundSession = { mode };
          if (msg.sessionId) next.boundSession.sessionId = String(msg.sessionId);
          if (msg.title) next.boundSession.title = String(msg.title);
        }
        await store.set({ faDap: next });
        const prov = await store.get(['faProvider', 'faApproval']);
        agent?.boot({ provider: prov.faProvider, approvalMode: prov.faApproval, dap: next });
        return { ok: true };
      }
      case 'hub.sessions': {
        if (!agent || !agent.sessionsList) return { ok: true, sessions: [] };
        return { ok: true, sessions: agent.sessionsList() || [] };
      }
      case 'providers.import': {
        // .fahx import (issue #34 item 3): the Dart agent owns the decrypt;
        // a wrong passphrase or tampered file fails loudly, nothing written.
        if (!agent) return { ok: false, error: 'agent not built (missing sw/agent.js)' };
        const out = await agent.importFahx(String(msg.contents ?? ''), String(msg.passphrase ?? ''));
        return out;
      }
      case 'tools.set': {
        // Second-tier power tools (issue #34 AC4d): store the enabled map,
        // then push it into the live agent — the gate re-applies there.
        const enabled = {};
        for (const [name, on] of Object.entries(msg.enabled ?? {})) {
          if (on === true) enabled[name] = true;
        }
        await store.set({ faBrowserTools: enabled });
        agent?.applyToolVisibility(enabled);
        return { ok: true, enabled };
      }
      default:
        return { ok: false, error: `unknown message type "${msg?.type}"` };
    }
  })().then(sendResponse);
  return true; // async sendResponse
});

// Push channel to open panels.
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== PANEL_PORT) return;
  ports.add(port);
  port.onDisconnect.addListener(() => ports.delete(port));
  port.postMessage({ type: 'status', status: snapshot() });
});

chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === KEEPALIVE_ALARM) bridge.onKeepalive();
  if (a.name === AGENT_ALARM) {
    // E8: a 0.5-min tick re-arms the ping and pings panels so an open panel
    // keeps the SW alive while a run is active; cleared when the run ends.
    if (agentRunning) bridge.onKeepalive();
    pushPanels({ type: 'agent', event: { type: 'status', running: agentRunning } });
  }
});

chrome.tabs.onCreated.addListener(tabs.onTabCreated);
chrome.tabs.onRemoved.addListener(tabs.onTabRemoved);

// Boot: adopt any surviving task group (E24), re-arm keepalives, reconnect if paired.
(async () => {
  await tabs.init();
  chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 1 });
  const cfg = await store.get(['bridgeUrl', 'token']);
  if (cfg.bridgeUrl && cfg.token) bridge.connect(cfg.bridgeUrl, cfg.token);
})();
