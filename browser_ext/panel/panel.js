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

const port = chrome.runtime.connect({ name: 'fa-panel' });
port.onMessage.addListener((m) => {
  if (m.type === 'status') render(m.status);
  if (m.type === 'mail') log(`mail ← ${m.from}: ${m.text.length > 80 ? `${m.text.slice(0, 80)}…` : m.text}`);
  if (m.type === 'agent') onAgentEvent(m.event);
});

// Initial snapshot (poll once; port covers the rest).
chrome.runtime.sendMessage({ type: 'status' }).then((res) => res?.ok && render(res.status));
