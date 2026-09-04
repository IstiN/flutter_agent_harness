// Service worker entry: pairing storage, bridge wiring, panel API.
import { bridge } from './bridge.js';
import { dispatch } from './ops.js';
import * as tabs from './tabs.js';

const PANEL_PORT = 'fa-panel';
const ports = new Set();

const store = {
  get: (keys) => chrome.storage.local.get(keys),
  set: (o) => chrome.storage.local.set(o),
  remove: (keys) => chrome.storage.local.remove(keys),
};

function pushPanels(msg) {
  for (const port of ports) port.postMessage(msg);
}

function snapshot() {
  return { ...bridge.status(), task: tabs.status() };
}

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

bridge.onMail((m) => pushPanels({ type: 'mail', from: m.from, text: m.text, msgId: m.msgId }));

bridge.onBrowserReq(async (req) => {
  const out = await dispatch(req.req ?? req.op, req.args || {}); // browser op name arrives as `req` (envelope op is "browserReq")
  bridge.browserRes(req.id, out); // exactly one answer per browserReq
});

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
  if (a.name === bridge.KEEPALIVE_ALARM) bridge.onKeepalive();
});

chrome.tabs.onCreated.addListener(tabs.onTabCreated);
chrome.tabs.onRemoved.addListener(tabs.onTabRemoved);

// Boot: adopt any surviving task group (E24), re-arm keepalive, reconnect if paired.
await tabs.init();
chrome.alarms.create(bridge.KEEPALIVE_ALARM, { periodInMinutes: 1 });
const cfg = await store.get(['bridgeUrl', 'token']);
if (cfg.bridgeUrl && cfg.token) bridge.connect(cfg.bridgeUrl, cfg.token);
