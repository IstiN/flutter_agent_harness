/// Real-engine parity suite for the `parity-fixture` extension (issue #32):
/// evaluates the fixture's actual main.js under quickjs-ng (qjs subprocess,
/// stdio transport) through the full [JsExtensionHost] bridge machinery, and
/// asserts every result is STRUCTURALLY IDENTICAL to the fake-protocol
/// expectations in `fixtures/parity_ext/parity_contract.dart` — the same
/// keys/values, modulo the engine id field (`qjs-process`).
///
/// Requires a `qjs` binary (quickjs-ng) on `PATH` or via `FA_QJS_BIN`;
/// every test skips cleanly when it is missing. Tagged `integration` — run
/// with: `FA_QJS_BIN=/tmp/qjsbin/qjs dart test --tags integration`.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../fixtures/parity_ext/parity_contract.dart';
import '../helpers/parity_harness.dart';
import '../helpers/scripted_env.dart';

/// Hard ceiling for every await: the suite must never hang.
const _bound = Duration(seconds: 30);

Future<T> _limit<T>(FutureOr<T> future) => Future<T>.value(
  future,
).timeout(_bound, onTimeout: () => throw TimeoutException('test hang'));
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

void main() {
  final notes = <String>[];
  final ioLines = <String>[];

  tearDown(() {
    notes.clear();
    ioLines.clear();
  });

  /// Loads the fixture through a REAL qjs subprocess evaluating main.js.
  Future<JsExtensionHost> engineHost({ScriptedShell? shell}) async {
    final (_, _, host) = await installParityHost(
      runtimeFactory: () => QjsProcessRuntime(),
      shell: shell,
      notes: notes,
      ioLines: ioLines,
    );
    return host;
  }

  test(
    'commit payload is byte-identical to the fake-protocol expectations',
    () async {
      QjsProcessRuntime? runtime;
      final (_, _, host) = await installParityHost(
        runtimeFactory: () {
          runtime = QjsProcessRuntime();
          return runtime!;
        },
      );
      expect(host.enginesByExtension, {'parity-fixture': 'qjs-process'});
      // THE parity assertion: the real engine's registration payload equals
      // the contract (and therefore the fake suite's payload) key-for-key.
      expect(await _limit(runtime!.commitPayload), parityCommitPayload());
      expect(host.hooksByExtension['parity-fixture'], hasLength(6));
      await _limit(host.dispose());
    },
    skip: _qjsSkip,
  );

  test(
    'parity_echo: engine=qjs-process + has_fs + fixture file line (THE parity)',
    () async {
      final host = await engineHost();
      final tool = host.tools.singleWhere((t) => t.name == 'parity_echo');
      final result = await _limit(tool.execute({'text': 'hello'}, null, null));
      // Structurally identical to parity_fake_test's assertion, modulo the
      // engine id field.
      expect(
        resultText(result),
        parityEchoText(engineId: 'qjs-process', text: 'hello'),
      );
      await _limit(host.dispose());
    },
    skip: _qjsSkip,
  );

  test('parity_exec: `echo ok` runs host-side through the exec gate', () async {
    final shell = ScriptedShell([
      const ShellExecResult(stdout: kParityExecStdout, stderr: '', exitCode: 0),
    ]);
    final host = await engineHost(shell: shell);
    final tool = host.tools.singleWhere((t) => t.name == 'parity_exec');
    final result = await _limit(tool.execute(const {}, null, null));
    expect(resultText(result), kParityExecResultText);
    expect(shell.commands, [kParityExecCommand]);
    await _limit(host.dispose());
  }, skip: _qjsSkip);

  test('beforeToolCall block path via a blocking tool call', () async {
    final host = await engineHost();
    final agent = testAgent();
    host.attachHooks(agent);
    final blocking = await _limit(
      agent.beforeToolCall!(
        beforeContext('parity_echo', {'block': 'yes', 'text': 'x'}),
        null,
      ),
    );
    expect(blocking?.block, isTrue);
    expect(blocking?.reason, '[ext:parity-fixture] $kParityBlockReason');
    await _limit(host.dispose());
  }, skip: _qjsSkip);

  test('afterToolCall append lands on the parity_echo result', () async {
    final host = await engineHost();
    final agent = testAgent();
    host.attachHooks(agent);
    final appended = await _limit(
      agent.afterToolCall!(afterContext('parity_echo', 'echo-body'), null),
    );
    expect(appended?.content?.whereType<TextContent>().map((b) => b.text), [
      'echo-body',
      kParityAppend,
    ]);
    await _limit(host.dispose());
  }, skip: _qjsSkip);

  test('slash parity-slash writes slash:a,b through io.writeln', () async {
    final host = await engineHost();
    final slash = host.slashCommands['parity-slash'];
    expect(slash, isNotNull);
    await _limit(slash!(['a', 'b']));
    expect(ioLines, [
      paritySlashLine(['a', 'b']),
    ]);
    await _limit(host.dispose());
  }, skip: _qjsSkip);

  test('flow submit returns the provider object', () async {
    final host = await engineHost();
    final entry = host.providerFlows['ext:parity-fixture:parity-flow'];
    expect(entry, isNotNull);
    expect(entry!.flow.fields.single.secret, isTrue);
    final result = await _limit(entry.submit({'token': 'sk-test'}));
    expect(result, parityFlowResult('sk-test'));
    await _limit(host.dispose());
  }, skip: _qjsSkip);

  test('sessionStart note is recorded through the session bridge', () async {
    final host = await engineHost();
    await _limit(host.sessionStart());
    expect(notes, [parityNote('onSessionStart')]);
    await _limit(host.dispose());
  }, skip: _qjsSkip);
}
