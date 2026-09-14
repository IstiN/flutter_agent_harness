// Panel logic: poll status once, then ride a port for pushes. Persists nothing.
const $ = (id) => document.getElementById(id);
const MAX_LOG = 20;
const MAX_BUBBLES = 200;

// Attachment staging for long pastes (issue #313): the fallback composer
// has no chip UI of its own, so a long multi-line paste stages the
// clipboard text into the SW agent's uploads/ sandbox over
// `agent.stageUpload` and sends a short path-reference on Send — the SAME
// semantics the app's stageAttachment has. The oversized guard reads the
// cap from the agent status payload (single source: core uploads.dart via
// getState) — no JS-side constant; 0 = unknown, skip the pre-check and
// let the SW refuse.
const stagedFiles = [];
let stagingCapBytes = 0;

function log(line) {
  const li = document.createElement('li');
  li.textContent = `[${new Date().toLocaleTimeString()}] ${line}`;
  const list = $('log');
  list.prepend(li);
  while (list.children.length > MAX_LOG) list.lastChild.remove();
}

function render(s) {
  const dot = $('dot');
  dot.className = `dot ${s.phase === 'connected' ? 'on' : s.phase === 'reconnecting' || s.phase === 'connecting' ? 'retry' : 'off'}`;
  let text;
  switch (s.phase) {
    case 'connected': text = `connected · ${s.bridgeUrl} · ${s.mailbox ?? ''}`; break;
    case 'connecting': text = `connecting ${s.bridgeUrl ?? ''}…`; break;
    case 'reconnecting': text = `reconnecting… ${s.reason ?? ''}`; break;
    case 'disconnected': text = `disconnected — ${s.reason ?? 'unknown'}`; break;
    default: text = 'unpaired — run /browser connect in fa, then paste the token';
  }
  $('status').textContent = text;
  const agent = s.agent;
  if (agent) {
    if (agent.staging?.capBytes) stagingCapBytes = agent.staging.capBytes;
    const p = agent.provider;
    $('agentStatus').textContent =
      `${p?.configured ? p.model : 'no provider configured (fake echoes)'} · approval: ${agent.approval} · ` +
      `session: ${agent.session?.messages ?? 0} msgs${agent.running ? ' · running…' : ''}` +
      // Issue #137: in yolo the chrome.* bridge never prompts — a
      // persistent indicator keeps that visible.
      `${agent.approval === 'yolo' ? ' · bridge: yolo — no prompts' : ''}`;
  } else {
    $('agentStatus').textContent = 'embedded agent not built — run scripts/build_browser_ext.sh';
  }
  const hub = agent?.hub;
  $('hubStatus').textContent = hubText(hub);
}

// E9: one quiet status line, no dialogs.
function hubText(hub) {
  if (!hub) return '';
  return hub.phase === 'connected'
    ? `hub: connected as ${hub.agentId}`
    : 'hub: disconnected (retrying)';
}

// -- Agent chat (plain text bubbles; markdown NOT rendered) -------------------

function bubble(role, text) {
  const div = document.createElement('div');
  div.className = `bubble ${role}`;
  div.textContent = text;
  const t = $('transcript');
  t.appendChild(div);
  while (t.children.length > MAX_BUBBLES) t.firstChild.remove();
  t.scrollTop = t.scrollHeight;
  return div;
}

let streamingBubble = null;
// Issue #314: steering a running stream queues the message for the next
// step boundary - show it instantly as a neutral pending row, never an
// error. One marker per steer; popped when its user message lands.
let steerMarkers = [];
function popSteerMarker() {
  steerMarkers.shift()?.remove();
}
function onAgentEvent(ev) {
  switch (ev?.type) {
    case 'steer_queued':
      steerMarkers.push(bubble('steer', 'steered - lands at the next step boundary'));
      break;
    case 'delta':
      // ponytail: single trailing bubble per run; deltas arrive pre-coalesced.
      if (!streamingBubble) streamingBubble = bubble('assistant', '');
      streamingBubble.textContent += ev.text ?? '';
      $('transcript').scrollTop = $('transcript').scrollHeight;
      break;
    case 'message_done':
      if (streamingBubble && ev.role === 'assistant') {
        streamingBubble.textContent = ev.text ?? streamingBubble.textContent;
        streamingBubble = null;
      } else if (ev.role === 'user') {
        bubble('user', ev.text ?? '');
        popSteerMarker();
      } else if (ev.role === 'toolResult') {
        bubble('tool', `${ev.toolName}: ${ev.text ?? ''}`);
      }
      break;
    case 'tool_result':
      bubble('tool', `${ev.toolName}: ${ev.isError ? 'ERROR ' : ''}${(ev.text ?? '').slice(0, 400)}`);
      break;
    case 'approval_request':
      showApproval(ev);
      break;
    case 'approval_resolved':
      hideApproval();
      log(`approval ${ev.id}: ${ev.allow ? 'allowed' : 'denied'}${ev.note ? ` (${ev.note})` : ''}`);
      break;
    case 'status':
      if (ev.running !== undefined && !ev.running) {
        if (streamingBubble) streamingBubble = null;
        steerMarkers.forEach((m) => m.remove());
        steerMarkers = [];
      }
      if (ev.hub) $('hubStatus').textContent = hubText(ev.hub);
      break;
    case 'error':
      log(`agent error: ${ev.error}`);
      break;
    default:
      break;
  }
}

function showApproval(ev) {
  $('approval').classList.remove('hidden');
  $('approval').dataset.id = ev.id;
  $('approvalText').textContent = `${ev.summary}${ev.reason ? ` — ${ev.reason}` : ''}`;
}
function hideApproval() {
  $('approval').classList.add('hidden');
  delete $('approval').dataset.id;
}

async function call(msg) {
  const res = await chrome.runtime.sendMessage(msg);
  if (!res?.ok) log(`error: ${res?.error ?? 'no response'}`);
  return res;
}

$('connect').addEventListener('click', async () => {
  const res = await call({ type: 'pair', url: $('url').value.trim(), token: $('token').value.trim() });
  if (res?.ok) log(`pairing ${$('url').value.trim()}…`);
});
$('disconnect').addEventListener('click', async () => {
  const res = await call({ type: 'unpair' });
  if (res?.ok) log('unpaired');
});
$('send').addEventListener('click', async () => {
  const res = await call({ type: 'sendTest', to: $('to').value.trim(), text: $('text').value });
  if (res?.ok) log(`mail → ${$('to').value.trim()} (queued for ack)`);
});
$('sendPrompt').addEventListener('click', sendPrompt);

// UTF-8-safe base64 in chunks (String.fromCharCode spread is stack-bound).
function base64EncodeUtf8(text) {
  const bytes = new TextEncoder().encode(text);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

$('prompt').addEventListener('paste', (e) => {
  const text = e.clipboardData?.getData('text/plain') ?? '';
  // Short or single-line pastes are normal input, not attachments.
  if (!text || !text.includes('\n')) return;
  const cap = stagingCapBytes;
  if (cap && text.length > cap) {
    e.preventDefault();
    log(`paste rejected: ${text.length} bytes exceeds the ${Math.floor(cap / (1024 * 1024))} MB staging cap — text kept for editing`);
    return;
  }
  e.preventDefault();
  const name = `pasted-${Date.now()}.txt`;
  extCall('agent.stageUpload', { name, bytes: base64EncodeUtf8(text) })
    .then((res) => {
      stagedFiles.push(res.path);
      $('prompt').value = '';
      log(`staged paste -> ${res.path} (${text.length} bytes) — attach on send`);
    })
    .catch((err) => {
      // Staging failed: put the pasted text back — inline paste is the
      // fallback, never a lost clipboard.
      $('prompt').value = text;
      log(`staging failed (${err.message}) — pasted inline instead`);
    });
});
$('prompt').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendPrompt();
  }
});
function sendPrompt() {
  const text = $('prompt').value.trim();
  const staged = stagedFiles.splice(0);
  if (!text && !staged.length) return;
  $('prompt').value = '';
  // A Send-button click leaves DOM focus on the button; after fa's reply the
  // next typed text goes nowhere (issue #39). Keep the caret in the composer
  // so a follow-up message never needs a fresh click on the field.
  $('prompt').focus();
  const fullText = [
    ...staged.map((path) => `[attached file: ${path} — read it with your tools]`),
    text,
  ]
    .filter(Boolean)
    .join('\n');
  call({ type: 'agent.send', text: fullText });
}
$('approve').addEventListener('click', () => {
  call({ type: 'agent.decide', id: $('approval').dataset.id, allow: true });
});
$('deny').addEventListener('click', () => {
  call({ type: 'agent.decide', id: $('approval').dataset.id, allow: false });
});
$('saveProvider').addEventListener('click', async () => {
  const res = await call({
    type: 'provider.save',
    baseUrl: $('pBaseUrl').value,
    apiKey: $('pApiKey').value,
    model: $('pModel').value,
    approvalMode: $('pApproval').value,
  });
  if (res?.ok) log('provider saved (stored in the service worker only)');
});

// -- CodeMie cookie sign-in (ext ops over the fa-ui-v2 port) ------------------
// The service worker serves three one-shot ops to this panel only:
// `fetch` (cookie-auth'd HTTP — MV3 + host permissions, no CORS), `tabs.create`
// (open the CodeMie login page) and `cookies.get_all` (direct jar reads). A
// CodeMie provider never needs an API key: the browser jar IS the credential.

// One fresh port per ext op: a port that lived through an embedded-agent
// boot/reconfigure can silently drop subsequent large messages (observed on
// Chromium 143: the connect survives, the ext_request never arrives at the
// worker), and one wedged port then blocks every queued op behind it. A
// per-call port isolates that failure - worst case a single op times out.
let extSeq = 0;
function extCall(op, params = {}, timeoutMs = 45000) {
  return new Promise((resolve, reject) => {
    const port = chrome.runtime.connect({ name: 'fa-ui-v2' });
    const id = `x${++extSeq}`;
    let settled = false;
    const finish = (settle) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { port.disconnect(); } catch {}
      settle();
    };
    const timer = setTimeout(() => finish(() => reject(new Error(`${op} timed out`))), timeoutMs);
    port.onMessage.addListener((m) => {
      if (m?.kind !== 'ext_result' || m.id !== id) return;
      finish(() => (m.ok ? resolve(m.data ?? {}) : reject(new Error(m.error || 'ext op failed'))));
    });
    port.onDisconnect.addListener(() => finish(() => reject(new Error('extension service worker went away'))));
    port.postMessage({ kind: 'ext_request', id, op, params });
  });
}

function codeMieStatus(text) {
  $('codeMieStatus').textContent = text;
}

// `<org>` or `<org>/…` → `<org>/code-assistant-api/v1` (the models base).
function codeMieApiBase(raw) {
  const base = String(raw || '').trim().replace(/\/+$/, '');
  if (!base) return null;
  if (base.includes('/code-assistant-api/v1')) return base;
  return `${base}/code-assistant-api/v1`;
}

// One cookie check: 200 → jar alive (and we surface model ids);
// 401/403 → the user must (re-)log in. Anything else surfaces as-is.
async function codeMieProbe(apiBase) {
  const res = await extCall('fetch', {
    url: `${apiBase}/llm_models?include_all=true`,
  });
  if (res.status === 401 || res.status === 403) {
    throw new Error(`not signed in (${res.status})`);
  }
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`CodeMie answered ${res.status}`);
  }
  try {
    const models = JSON.parse(res.body);
    return Array.isArray(models)
      ? models.map((m) => m && (m.id || m.base_name || m.deployment_name)).filter(Boolean)
      : [];
  } catch {
    return [];
  }
}

$('codeMieLogin').addEventListener('click', async () => {
  const apiBase = codeMieApiBase($('pBaseUrl').value);
  if (!apiBase) {
    codeMieStatus('enter the CodeMie base URL above first');
    return;
  }
  codeMieStatus('checking cookies…');
  let models;
  try {
    models = await codeMieProbe(apiBase);
  } catch (e) {
    if (!/not signed in/.test(String(e.message))) {
      codeMieStatus(e.message);
      return;
    }
    // Open the login page, then poll: the moment the jar holds a live
    // session the probe succeeds (bounded wait, no infinite loop).
    codeMieStatus('opened the login tab — sign in, keeping this panel open');
    const origin = new URL(apiBase).origin;
    await extCall('tabs.create', { url: `${origin}/login` }).catch(() => {});
    const deadline = Date.now() + 5 * 60 * 1000;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 4000));
      try {
        models = await codeMieProbe(apiBase);
        break;
      } catch (e) {
        if (!/not signed in/.test(String(e.message))) {
          codeMieStatus(e.message);
          return;
        }
      }
    }
    if (!models) return; // gave up quietly; the user can press again
  }
  codeMieStatus(`cookies OK${models.length ? ` — ${models.length} models` : ''}`);
  if (models.length && !$('pModel').value.trim()) {
    $('pModel').value = models[0];
  }
  // Pre-select the first model in the picker list; the key stays EMPTY —
  // CodeMie authenticates by cookie.
  $('pApiKey').value = '';
  log(`CodeMie ready: ${apiBase} (${models.length} models, cookie auth)`);
});

// -- Provider registry (issue #34 item 3) -------------------------------------
// Synced (from the CLI bridge) + local (.fahx import) entries with their
// provenance. Remove filters the stored doc directly; the agent re-resolves
// the active provider on the storage.onChanged ping.

function renderProviders(doc) {
  const list = $('providerList');
  list.textContent = '';
  const provs = doc?.providers ?? [];
  if (!provs.length) {
    list.textContent = 'no registry entries — the legacy form above still applies';
    return;
  }
  for (const p of provs) {
    const row = document.createElement('div');
    const badge = document.createElement('span');
    badge.textContent = p.provenance === 'local' ? '[local]' : '[synced]';
    const label = document.createElement('span');
    label.textContent = ` ${p.name} — ${p.baseUrl} — ${p.modelId || '(CLI model)'} `;
    const rm = document.createElement('button');
    rm.textContent = 'remove';
    rm.className = 'ghost';
    rm.addEventListener('click', () => removeProvider(p.name));
    row.append(badge, label, rm);
    list.appendChild(row);
  }
}

async function removeProvider(name) {
  const doc = (await chrome.storage.local.get('faProviders')).faProviders;
  doc.providers = (doc?.providers ?? []).filter((p) => p.name !== name);
  await chrome.storage.local.set({ faProviders: doc });
  log(`provider ${name} removed`);
}

chrome.storage?.local?.get('faProviders')
  ?.then((s) => renderProviders(s.faProviders));
chrome.storage?.onChanged?.addListener?.((change, area) => {
  if (area === 'local' && change.faProviders) {
    renderProviders(change.faProviders.newValue);
  }
});

// .fahx import: file content + passphrase go to the SW agent, which owns
// the decrypt (PBKDF2 + HMAC-CTR, matching the CLI exporter). Wrong
// passphrase or a tampered file fails loudly — nothing is written.
$('importFahx').addEventListener('click', () => $('fahxFile').click());
$('fahxFile').addEventListener('change', async () => {
  const file = $('fahxFile').files[0];
  const pass = $('fahxPass').value;
  const msg = $('fahxMsg');
  if (!file || !pass) {
    msg.textContent = 'pick a .fahx file and enter its passphrase';
    return;
  }
  msg.textContent = 'importing…';
  const res = await call({
    type: 'providers.import',
    contents: await file.text(),
    passphrase: pass,
  });
  $('fahxFile').value = '';
  if (res?.ok) {
    msg.textContent = `imported ${res.imported} provider(s)`;
    log(`.fahx import: ${res.imported} provider(s)`);
  } else {
    msg.textContent = `import failed: ${res?.error ?? 'no response'}`;
  }
});

$('saveHub').addEventListener('click', async () => {
  const res = await call({ type: 'hub.save', url: $('hubUrl').value, name: $('hubName').value, secret: $('hubSecret').value });
  if (res?.ok) log('hub settings saved');
  $('hubSecret').value = '';
});

// --- DAP inbound-mail routing (faDap.boundSession) -----------------------
// The panel NEVER reads faDap from chrome.storage: the read goes through
// call({type:'hub.bind.get'}) — the SW answers with routing fields ONLY
// ({mode, sessionId?, title?}), so the hub secret never crosses into the
// UI ('UI holds no keys'). Saves go via call({type:'hub.bind'}) — the SW
// merges the binding into faDap (preserving url/name/secret/
// savedConnections) and reboots the agent with the new routing.
//
// Default when nothing is stored: 'dedicated' — the first inbound mail
// mints the 'DAP Inbox' session; the SW persists its id back into
// faDap.boundSession.sessionId so it survives SW restarts.
//
// Mode switches never lose already-received mail: routing is forward-only
// (boundSessionAction decides the pre-turn move for FUTURE mail; archived
// sessions stay put, and a dangling bound id degrades to the live session).
//
// All DOM access sits behind $() (getElementById) inside initDapBind() —
// no top-level querySelector probes: the vm-test harness serves
// getElementById with create-on-access stubs, and an import-time DOM query
// breaks every panel test (issue #321 review).
//
// TODO(unread-badge contract, v2 Flutter panel owns the session drawer):
// SW adds `dapUnread: <count>` to the status payload per bound session
// (hub mails routed there since it was last opened); the v2 panel renders
// it as a badge on the session list entry and clears on open. NOT
// implemented in this v1 panel — no session drawer here.

const DAP_MODES = ['dedicated', 'current', 'named'];

function dapMode() {
  for (const m of DAP_MODES) {
    if ($(`dapMode_${m}`).checked) return m;
  }
  return 'dedicated'; // nothing checked (fresh panel) — the default
}

function setDapMode(mode) {
  const valid = DAP_MODES.includes(mode) ? mode : 'dedicated';
  for (const m of DAP_MODES) $(`dapMode_${m}`).checked = m === valid;
  $('dapBindNamedRow').hidden = valid !== 'named';
}

// One status-line phrase per binding. Dedicated renders the bound title
// ('DAP Inbox' when the session was self-minted) so the title the first
// bind writes is visible where the mail actually lands.
function describeDapBind(bound) {
  const mode = DAP_MODES.includes(bound?.mode) ? bound.mode : 'dedicated';
  if (mode === 'named') {
    return bound?.sessionId ? `named → ${bound.sessionId}` : 'named';
  }
  if (mode === 'dedicated') {
    const label = bound?.title || 'DAP Inbox';
    return bound?.sessionId
      ? `dedicated → ${label} (${bound.sessionId})`
      : `dedicated → ${label}`;
  }
  return 'current';
}

async function loadDapBind() {
  let bound = null;
  try {
    const res = await call({ type: 'hub.bind.get' });
    if (res?.ok) bound = res.binding ?? null;
    if (bound?.sessionId) $('dapBindSession').dataset.boundId = bound.sessionId;
    await refreshDapBindSessions(bound?.sessionId ?? '');
  } catch {
    // hub.bind.get / hub.sessions unavailable (SW down, partial DOM in the
    // vm harness) — degrade to the dedicated default. Panel boot must never
    // depend on this round-trip (issue #321 review).
  }
  setDapMode(bound?.mode ?? 'dedicated');
  $('dapBindStatus').textContent = bound
    ? `routing: ${describeDapBind(bound)}`
    : 'routing: dedicated (default)';
}

async function refreshDapBindSessions(selectedId) {
  const sel = $('dapBindSession');
  sel.innerHTML = '';
  const res = await call({ type: 'hub.sessions' });
  const sessions = res?.ok ? (res.sessions ?? []) : [];
  for (const s of sessions) {
    const opt = document.createElement('option');
    opt.value = s.id;
    opt.textContent = `${s.id} (${s.messages ?? 0} msgs${s.running ? ', running' : ''})`;
    sel.appendChild(opt);
  }
  if (selectedId) sel.value = selectedId;
}

async function saveDapBind() {
  const mode = dapMode();
  const msg = { type: 'hub.bind', mode };
  if (mode === 'named') {
    const sessionId = $('dapBindSession').value;
    if (!sessionId) { $('dapBindStatus').textContent = 'pick a session for named mode'; return; }
    msg.sessionId = sessionId;
    msg.title = $('dapBindSession').selectedOptions?.[0]?.textContent ?? '';
  } else if (mode === 'dedicated') {
    const kept = $('dapBindSession').dataset.boundId ?? '';
    if (kept) msg.sessionId = kept; // rebind preserves the existing dedicated session
    else msg.title = 'DAP Inbox';   // first inbound mail mints it under this title
  }
  const res = await call(msg);
  if (res?.ok) {
    log(`dap bind saved: ${mode}${msg.sessionId ? ' → ' + msg.sessionId : ''}`);
    // The SW's persisted view wins (it preserves the minted title on a
    // dedicated rebind); the local payload is the fallback.
    $('dapBindStatus').textContent = `routing: ${describeDapBind(res.binding ?? msg)}`;
  } else {
    $('dapBindStatus').textContent = `save failed: ${res?.error ?? 'no response'}`;
  }
}

function initDapBind() {
  for (const m of DAP_MODES) {
    $(`dapMode_${m}`).addEventListener('change', () => {
      $('dapBindNamedRow').hidden = dapMode() !== 'named';
    });
  }
  $('saveDapBind').addEventListener('click', saveDapBind);
  loadDapBind();
}
initDapBind();


// -- Advanced: Settings-gated power tools (issue #34 AC4d) --------------------
// Each toggle is the user gesture Chrome requires: enabling requests the
// tool's optional permission, disabling revokes it, then the enabled-map
// goes to the service worker (store + live agent re-surface).

const POWER_TOOLS = [
  { id: 'browser_search', perm: 'search' },
  { id: 'top_sites', perm: 'topSites' },
  { id: 'reading_list', perm: 'readingList' },
  { id: 'page_capture', perm: 'pageCapture' },
];

function enabledTools() {
  const enabled = {};
  for (const { id } of POWER_TOOLS) enabled[id] = $(`tool-${id}`).checked;
  return enabled;
}

function renderTools(enabled) {
  for (const { id } of POWER_TOOLS) $(`tool-${id}`).checked = !!enabled?.[id];
}

async function setTool({ id, perm }, on) {
  try {
    const granted = on
      ? await chrome.permissions.request({ permissions: [perm] })
      : await chrome.permissions.remove({ permissions: [perm] });
    if (!granted) {
      $(`tool-${id}`).checked = !on; // toggle follows the capability
      return;
    }
    const res = await call({ type: 'tools.set', enabled: enabledTools() });
    if (res?.ok) log(`tool ${id} ${on ? 'on' : 'off'}`);
  } catch (e) {
    log(`tool ${id}: ${e.message ?? e}`);
    $(`tool-${id}`).checked = !on;
  }
}

for (const tool of POWER_TOOLS) {
  $(`tool-${tool.id}`).addEventListener('change', (e) => setTool(tool, e.target.checked));
}
chrome.storage?.local?.get('faBrowserTools')
  ?.then((s) => renderTools(s.faBrowserTools));

const port = chrome.runtime.connect({ name: 'fa-panel' });
port.onMessage.addListener((m) => {
  if (m.type === 'status') render(m.status);
  if (m.type === 'mail') log(`mail ← ${m.from}: ${m.text.length > 80 ? `${m.text.slice(0, 80)}…` : m.text}`);
  if (m.type === 'agent') onAgentEvent(m.event);
});

// Initial snapshot (poll once; port covers the rest).
chrome.runtime.sendMessage({ type: 'status' }).then((res) => res?.ok && render(res.status));

// -- v2.1 app-hosting loader (AC1) --------------------------------------------
// The panel hosts the built fa web app when present; the chat UI above is the
// fallback only. DOM is resolved lazily inside decide() so tests can drive it
// without a real document.

globalThis.faPanel = {
  decide(appPresent) {
    if (appPresent) {
      (globalThis.__faRedirect ?? ((url) => location.replace(url)))('app/index.html');
      return { mode: 'app' };
    }
    const notice = $('notice');
    notice.textContent = 'fa app bundle not built — run scripts/build_browser_ext.sh --with-app — showing basic panel.';
    notice.classList.remove('hidden');
    $('legacy').classList.remove('hidden');
    return { mode: 'fallback' };
  },
};

fetch('app/index.html', { method: 'HEAD' })
  .then((res) => faPanel.decide(res?.ok))
  .catch(() => faPanel.decide(false));
