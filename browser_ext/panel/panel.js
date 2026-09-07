// Panel logic: poll status once, then ride a port for pushes. Persists nothing.
const $ = (id) => document.getElementById(id);
const MAX_LOG = 20;
const MAX_BUBBLES = 200;

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
    const p = agent.provider;
    $('agentStatus').textContent =
      `${p?.configured ? p.model : 'no provider configured (fake echoes)'} · approval: ${agent.approval} · ` +
      `session: ${agent.session?.messages ?? 0} msgs${agent.running ? ' · running…' : ''}`;
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
function onAgentEvent(ev) {
  switch (ev?.type) {
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
      if (ev.running !== undefined && !ev.running && streamingBubble) streamingBubble = null;
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
$('prompt').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendPrompt();
  }
});
function sendPrompt() {
  const text = $('prompt').value.trim();
  if (!text) return;
  $('prompt').value = '';
  call({ type: 'agent.send', text });
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
  const res = await call({ type: 'hub.save', url: $('hubUrl').value, name: $('hubName').value });
  if (res?.ok) log('hub settings saved');
});

// -- Advanced: Settings-gated power tools (issue #34 AC4d) --------------------
// Each toggle is the user gesture Chrome requires: enabling requests the
// tool's optional permission, disabling revokes it, then the enabled-map
// goes to the service worker (store + live agent re-surface).

const POWER_TOOLS = [
  { id: 'browser_search', perm: 'search' },
  { id: 'top_sites', perm: 'topSites' },
  { id: 'reading_list', perm: 'readingList' },
  { id: 'page_capture', perm: 'pageCapture' },
  { id: 'tts_speak', perm: 'tts' },
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
