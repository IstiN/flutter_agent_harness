// Service worker entry (classic script — MV3 classic SW; dart2js agent.js is
// classic too, so importScripts works for everything). Owns: pairing storage,
// bridge wiring, panel API, and the embedded fa agent (self-contained mode).
//
// Load order matters: tabs.js before ops.js (namespace destructure), agent.js
// is optional (scaffold checkouts without a dart build stay fully functional).
importScripts('./tabs.js', './bridge.js', './ops.js', './cdp.js');
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
        agent?.boot({ provider }); // hot-swap stream fn / approval mode
        return { ok: true };
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
