/// Real-process integration tests for [QjsProcessRuntime] over quickjs-ng.
///
/// Requires a `qjs` binary (quickjs-ng) on `PATH` or via `FA_QJS_BIN`;
/// every engine-dependent test skips cleanly when [QjsProcessRuntime.engineProbe]
/// fails. Tagged `integration` — excluded from the pre-commit gate, run with:
/// `dart test --tags integration`.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_js.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:test/test.dart';

/// Hard ceiling for every await: the suite must never hang.
const _bound = Duration(seconds: 20);

Future<T> _limit<T>(Future<T> future) => future.timeout(
  _bound,
  onTimeout: () => throw TimeoutException('test hang'),
);

/// Sync availability probe for the `skip:` parameter: false when a usable
/// qjs binary resolves, otherwise the skip reason.
final Object _qjsSkip = () {
  final bin = QjsProcessRuntime.resolveBinary();
  if (bin.contains(Platform.pathSeparator)) {
    return File(bin).existsSync() ? false : 'FA_QJS_BIN binary not found: $bin';
  }
  for (final dir in (Platform.environment['PATH'] ?? '').split(
    Platform.pathSeparator,
  )) {
    if (dir.isEmpty) continue;
    final f = File('$dir/$bin');
    if (f.existsSync() && (f.statSync().mode & 73) != 0) return false;
  }
  return 'qjs (quickjs-ng) not found on PATH; install it or set FA_QJS_BIN';
}();

/// Contract §7: adapter bootstrap = transport + core.
const _bootstrap = '$kExtTransportStdioJs\n;\n$kExtBootstrapCoreJs';

/// Extension registering an echo tool and writing one bridge line at load.
const _echoMainJs = '''
jsr.ext.registerTool({ name: 'echo', description: 'echoes its args', call: (args) => args });
jsr.ext.io.write('hello-from-ext');
''';

Future<Object?> _recordingBridges(
  List<String> written,
  String method,
  Map<String, dynamic> args,
) async {
  if (method == 'io.write' || method == 'io.writeln') {
    written.add('${args['text']}');
  }
  return null;
}

void main() {
  group('QjsProcessRuntime', () {
    test('composeScript matches the pinned host composition', () {
      final script = QjsProcessRuntime.composeScript('<BOOT>', '<MAIN>');
      expect(
        script,
        'globalThis.__extFatal=function(m){ '
        'print(JSON.stringify({fatal:m})); };\n'
        '<BOOT>\n;try{\n<MAIN>\n'
        '}catch(e){ __extFatal(String(e && e.message || e)); }\n',
      );
    });

    test('missing binary => ExtEngineUnavailableException', () async {
      final runtime = QjsProcessRuntime(
        binary: '/nonexistent/fa-qjs-missing',
        startTimeout: const Duration(seconds: 5),
      );
      await expectLater(
        _limit(
          runtime.start(
            bootstrapJs: _bootstrap,
            mainJs: _echoMainJs,
            bridges: (_, _) async => null,
          ),
        ),
        throwsA(
          isA<ExtEngineUnavailableException>().having(
            (e) => e.toString(),
            'toString',
            contains('FA_QJS_BIN'),
          ),
        ),
      );
      await _limit(runtime.dispose());
    });

    test('engineProbe returns a version string', () async {
      final version = await _limit(QjsProcessRuntime.engineProbe());
      expect(version, isNotEmpty);
    }, skip: _qjsSkip);

    test('start + __extPing + tool invoke + bridge + dispose', () async {
      final written = <String>[];
      final runtime = QjsProcessRuntime();

      await _limit(
        runtime.start(
          bootstrapJs: _bootstrap,
          mainJs: _echoMainJs,
          bridges: (method, args) => _recordingBridges(written, method, args),
        ),
      );

      final commit = await _limit(runtime.commitPayload);
      final tools = commit['tools'] as List<Object?>;
      final echo =
          tools.singleWhere(
                (t) => (t as Map<String, dynamic>)['name'] == 'echo',
              )
              as Map<String, dynamic>;

      expect(
        await _limit(runtime.invoke('__extPing', const [])),
        'qjs-process',
      );

      final handle = echo['handle'] as int;
      final result = await _limit(
        runtime.invoke('__extInvoke', [
          handle,
          const {'a': 1},
        ]),
      );
      expect(result, const {'a': 1});

      expect(written, contains('hello-from-ext'));

      await _limit(runtime.dispose());
      await _limit(runtime.dispose()); // idempotent
    }, skip: _qjsSkip);

    test('start times out and kills on infinite-loop main.js', () async {
      final runtime = QjsProcessRuntime(
        startTimeout: const Duration(milliseconds: 1200),
      );
      await expectLater(
        _limit(
          runtime.start(
            bootstrapJs: _bootstrap,
            mainJs: 'while (true) {}',
            bridges: (_, _) async => null,
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await _limit(runtime.dispose());
      await _limit(runtime.dispose()); // idempotent
    }, skip: _qjsSkip);

    test('invoke timeout sigkills the engine', () async {
      final runtime = QjsProcessRuntime();
      await _limit(
        runtime.start(
          bootstrapJs: _bootstrap,
          mainJs:
              "jsr.ext.registerTool({ name: 'spin', description: 'spins', "
              'call: () => { while (true) {} } });',
          bridges: (_, _) async => null,
        ),
      );
      final commit = await _limit(runtime.commitPayload);
      final tools = commit['tools'] as List<Object?>;
      final spin =
          tools.singleWhere(
                (t) => (t as Map<String, dynamic>)['name'] == 'spin',
              )
              as Map<String, dynamic>;
      final handle = spin['handle'] as int;

      await expectLater(
        _limit(
          runtime.invoke('__extInvoke', [
            handle,
            null,
          ], timeout: const Duration(milliseconds: 800)),
        ),
        throwsA(isA<TimeoutException>()),
      );

      // The engine was SIGKILLed; the next invoke fails fast, never hangs.
      await expectLater(
        _limit(runtime.invoke('__extPing', const [])),
        throwsA(isA<StateError>()),
      );

      await _limit(runtime.dispose());
    }, skip: _qjsSkip);

    test(
      'JS evaluation error surfaces as fatal ExtProtocolException',
      () async {
        final runtime = QjsProcessRuntime();
        await expectLater(
          _limit(
            runtime.start(
              bootstrapJs: _bootstrap,
              mainJs: 'throw new Error("boom-at-load");',
              bridges: (_, _) async => null,
            ),
          ),
          throwsA(
            isA<ExtProtocolException>().having(
              (e) => e.toString(),
              'toString',
              contains('boom-at-load'),
            ),
          ),
        );
        await _limit(runtime.dispose());
      },
      skip: _qjsSkip,
    );
  });
}
