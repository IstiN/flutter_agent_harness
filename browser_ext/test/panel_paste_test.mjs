// Issue #313: the v1 fallback composer stages long pastes into the SW
// agent's uploads/ sandbox over `agent.stageUpload` and sends a short
// path-reference on Send (panel.js runs in a vm sandbox with stubbed
// document/chrome, mirroring panel_loader_test.mjs).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const panelDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'panel');
const src = readFileSync(join(panelDir, 'panel.js'), 'utf8');

const CAP = 20 * 1024 * 1024;
const STATUS = {
  phase: 'connected',
  agent: { staging: { capBytes: CAP }, provider: { configured: false }, approval: 'ask' },
};

/** Boots panel.js with recording stubs; returns the captured seams. */
function boot({ status = STATUS } = {}) {
  const elements = new Map();
  const el = (id) => ({
    id,
    textContent: '',
    value: '',
    className: '',
    dataset: {},
    children: [],
    get lastChild() {
      return this.children[0];
    },
    classList: {
      add() {},
      remove() {},
    },
    addEventListener(type, fn) {
      this.listeners ??= {};
      (this.listeners[type] ??= []).push(fn);
    },
    prepend(li) {
      this.children.unshift(li);
      while (this.children.length > 20) this.children.pop();
    },
    focus() {},
  });
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, el(id));
      return elements.get(id);
    },
    createElement: () => ({ textContent: '', className: '' }),
  };
  const listenerHost = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
  const mkPort = (name) => {
    const port = {
      name,
      onMessage: listenerHost(),
      responder: null,
      onDisconnect: listenerHost(),
      postMessage(m) {
        // The SW side answers ext_requests; route them to the test's
        // responder, which replies through the real onMessage listeners.
        if (m?.kind === 'ext_request') (port.responder ?? defaultResponder)?.(m);
      },
    };
    return port;
  };
  let defaultResponder = null;
  const panelPort = mkPort('fa-panel');
  // panel.js opens one fresh fa-ui-v2 port per ext op (a long-lived port can
  // silently drop large messages after an agent boot); track them all.
  const extPorts = [];
  const mkExtPort = () => {
    const port = mkPort('fa-ui-v2');
    extPorts.push(port);
    return port;
  };
  const sent = [];
  const sandbox = {
    console,
    document,
    location: { replace: () => {} },
    btoa: (bin) => Buffer.from(bin, 'binary').toString('base64'),
    fetch: () => Promise.resolve({ ok: false }),
    TextEncoder,
    setTimeout,
    clearTimeout,
    chrome: {
      runtime: {
        connect: ({ name }) => (name === 'fa-panel' ? panelPort : mkExtPort()),
        sendMessage: (msg) => {
          sent.push(msg);
          if (msg.type === 'status') return Promise.resolve({ ok: true, status });
          return Promise.resolve({ ok: true });
        },
      },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);

  const deliver = (frame) => extPorts.forEach((p) => p.onMessage.listeners.forEach((fn) => fn(frame)));
  const settle = async () => {
    for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 1));
  };
  return {
    elements,
    extPorts,
    sent,
    deliver,
    settle,
    serve(res) {
      // Applies to existing ports and every future per-op port.
      defaultResponder = res;
      extPorts.forEach((p) => { p.responder = res; });
    },
    async paste(text) {
      await settle();
      const ev = {
        clipboardData: { getData: () => text },
        prevented: false,
      };
      ev.preventDefault = () => {
        ev.prevented = true;
      };
      for (const fn of elements.get('prompt').listeners.paste) fn(ev);
      await settle();
      return ev;
    },
    send() {
      for (const fn of elements.get('sendPrompt').listeners.click) fn();
    },
    logs() {
      return elements.get('log').children.map((li) => li.textContent);
    },
  };
}

const stageOk = (t) =>
  t.serve((m) => {
    assert.equal(m.op, 'agent.stageUpload');
    t.stagedBytes = Buffer.from(m.params.bytes, 'base64').toString('utf8');
    t.deliver({ kind: 'ext_result', id: m.id, ok: true, data: { path: `uploads/${m.params.name}` } });
  });

test('long multi-line paste stages into the SW sandbox, one reference on send', async () => {
  const t = boot();
  await t.settle();
  stageOk(t);
  const LONG = Array.from({ length: 3000 }, (_, i) => `line-${i} padding for the payload`).join('\n');

  const ev = await t.paste(LONG);
  assert.equal(ev.prevented, true, 'the paste is consumed, not inlined');
  assert.equal(t.stagedBytes, LONG, 'byte-exact staging of the clipboard text');
  assert.equal(t.elements.get('prompt').value, '', 'composer cleared after staging');
  assert.equal(t.sent.filter((m) => m.type === 'agent.send').length, 0, 'nothing sent yet');
  assert.ok(t.logs().some((l) => /staged paste -> uploads\/pasted-\d+\.txt/.test(l)));

  t.send();
  const sends = t.sent.filter((m) => m.type === 'agent.send');
  assert.equal(sends.length, 1, 'one turn carries the reference');
  assert.match(
    sends[0].text,
    /^\[attached file: uploads\/pasted-\d+\.txt — read it with your tools\]$/,
  );
});

test('short single-line paste stays inline — no staging request', async () => {
  const t = boot();
  await t.settle();
  t.serve(() => assert.fail('no ext_request expected for a short paste'));
  const ev = await t.paste('just a line');
  assert.equal(ev.prevented, false, 'normal paste untouched (no preventDefault)');
  assert.equal(
    t.sent.filter((m) => m.type === 'agent.send').length,
    0,
    'no send traffic',
  );
});

test('oversized paste is refused locally with the shared wording, nothing sent', async () => {
  const t = boot();
  await t.settle();
  t.serve(() => assert.fail('oversized paste must be refused BEFORE staging'));
  const big = `x\n${'y'.repeat(CAP)}`;
  const ev = await t.paste(big);
  assert.equal(ev.prevented, true);
  assert.equal(t.elements.get('prompt').value, '');
  assert.equal(t.sent.filter((m) => m.type === 'agent.send').length, 0);
  assert.ok(
    t.logs().some((l) => l.includes(`paste rejected: ${big.length} bytes exceeds the 20 MB staging cap`)),
    `refusal wording surfaced, got: ${t.logs().join(' | ')}`,
  );
});

test('staging failure falls back to inline paste — clipboard never lost', async () => {
  const t = boot();
  await t.settle();
  t.serve((m) => t.deliver({ kind: 'ext_result', id: m.id, ok: false, error: 'no agent' }));
  const LONG = 'a\nb\nc';
  await t.paste(LONG);
  assert.equal(t.elements.get('prompt').value, LONG, 'pasted text restored');
  assert.ok(t.logs().some((l) => l.includes('staging failed (no agent)')));
});
