// Mock `fa wire-serve` for the sdk/web example smoke test (issue #1101).
// Node-only, zero deps: static file serving for example/ + dist/, plus a
// minimal RFC6455 WebSocket server at /ws (unfragmented text frames;
// browsers always mask client→server frames, the server never masks).
// Speaks Agent Wire Protocol v1: hello→welcome, then ONE scripted run per
// prompt — Cyrillic deltas, tool lifecycle, approval/ask/secret
// round-trips. Received commands print as `CMD {...}` lines for assertion.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { appendFileSync } from 'node:fs';
import { extname, normalize } from 'node:path';

const CMD_LOG = process.env.CMD_LOG ?? '/dev/null';

const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png',
};

const frame = (kind, extra = {}) => ({ v: 1, kind, ...extra });
const msg = (text) => ({
  role: 'assistant',
  content: [{ type: 'text', text }],
  api: 'openai-completions',
  provider: 'mock',
  model: 'mock-1',
  usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: 'stop',
  timestamp: 1727673600000,
});
const update = (text, delta) =>
  frame('message_update', { message: msg(text), event: { kind: 'text_delta', contentIndex: 0, delta } });

function scriptRun(client) {
  const wait = (kind) => new Promise((resolve) => { client.pending[kind] = resolve; });
  void (async () => {
    const send = (f) => client.writeText(JSON.stringify(f));
    send(frame('agent_start'));
    send(frame('turn_start'));
    send(update('Привет ', 'Привет '));
    send(update('Привет мир', 'мир'));
    send(frame('tool_execution_start', { toolCallId: 'call_1', toolName: 'bash', args: { command: 'ls' }, timestamp: 1727673600000 }));
    send(frame('approval_request', { id: 'ap_1', toolName: 'bash', tier: 'exec', arguments: { command: 'ls' }, reason: 'exec tier' }));
    const approval = await wait('approval_response');
    send(frame('tool_execution_end', { toolCallId: 'call_1', toolName: 'bash', result: { content: [{ type: 'text', text: 'ok' }], terminate: false }, isError: false }));
    send(frame('ask_request', { id: 'ask_1', questions: [{ question: 'Which database?', options: [{ label: 'Postgres' }, { label: 'SQLite' }], multiSelect: false }, { question: 'Notes?', options: [], multiSelect: false }] }));
    const ask = await wait('ask_response');
    send(update('Привет мир — готово', ' — готово'));
    send(frame('secret_request', { id: 'sec_1', name: 'DEPLOY_TOKEN', reason: 'deploy' }));
    const secret = await wait('secret_response');
    send(frame('message_end', { message: msg('Привет мир — готово') }));
    send(frame('turn_end', { message: msg('Привет мир — готово'), toolResults: [] }));
    send(frame('agent_end', { messages: [msg('Привет мир — готово')] }));
    // E4: the granted value never reaches any log — name + persisted only.
    const secretSafe = secret ? { name: secret.name, persisted: secret.persisted } : null;
    console.log(`RUN decision=${approval.decision} ask=${JSON.stringify(ask)} secret=${JSON.stringify(secretSafe)}`);
  })();
}

// --- minimal RFC6455 ------------------------------------------------------
function encodeText(payload) {
  const data = Buffer.from(payload, 'utf8');
  const len = data.length;
  if (len < 126) return Buffer.concat([Buffer.from([0x81, len]), data]);
  const header = Buffer.alloc(4);
  header[0] = 0x81;
  header[1] = 126;
  header.writeUInt16BE(len, 2);
  return Buffer.concat([header, data]);
}

// Extracts one complete frame from [buffer]; returns null while incomplete.
// Returns {opcode, payload} — payload is already unmasked.
function decodeFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  const len0 = buffer[1] & 0x7f;
  let offset = 2;
  let length = len0;
  if (len0 === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  }
  let maskKey = null;
  if (masked) {
    if (buffer.length < offset + 4) return null;
    maskKey = buffer.subarray(offset, offset + 4);
    offset += 4;
  }
  if (buffer.length < offset + length) return null;
  const payload = Buffer.from(buffer.subarray(offset, offset + length));
  if (maskKey) for (let i = 0; i < payload.length; i++) payload[i] ^= maskKey[i % 4];
  return { opcode, payload, rest: buffer.subarray(offset + length) };
}

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function handleFrame(client, opcode, payload) {
  if (opcode === 0x8) { client.socket.end(); return; } // close
  if (opcode !== 0x1) return; // text only: pings/binary are not part of this mock
  const text = payload.toString('utf8');
  console.log('CMD ' + text);
  if (CMD_LOG !== '/dev/null') appendFileSync(CMD_LOG, text + '\n');
  const f = JSON.parse(text);
  if (f.kind === 'hello') {
    client.writeText(JSON.stringify(frame('welcome', { version: 1 })));
  } else if (f.kind === 'prompt') {
    scriptRun(client);
  } else if (client.pending[f.kind]) {
    client.pending[f.kind](f);
    delete client.pending[f.kind];
  }
}

const http = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/health') { res.end('ok'); return; }
  let decoded;
  try {
    decoded = decodeURIComponent(url.pathname);
  } catch {
    // Malformed percent-encoding must answer, not crash the handler.
    res.writeHead(400); res.end('bad percent-encoding'); return;
  }
  let path = normalize(decoded).replace(/^([/\\])+/, '');
  // Traversal guard: reject any `..` segment (post-normalize) so the mock
  // cannot be aimed above its serving root (the process cwd). A mock, not
  // a hardened file server — doc root == cwd, nothing tighter is claimed.
  if (path.split(/[\\/]/).includes('..')) {
    res.writeHead(403); res.end('forbidden'); return;
  }
  if (path === '' || path.endsWith('/')) path += 'index.html';
  try {
    const data = await readFile(path);
    res.writeHead(200, { 'content-type': MIME[extname(path)] ?? 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end('not found');
  }
});

http.on('upgrade', (req, socket) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname !== '/ws') { socket.destroy(); return; }
  const key = req.headers['sec-websocket-key'];
  const accept = createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  const client = {
    socket,
    pending: {},
    writeText: (payload) => socket.write(encodeText(payload)),
  };
  let buffer = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const decoded = decodeFrame(buffer);
      if (decoded === null) return;
      buffer = decoded.rest;
      handleFrame(client, decoded.opcode, decoded.payload);
    }
  });
  socket.on('close', () => socket.destroy());
});

http.listen(8091, '127.0.0.1', () =>
  console.log('mock wire-serve on http://127.0.0.1:8091 (ws at /ws)'),
);
