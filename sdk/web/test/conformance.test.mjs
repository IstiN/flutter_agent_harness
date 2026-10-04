// Agent Wire Protocol v1 conformance runner for the web reference client
// (issue #1101, UT-3). Parses EVERY golden event fixture under
// `test/wire/fixtures/v1/events/` and reproduces EVERY pinned command frame
// under `.../commands/` with the TypeScript client — the same corpus the
// Dart suite pins, so server and client drift-proof each other.
//
// Runs on plain node (>= 22.18: default type stripping) with zero
// dependencies; CI invokes it from `test/wire/web_client_conformance_test.dart`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  WIRE_VERSION,
  WireProtocolError,
  WireVersionError,
  abortCommand,
  acceptWelcome,
  approvalResponseCommand,
  askResponseCommand,
  decodeEvent,
  encodeUnknownEvent,
  frameLine,
  helloFrame,
  isSecretField,
  negotiate,
  parseLine,
  promptCommand,
  redactForLog,
  secretResponseCommand,
  sessionControlCommand,
  steerCommand,
} from '../src/wire-client.ts';

// Fixture dir resolved relative to THIS file: works from any working dir.
const fixturesRoot = fileURLToPath(
  new URL('../../../test/wire/fixtures/v1', import.meta.url),
);

/// Loader mirroring the Dart golden loader: loud on structure problems
/// (a half-written fixture pins nothing).
function loadFixtures(dirName) {
  const dir = `${fixturesRoot}/${dirName}`;
  const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort();
  if (files.length === 0) throw new Error(`no fixtures under ${dir}`);
  return files.map((name) => {
    const doc = JSON.parse(readFileSync(`${dir}/${name}`, 'utf8'));
    for (const key of ['kind', 'protocolVersion', 'frame']) {
      if (!(key in doc)) throw new Error(`${dir}/${name}: missing "${key}"`);
    }
    if (doc.frame.kind !== doc.kind) {
      throw new Error(`${dir}/${name}: frame.kind != fixture.kind`);
    }
    if (doc.frame.v !== doc.protocolVersion) {
      throw new Error(`${dir}/${name}: frame.v != protocolVersion`);
    }
    return { name, kind: doc.kind, version: doc.protocolVersion, frame: doc.frame };
  });
}

const eventFixtures = loadFixtures('events');
const commandFixtures = loadFixtures('commands');

// The same classification tables as the Dart golden suite.
const requestKinds = { approval_request: true, ask_request: true, secret_request: true };
const serverKinds = { error: true };

test('every v1 event fixture decodes with the pinned classification', () => {
  for (const fixture of eventFixtures) {
    const decoded = decodeEvent(fixture.frame);
    if (requestKinds[fixture.kind]) {
      assert.equal(decoded.type, 'request', fixture.name);
      assert.equal(decoded.requestId, fixture.frame.id, fixture.name);
    } else if (serverKinds[fixture.kind] || fixture.kind === 'unknown_event') {
      assert.equal(decoded.type, 'unknown', fixture.name);
      if (fixture.kind === 'unknown_event') {
        assert.equal(decoded.kind, fixture.frame.originalKind, fixture.name);
      }
    } else {
      assert.equal(decoded.type, 'known', fixture.name);
      assert.equal(decoded.kind, fixture.kind, fixture.name);
    }
  }
});

test('unknown fields on any fixture frame are tolerated (additive rule)', () => {
  for (const fixture of eventFixtures) {
    const withExtra = { ...fixture.frame, x_future_field: { a: [1, 2] } };
    assert.equal(
      decodeEvent(withExtra).type,
      decodeEvent(fixture.frame).type,
      fixture.name,
    );
  }
});

test('unknown kinds degrade to the passthrough (E3)', () => {
  const decoded = decodeEvent({ v: 1, kind: 'future_widget', size: 3 });
  assert.deepEqual(decoded, {
    type: 'unknown',
    kind: 'future_widget',
    frame: { v: 1, kind: 'future_widget', size: 3 },
  });
});

test('unsupported versions are a LOUD version error', () => {
  for (const v of [0, 2, 99]) {
    assert.throws(
      () => decodeEvent({ v, kind: 'agent_start' }),
      WireVersionError,
      `v=${v}`,
    );
    assert.throws(
      () => decodeEvent({ kind: 'agent_start' }),
      WireVersionError,
      'missing v',
    );
  }
});

test('every v1 command fixture is reproduced by its builder', () => {
  const builders = {
    'prompt': (f) => promptCommand(f.text, f.v),
    'steer': (f) => steerCommand(f.text, f.v),
    'abort': (f) => abortCommand(f.v),
    'approval_response': (f) =>
      approvalResponseCommand(f.id, f.decision, f.v),
    'ask_response': (f) =>
      askResponseCommand(f.id, f.cancelled ? null : f.answers, f.v),
    'secret_response': (f) =>
      secretResponseCommand(
        f.id,
        f.granted
          ? { name: f.name, value: f.value, persisted: f.persisted }
          : null,
        f.v,
      ),
    'session_control': (f) => sessionControlCommand(f.op, f.params ?? {}, f.v),
  };
  for (const fixture of commandFixtures) {
    const build = builders[fixture.kind];
    assert.ok(build, `no builder pinned for ${fixture.kind}`);
    const built = build(fixture.frame);
    // The conformance pin: structural equality with the golden frame —
    // the same order-insensitive discipline as the Dart suite.
    assert.deepEqual(built, fixture.frame, fixture.name);
  }
});

test('handshake: hello shape, max-overlap negotiation, loud failures', () => {
  assert.deepEqual(helloFrame(), {
    v: WIRE_VERSION,
    kind: 'hello',
    versions: [WIRE_VERSION],
  });
  assert.deepEqual(helloFrame({ caps: ['tools'] }), {
    v: WIRE_VERSION,
    kind: 'hello',
    versions: [WIRE_VERSION],
    caps: ['tools'],
  });
  assert.equal(negotiate([1, 2]), 1);
  assert.throws(() => negotiate([2, 3]), WireVersionError);
  assert.equal(acceptWelcome({ v: 1, kind: 'welcome', version: 1 }), 1);
  assert.throws(
    () => acceptWelcome({ v: 1, kind: 'welcome', version: 2 }),
    WireVersionError,
  );
  assert.throws(
    () => acceptWelcome({ v: 1, kind: 'error', version: 1 }),
    WireProtocolError,
  );
});

test('NDJSON framing: one object per line, blank lines skipped', () => {
  assert.equal(frameLine({ v: 1, kind: 'abort' }), '{"v":1,"kind":"abort"}\n');
  const frame = { v: 1, kind: 'prompt', text: 'привет мир — Cyrillic integrity' };
  assert.deepEqual(parseLine(frameLine(frame)), frame);
  assert.equal(parseLine(''), null);
  assert.equal(parseLine('   \n'), null);
  assert.throws(() => parseLine('[1,2]'), WireProtocolError);
  assert.throws(() => parseLine('not json'));
});

test('E4: secret fields are redactable, live frames keep their values', () => {
  const secret = eventFixtures.find((f) => f.kind === 'secret_request');
  assert.ok(secret);
  assert.equal(isSecretField('secret_response', 'value'), true);
  assert.equal(isSecretField('model_request', 'rawWireDump'), true);
  assert.equal(isSecretField('model_request', 'detail'), false);
  assert.equal(isSecretField('prompt', 'value'), false);
  assert.equal(isSecretField('anything', 'rawBody'), true);

  const modelRequest = eventFixtures.find((f) => f.kind === 'model_request');
  const redacted = redactForLog(modelRequest.frame);
  assert.equal(redacted.rawWireDump, '[REDACTED:model_request]');
  assert.equal(JSON.stringify(redacted).includes('<raw-wire-dump-secret>'), false);
  // The live frame keeps its values.
  assert.equal(modelRequest.frame.rawWireDump, '<raw-wire-dump-secret>');

  // rawBody is SECRET anywhere; nested maps inherit the frame kind label.
  const nested = redactForLog({
    v: 1,
    kind: 'message_update',
    message: { rateLimit: { rawBody: 'LIVE-429' } },
  });
  assert.equal(
    nested.message.rateLimit.rawBody,
    '[REDACTED:message_update]',
  );
});

test('unknown_event passthrough frames are emittable', () => {
  assert.deepEqual(encodeUnknownEvent('future_widget', { size: 3 }), {
    v: 1,
    kind: 'unknown_event',
    originalKind: 'future_widget',
    payload: { size: 3 },
  });
});
