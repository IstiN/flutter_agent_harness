/// Shared parity contract for the `parity-fixture` extension (issue #32).
///
/// This file is the single source of truth both parity suites compare
/// against:
///
/// - `parity_fake_test.dart` drives the fixture's registration + callback
///   semantics in Dart ([FakeJsrRuntime] standing in for the engine, with the
///   real [JsExtensionHost] bridge machinery underneath) and asserts the
///   exact commit payload + tool results.
/// - `integration/parity_engine_test.dart` runs the real `main.js` under qjs
///   and asserts the results are STRUCTURALLY IDENTICAL to what these
///   expectations produce (same keys/values, modulo the engine id field).
///
/// The Dart mirror of every `main.js` behavior lives here on purpose: if the
/// JS fixture and this file ever drift, the engine suite fails.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';

/// Directory holding the fixture files (manifest.json, main.js,
/// parity_data.txt, this contract).
const String kParityFixtureDir = 'test/js_ext/fixtures/parity_ext';

String _fixtureFile(String name) =>
    File('$kParityFixtureDir/$name').readAsStringSync();

/// The fixture `main.js`, verbatim (the engine suite evaluates this).
final String kParityMainJs = _fixtureFile('main.js');

/// Content installed at `<projectRoot>/parity_data.txt` — the path the
/// fixture's tool reads through the confined fs bridge.
const String kParityDataContent = 'parity-data-line-1\nparity-data-line-2\n';

/// First line of [kParityDataContent] (what `fs.readFile` + split yields).
const String kParityDataFirstLine = 'parity-data-line-1';

/// Manifest JSON of the fixture; [name] overridable for multi-extension
/// isolation tests (AC9) — everything else stays identical.
String parityManifestJson({String name = 'parity-fixture'}) {
  final json =
      jsonDecode(_fixtureFile('manifest.json')) as Map<String, dynamic>;
  json['name'] = name;
  return jsonEncode(json);
}

/// Store file set for the fixture: `manifest.json` + `main.js`.
Map<String, String> parityFixtureFiles({String name = 'parity-fixture'}) => {
  'manifest.json': parityManifestJson(name: name),
  'main.js': kParityMainJs,
};

/// A valid trust record pinning [files] (the installer's real hash function).
TrustRecord parityTrustRecord(Map<String, String> files) => TrustRecord(
  source: ExtTrustSource.local,
  sourceRef: '/proj/.fah/js-ext/parity',
  contentSha256: extContentHash(files),
  capabilities: const {},
  grantedAt: DateTime.utc(2026),
);

// ---------------------------------------------------------------------------
// Registration contract (the commit payload `__extCommit()` must return).
// ---------------------------------------------------------------------------

/// Handles are allocated in registration order; main.js registers in exactly
/// this order, so every engine sees the same table.
const int kHandleEchoTool = 1;
const int kHandleExecTool = 2;
const int kHandleSlash = 3;
const int kHandleFlow = 4;
const int kHandleBeforeToolCall = 5;
const int kHandleAfterToolCall = 6;
const int kHandlePrepareNextTurn = 7;
const int kHandleOnSteering = 8;
const int kHandleSessionStart = 9;
const int kHandleSessionEnd = 10;

/// The exact commit payload `__extCommit()` must return after evaluating
/// `main.js` — tools, all six hooks, slash command, and flow, byte-identical
/// between the fake and every real engine.
Map<String, dynamic> parityCommitPayload() => {
  'tools': [
    {
      'name': 'parity_echo',
      'description':
          'parity: engine identity + capability probe + fs read + echo',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
      'tier': 'read',
      'handle': kHandleEchoTool,
    },
    {
      'name': 'parity_exec',
      'description': 'parity: runs `echo ok` through the exec bridge',
      'parameters': {'type': 'object', 'properties': {}},
      'tier': 'exec',
      'handle': kHandleExecTool,
    },
  ],
  'hooks': [
    {'event': 'beforeToolCall', 'handle': kHandleBeforeToolCall},
    {'event': 'afterToolCall', 'handle': kHandleAfterToolCall},
    {'event': 'prepareNextTurn', 'handle': kHandlePrepareNextTurn},
    {'event': 'onSteering', 'handle': kHandleOnSteering},
    {'event': 'onSessionStart', 'handle': kHandleSessionStart},
    {'event': 'onSessionEnd', 'handle': kHandleSessionEnd},
  ],
  'slash': [
    {
      'name': 'parity-slash',
      'description': 'parity: writes its args back',
      'handle': kHandleSlash,
    },
  ],
  'flows': [
    {
      'id': 'parity-flow',
      'title': 'Parity Provider',
      'description': 'parity: flow submit contract',
      'fields': [
        {'name': 'token', 'label': 'Token', 'secret': true},
      ],
      'handle': kHandleFlow,
    },
  ],
};

// ---------------------------------------------------------------------------
// Behavior expectations (what each registered callback must produce).
// ---------------------------------------------------------------------------

/// `parity_echo` result text: engine identity + `has('fs')` + first line of
/// the fixture data file + echo of the `text` argument.
String parityEchoText({
  required String engineId,
  String text = '',
  bool hasFs = true,
  String fileLine = kParityDataFirstLine,
}) => 'engine=$engineId has_fs=$hasFs file=$fileLine echo=$text';

/// The `{content:[{type:'text',...}]}` result shape `parity_echo` returns
/// before the host normalizes it.
Map<String, dynamic> parityEchoResult({
  required String engineId,
  String text = '',
  bool hasFs = true,
  String fileLine = kParityDataFirstLine,
}) => {
  'content': [
    {
      'type': 'text',
      'text': parityEchoText(
        engineId: engineId,
        text: text,
        hasFs: hasFs,
        fileLine: fileLine,
      ),
    },
  ],
};

/// The shell command `parity_exec` triggers through the exec bridge.
const String kParityExecCommand = 'echo ok';

/// Stdout the scripted shell answers `echo ok` with.
const String kParityExecStdout = 'ok\n';

/// `parity_exec` result text after the fixture trims the stdout.
const String kParityExecResultText = 'ok';

/// Text the `afterToolCall` hook appends to `parity_echo` results.
const String kParityAppend = '[appended by parity]';

/// `reason` the `beforeToolCall` hook returns for `args.block == 'yes'` (the
/// host prefixes it with `[ext:<name>] `).
const String kParityBlockReason = 'parity-block';

/// Slash output line for [args] (through `io.writeln`).
String paritySlashLine(List<String> args) => 'slash:${args.join(',')}';

/// The provider object the flow's `onSubmit` returns for [token].
Map<String, dynamic> parityFlowResult(String token) => {
  'providerName': 'parity',
  'baseUrl': 'https://x.test',
  'apiKey': token,
};

/// Session note the sessionStart/sessionEnd hooks append.
String parityNote(String event) => 'parity note $event';

// ---------------------------------------------------------------------------
// Dart mirror of main.js for [FakeJsrRuntime] (no JS engine involved).
// ---------------------------------------------------------------------------

/// Registers the fixture's globals on [runtime]: `__extCommit` returns
/// [parityCommitPayload]; `__extInvoke` dispatches to Dart mirrors of the
/// main.js callbacks, making bridge calls through the runtime's `bridges`
/// handler (the real host machinery, set by `JsrRuntime.start`).
void installParityGlobals(FakeJsrRuntime runtime) {
  runtime.onGlobal('__extCommit', (_) async => parityCommitPayload());
  runtime.onGlobal('__extInvoke', (args) async {
    final handle = args[0]! as int;
    final payload = args.length > 1 ? args[1] : null;
    return _invokeParityHandle(runtime, handle, payload);
  });
}

Future<Object?> _invokeParityHandle(
  FakeJsrRuntime runtime,
  int handle,
  Object? payload,
) async {
  final bridges = runtime.bridges!;
  switch (handle) {
    case kHandleEchoTool:
      final args = payload as Map?;
      final text = args?['text'] is String ? args!['text'] as String : '';
      final hasFs = await bridges('has', {'capability': 'fs'});
      final content =
          await bridges('fs.readFile', {'path': 'parity_data.txt'}) as String;
      return parityEchoResult(
        engineId: runtime.engineId,
        text: text,
        hasFs: hasFs == true,
        fileLine: content.split('\n').first,
      );
    case kHandleExecTool:
      final res =
          await bridges('exec.run', {
                'command': 'echo',
                'args': ['ok'],
              })
              as Map;
      return {'text': (res['stdout'] as String).trim()};
    case kHandleSlash:
      // The host passes the raw args array (SlashCommand contract); the
      // fixed bootstrap wrapper forwards it to run(args, io).
      final args = [for (final e in payload as List) e.toString()];
      await bridges('io.writeln', {'text': paritySlashLine(args)});
      return null;
    case kHandleFlow:
      final values = payload as Map;
      return parityFlowResult('${values['token']}');
    case kHandleBeforeToolCall:
      final args = (payload as Map?)?['args'];
      if (args is Map && args['block'] == 'yes') {
        return {'block': true, 'reason': kParityBlockReason};
      }
      return null;
    case kHandleAfterToolCall:
      final map = payload as Map?;
      if (map?['tool'] == 'parity_echo') {
        return {'append': kParityAppend};
      }
      return null;
    case kHandlePrepareNextTurn:
    case kHandleOnSteering:
      return null;
    case kHandleSessionStart:
      await bridges('session.appendNote', {
        'text': parityNote('onSessionStart'),
      });
      return null;
    case kHandleSessionEnd:
      await bridges('session.appendNote', {'text': parityNote('onSessionEnd')});
      return null;
    default:
      throw StateError('parity fixture: no such handle $handle');
  }
}
