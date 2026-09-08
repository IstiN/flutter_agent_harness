// Panel CodeMie cookie sign-in flow (issue #43): panel.js booted in a vm
// sandbox whose fa-ui-v2 port answers ext_result frames like the Dart
// service worker would. Pins: the probe (200 → cookies OK, models
// prefill, key stays EMPTY), the 401 → login tab path, and the
// ext_request wire shape.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const panelDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'panel');
const src = readFileSync(join(panelDir, 'panel.js'), 'utf8');

/** Boots panel.js with a scripted fa-ui-v2 ext-op responder. */
function boot({ respond }) {
  const elements = new Map();
  const el = (id) => ({
    style: {},
    textContent: '',
    value: '',
    dataset: {},
    classList: { add() {}, remove() {} },
    listeners: {},
    addEventListener(type, fn) { this.listeners[type] = fn; },
    // log() prepends entries to its list element.
    prepend() {},
    appendChild() {},
    children: [],
    lastChild: null,
  });
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, el(id));
      return elements.get(id);
    },
    createElement: () => ({ textContent: '', className: '' }),
  };
  let onPortMessage = null;
  const sentFrames = [];
  const chatChannel = { onMessage: { addListener() {} } };
  const extChannel = {
    onMessage: {
      addListener(fn) { onPortMessage = fn; },
    },
    postMessage(frame) {
      sentFrames.push(frame);
      // Answer asynchronously, like the SW round-trip would.
      setTimeout(() => {
        const reply = respond(frame);
        if (reply) onPortMessage(reply);
      }, 0);
    },
  };
  const sandbox = {
    console: { log() {}, error() {} },
    document,
    fetch: () => Promise.resolve({ ok: false }),
    location: { replace() {} },
    setTimeout,
    URL, // the vm realm has no WHATWG globals; the panel runs in a browser
    Date,
    chrome: {
      runtime: {
        connect: (opts) => (opts?.name === 'fa-ui-v2' ? extChannel : chatChannel),
        sendMessage: () => Promise.resolve({ ok: false }),
      },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'panel.js' });
  return {
    elements: document, // getElementById creates-on-access, like the DOM
    sentFrames,
    click: (id) => document.getElementById(id).listeners.click(),
  };
}

const fetchResult = (frame, status, body) => ({
  kind: 'ext_result',
  id: frame.id,
  ok: true,
  data: { status, body },
});

test('probe 200 → cookies OK, first model prefilled, key left empty', async () => {
  const { elements, sentFrames, click } = boot({
    respond: (frame) => fetchResult(frame, 200, '[{"id":"gpt-x"},{"base_name":"claude-y"}]'),
  });
  elements.getElementById('pBaseUrl').value = 'https://codemie.lab.epam.com';
  elements.getElementById('pModel').value = '';
  elements.getElementById('pApiKey').value = 'leftover';
  click('codeMieLogin');
  await new Promise((r) => setTimeout(r, 20));

  assert.equal(sentFrames.length, 1);
  assert.equal(sentFrames[0].kind, 'ext_request');
  assert.equal(sentFrames[0].op, 'fetch');
  assert.equal(
    sentFrames[0].params.url,
    'https://codemie.lab.epam.com/code-assistant-api/v1/llm_models?include_all=true',
  );
  assert.equal(elements.getElementById('pModel').value, 'gpt-x');
  assert.equal(elements.getElementById('pApiKey').value, '');
  assert.match(elements.getElementById('codeMieStatus').textContent, /cookies OK.*2 models/);
});

test('401 → opens the CodeMie login tab', async () => {
  const opened = [];
  let probes = 0;
  const { elements, sentFrames, click } = boot({
    respond: (frame) => {
      if (frame.op === 'tabs.create') {
        opened.push(frame.params.url);
        return { kind: 'ext_result', id: frame.id, ok: true, data: { opened: true } };
      }
      probes += 1;
      return probes === 1
        ? fetchResult(frame, 401, 'denied')
        : fetchResult(frame, 200, '[{"id":"m2"}]');
    },
  });
  elements.getElementById('pBaseUrl').value = 'https://codemie.lab.epam.com/code-assistant-api/v1';
  click('codeMieLogin');
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(opened[0], 'https://codemie.lab.epam.com/login');
  assert.deepEqual(
    sentFrames.map((f) => f.op),
    ['fetch', 'tabs.create'],
  );
});

test('empty base URL → guidance, no frames sent', async () => {
  const { elements, sentFrames, click } = boot({ respond: () => null });
  elements.getElementById('pBaseUrl').value = '  ';
  click('codeMieLogin');
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(sentFrames, []);
  assert.match(elements.getElementById('codeMieStatus').textContent, /base URL/);
});
