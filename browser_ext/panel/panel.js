// Panel logic: poll status once, then ride a port for pushes. Persists nothing.
const $ = (id) => document.getElementById(id);
const MAX_LOG = 20;

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

const port = chrome.runtime.connect({ name: 'fa-panel' });
port.onMessage.addListener((m) => {
  if (m.type === 'status') render(m.status);
  if (m.type === 'mail') log(`mail ← ${m.from}: ${m.text.length > 80 ? `${m.text.slice(0, 80)}…` : m.text}`);
});

// Initial snapshot (poll once; port covers the rest).
chrome.runtime.sendMessage({ type: 'status' }).then((res) => res?.ok && render(res.status));
