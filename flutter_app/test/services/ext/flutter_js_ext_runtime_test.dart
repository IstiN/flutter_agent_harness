// Real-engine tests for FlutterJsExtRuntime (contract section 14) — tagged
// `integration` and skipped cleanly when the flutter_js native binding cannot
// load on the test host (the deterministic app suite lives in
// app_extension_service_test.dart).
//
// Protocol coverage: commit/ping round-trip, sync + Promise invoke results
// over the __ext_host channel, the fs bridge round-trip, invoke timeout
// disposal, and the __extFatal path.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:fa/services/ext/flutter_js_ext_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_js/flutter_js.dart';

/// Send-message transport verbatim (the production bootstrap is composed by
/// AppExtensionService; the runtime only receives the source).
const String _kBootstrapTransportOnly = '''
(function (g) {
  'use strict';
  g.__extEngineId = 'flutter-js';
  if (typeof sendMessage !== 'function') {
    throw new Error('ext: send-message transport requires the flutter_js sendMessage global');
  }
  g.__extTransport = {
    call: function (method, args) {
      var s = g.__extNextSeq();
      var p = g.__extExpect(s);
      sendMessage('__ext_host', JSON.stringify({ seq: s, method: method, args: args === undefined ? {} : args }));
      return p;
    }
  };
})(globalThis);
''';

Future<FlutterJsExtRuntime> _start(
  String mainJs,
  ExtBridgeHandler bridges,
) async {
  final runtime = FlutterJsExtRuntime();
  await runtime.start(
    bootstrapJs: _kBootstrapTransportOnly,
    mainJs: mainJs,
    bridges: bridges,
  );
  return runtime;
}

Future<Object?> _nullBridge(String method, Map<String, dynamic> args) async =>
    null;

/// Probe: true when a real flutter_js engine works on this host.
Future<bool> _probeEngine() async {
  JavascriptRuntime? probe;
  try {
    probe = getJavascriptRuntime();
    final result = probe.evaluate('1 + 1');
    return !result.isError && result.stringResult == '2';
  } catch (_) {
    return false;
  } finally {
    try {
      probe?.dispose();
    } catch (_) {}
  }
}

Future<void> main() async {
  final engineAvailable = await _probeEngine();

  group(
    'FlutterJsExtRuntime (real engine)',
    () {
      test('commit round-trip: registrations surface after start', () async {
        final mainJs = '''
jsr.ext.registerTool({ name: 'ext_hello', description: 'greets', call: function (args) { return { text: 'hi ' + args.name }; } });
jsr.ext.onHook('onSessionEnd', function () {});
''';
        final runtime = await _start(mainJs, _nullBridge);
        try {
          final commit =
              await runtime.invoke(ExtJsGlobals.commit, const []) as Map;
          final tools = (commit['tools'] as List).cast<Map>();
          expect(tools.single['name'], 'ext_hello');
          expect(tools.single['handle'], 1);
          expect(commit['hooks'], hasLength(1));
          expect(
            await runtime.invoke(ExtJsGlobals.ping, const []),
            'flutter-js',
          );
        } finally {
          await runtime.dispose();
        }
      });

      test('invoke round-trip: sync and Promise tool results', () async {
        final mainJs = '''
jsr.ext.registerTool({ name: 'sync_tool', call: function (args) { return { text: 'sync:' + args.v }; } });
jsr.ext.registerTool({ name: 'async_tool', call: function (args) { return new Promise(function (resolve) { resolve({ text: 'async:' + args.v }); }); } });
''';
        final runtime = await _start(mainJs, _nullBridge);
        try {
          expect(
            await runtime.invoke(ExtJsGlobals.invoke, [
              1,
              {'v': 'Fa'},
            ]),
            {'text': 'sync:Fa'},
          );
          expect(
            await runtime.invoke(ExtJsGlobals.invoke, [
              2,
              {'v': 'Fa'},
            ]),
            {'text': 'async:Fa'},
          );
        } finally {
          await runtime.dispose();
        }
      });

      test(
        'bridge round-trip: fs.readFile resolves through the host',
        () async {
          final mainJs = '''
jsr.ext.registerTool({
  name: 'read_notes',
  call: function (args) {
    return jsr.ext.fs.readFile(args.path).then(function (content) {
      return { text: 'notes:' + content };
    });
  }
});
''';
          Future<Object?> bridges(
            String method,
            Map<String, dynamic> args,
          ) async {
            if (method == 'fs.readFile') return 'file-body';
            throw StateError('unexpected bridge: $method');
          }

          final runtime = await _start(mainJs, bridges);
          try {
            expect(
              await runtime.invoke(ExtJsGlobals.invoke, [
                1,
                {'path': 'notes.txt'},
              ]),
              {'text': 'notes:file-body'},
            );
          } finally {
            await runtime.dispose();
          }
        },
      );

      test('invoke timeout disposes the engine and throws', () async {
        final mainJs = '''
jsr.ext.registerTool({ name: 'hang', call: function () { return new Promise(function () {}); } });
''';
        final runtime = await _start(mainJs, _nullBridge);
        await expectLater(
          runtime.invoke(ExtJsGlobals.invoke, [
            1,
            const <String, dynamic>{},
          ], timeout: const Duration(milliseconds: 200)),
          throwsA(isA<TimeoutException>()),
        );
        // The timeout kill-switch released the engine.
        await expectLater(
          runtime.invoke(ExtJsGlobals.ping, const []),
          throwsA(isA<StateError>()),
        );
        await runtime.dispose(); // idempotent
      });

      test('main.js top-level throw surfaces as a start error', () async {
        final runtime = FlutterJsExtRuntime();
        await expectLater(
          runtime.start(
            bootstrapJs: _kBootstrapTransportOnly,
            mainJs: 'throw new Error("boom-main");',
            bridges: _nullBridge,
          ),
          throwsA(
            isA<ExtProtocolException>().having(
              (e) => e.message,
              'message',
              contains('boom-main'),
            ),
          ),
        );
        await runtime.dispose();
      });
    },
    skip: engineAvailable
        ? null
        : 'flutter_js engine not available on this host',
  );
}
