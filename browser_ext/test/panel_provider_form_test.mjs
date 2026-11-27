// gh-2425: the panel provider form gains a Context window field and a
// Custom headers field; panel.js prefills them from the SW's `provider.get`
// (which never carries the apiKey) and sends them with `provider.save`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const panelDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'panel');
const src = readFileSync(join(panelDir, 'panel.js'), 'utf8');

function boot({ storedProvider, saves }) {
  const elements = new Map();
  const el = (id) => ({
    style: {},
    textContent: '',
    value: '',
    dataset: {},
    hidden: false,
    checked: false,
    classList: { add() {}, remove() {} },
    listeners: {},
    addEventListener(type, fn) { this.listeners[type] = fn; },
    prepend() {},
    appendChild() {},
    children: [],
    lastChild: null,
    selectedOptions: [],
  });
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, el(id));
      return elements.get(id);
    },
    createElement: () => ({ textContent: '', className: '' }),
  };
  const seen = [];
  const chatChannel = { onMessage: { addListener() {} }, onDisconnect: { addListener() {} } };
  const sandbox = {
    console: { log() {}, error() {} },
    document,
    fetch: () => Promise.resolve({ ok: false }),
    location: { replace() {} },
    setTimeout,
    clearTimeout,
    URL,
    Date,
    chrome: {
      runtime: {
        connect: () => chatChannel,
        sendMessage: async (msg) => {
          seen.push(msg);
          if (msg.type === 'provider.get') {
            return { ok: true, provider: storedProvider ?? {} };
          }
          if (msg.type === 'provider.save') {
            saves.push(JSON.parse(JSON.stringify(msg)));
            return { ok: true };
          }
          if (msg.type === 'status') {
            return { ok: true, status: {} };
          }
          return { ok: false, error: 'unsupported in test' };
        },
      },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'panel.js' });
  return {
    elements,
    seen,
    click: (id) => document.getElementById(id).listeners.click(),
    field: (id) => document.getElementById(id),
  };
}

const stored = {
  baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
  model: 'gemini-4-hydrogen',
  contextWindow: 264000,
  contextWindowCap: 0,
  headers: { 'x-copilot-integration-id': 'vscode-chat', authorization: 'Bearer abc' },
};

test('prefill: fields fill from provider.get, the key stays empty', async () => {
  const { field } = boot({ storedProvider: stored });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(field('pBaseUrl').value, stored.baseUrl);
  assert.equal(field('pModel').value, stored.model);
  assert.equal(field('pContextWindow').value, '264000');
  assert.equal(
    field('pHeaders').value,
    'x-copilot-integration-id: vscode-chat\nauthorization: Bearer abc',
  );
  assert.equal(field('pApiKey').value, '', 'the key is write-only — never prefilled');
});

test('save: contextWindow and headers ride the provider.save message', async () => {
  const saves = [];
  const { field, click } = boot({ storedProvider: stored, saves });
  await new Promise((r) => setTimeout(r, 20));
  field('pApiKey').value = 'typed-key';
  field('pContextWindow').value = '1000000';
  field('pHeaders').value = 'x-new: yes';
  click('saveProvider');
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(saves.length, 1);
  assert.equal(saves[0].type, 'provider.save');
  assert.equal(saves[0].contextWindow, '1000000', 'the raw field value; the SW parses');
  assert.equal(saves[0].headers, 'x-new: yes');
  assert.equal(saves[0].model, stored.model);
});

test('prefill with nothing stored: fields stay empty, save still works', async () => {
  const saves = [];
  const { field, click } = boot({ storedProvider: null, saves });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(field('pBaseUrl').value, '');
  assert.equal(field('pContextWindow').value, '');
  assert.equal(field('pHeaders').value, '');
  field('pBaseUrl').value = 'https://x/v1';
  field('pModel').value = 'm';
  click('saveProvider');
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(saves.length, 1);
  assert.equal(saves[0].contextWindow, '');
  assert.equal(saves[0].headers, '');
});
