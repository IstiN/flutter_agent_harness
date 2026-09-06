/// Real-engine integration suite for the bundled `crap-guard` extension
/// (issue #32): the actual bundled main.js runs end-to-end under quickjs-ng
/// through [JsExtensionHost] with bridges over a scripted exec environment —
/// the 2800-line cap, the `**.g.dart` exclusion, the E17 one-time
/// degradation note, and the onSessionEnd offender report.
///
/// The guard's 2s debounce window is driven deterministically: the test
/// bootstrap prelude pins `Date.now` and exposes `__extAdvanceClock(ms)`,
/// which the test reaches through the runtime's invoke seam (no real sleeps).
///
/// Requires a `qjs` binary (quickjs-ng) on `PATH` or via `FA_QJS_BIN`;
/// every test skips cleanly when it is missing. Tagged `integration` — run
/// with: `FA_QJS_BIN=/tmp/qjsbin/qjs dart test --tags integration`.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/js_ext/bundled/bundled_exts.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_js.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../helpers/parity_harness.dart';
import '../helpers/scripted_env.dart';

/// Hard ceiling for every await: the suite must never hang.
const _bound = Duration(seconds: 30);

Future<T> _limit<T>(FutureOr<T> future) => Future<T>.value(
  future,
).timeout(_bound, onTimeout: () => throw TimeoutException('test hang'));

/// Sync availability probe for the `skip:` parameter (same shape as
/// test/cli/ext_engine_process_test.dart).
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

/// Test bootstrap: pins the guard's clock (debounce determinism) before the
/// production stdio transport + core.
const String _bootstrap =
    'globalThis.__extClockMs = 1000000;\n'
    'Date.now = function () { return globalThis.__extClockMs; };\n'
    'globalThis.__extAdvanceClock = function (ms) { '
    'globalThis.__extClockMs += Number(ms); return globalThis.__extClockMs; };\n'
    '$kExtTransportStdioJs\n;\n$kExtBootstrapCoreJs';

const String _activationNoteFragment = 'crap4dart not activated';

/// A realistic `crap4dart analyze` console report. Header rows must never
/// parse as data rows (the guard follows the real column format).
String _analyze({String row = ''}) =>
    '  CRAP  COV%  BR%  CC  Class.method  file:line\n'
    '  ----  ----  ---  --  -----------  ---------\n'
    '$row';

const String _offenderRow = '15.50  0.0  N/A  4  Foo.bar  lib/x.dart:10';

ShellExecResult _analyzeResult({String row = ''}) => ShellExecResult(
  stdout: _analyze(row: row),
  stderr: '',
  exitCode: 0,
);

void main() {
  final notes = <String>[];
  final followUps = <String>[];

  tearDown(() {
    notes.clear();
    followUps.clear();
  });

  /// Installs the bundled guard, loads it under a real qjs subprocess, and
  /// wires it into the host sinks. [execResponses] script the host-side
  /// shell the exec bridge runs against; [files] seeds the project.
  Future<
    ({JsExtensionHost host, QjsProcessRuntime runtime, ScriptedShell shell})
  >
  guardHost({
    List<ShellExecResult> execResponses = const [],
    Map<String, String> files = const {},
  }) async {
    final shell = ScriptedShell(execResponses);
    final env = ScriptedShellEnv(shell: shell);
    for (final entry in files.entries) {
      (await env.writeFile('/proj/${entry.key}', entry.value)).getOrThrow();
    }
    final store = ExtensionStore(
      env: env,
      projectDir: '/proj',
      userDir: '/home',
    );
    await store.write(
      'crap-guard',
      files: kBundledExtensions['crap-guard']!,
      trust: TrustRecord(
        source: ExtTrustSource.bundled,
        sourceRef: 'bundled',
        contentSha256: extContentHash(kBundledExtensions['crap-guard']!),
        capabilities: const {},
        grantedAt: DateTime.utc(2026),
      ),
    );
    QjsProcessRuntime? runtime;
    final host =
        JsExtensionHost(
            env: env,
            store: store,
            runtimeFactory: (_) {
              runtime = QjsProcessRuntime();
              return runtime!;
            },
            bootstrapJs: _bootstrap,
          )
          ..onAppendNote = notes.add
          ..onFollowUp = followUps.add;
    final report = await _limit(host.loadAll());
    expect(report.loaded, ['crap-guard'], reason: 'guard must load');
    expect(report.errors, isEmpty);
    return (host: host, runtime: runtime!, shell: shell);
  }

  /// Fires the guard's afterToolCall hook for a write of [path].
  Future<AfterToolCallResult?> writeEdit(JsExtensionHost host, String path) {
    final agent = testAgent();
    host.attachHooks(agent);
    return _limit(
      agent.afterToolCall!(
        afterContext('write', 'ok', args: {'path': path, 'content': ''}),
        null,
      ),
    );
  }

  /// The append half of a hook result (the base 'ok' text excluded).
  String? appendOf(AfterToolCallResult? result) {
    final texts = result?.content?.whereType<TextContent>().map((b) => b.text);
    if (texts == null) return null;
    return texts.where((t) => t != 'ok').join('\n').isEmpty
        ? null
        : texts.where((t) => t != 'ok').join('\n');
  }

  test(
    'afterToolCall: 3000-line .dart file is flagged over the 2800-line cap',
    () async {
      final dartLines = List.generate(
        3000,
        (i) => '// line ${i + 1}',
      ).join('\n');
      final scene = await guardHost(
        execResponses: [_analyzeResult()],
        files: {'lib/big.dart': dartLines},
      );
      final result = await writeEdit(scene.host, 'lib/big.dart');
      final append = appendOf(result);
      expect(append, isNotNull);
      expect(append, contains('lines (max 2800)'));
      expect(append, contains('lib/big.dart'));
      expect(scene.shell.commands, ['dart pub global run crap4dart analyze']);
      await _limit(scene.host.dispose());
    },
    skip: _qjsSkip,
  );

  test('excluded generated path (**.g.dart) never triggers a check', () async {
    final scene = await guardHost(
      files: {'lib/generated.g.dart': '// generated\n'},
    );
    final result = await writeEdit(scene.host, 'lib/generated.g.dart');
    expect(result, isNull);
    expect(scene.shell.commands, isEmpty);
    expect(notes, isEmpty);
    await _limit(scene.host.dispose());
  }, skip: _qjsSkip);

  test(
    'E17: not-found exec yields exactly one activation note, then silence',
    () async {
      const notFound = ShellExecResult(
        stdout: '',
        stderr: 'dart: command not found',
        exitCode: 127,
      );
      final scene = await guardHost(
        execResponses: [notFound, notFound],
        files: {'lib/a.dart': '// a\n', 'lib/b.dart': '// b\n'},
      );

      // First guarded check: the one-time degradation note rides the append.
      final first = await writeEdit(scene.host, 'lib/a.dart');
      final firstAppend = appendOf(first);
      expect(firstAppend, contains(_activationNoteFragment));

      // Advance past the debounce window; the second check runs but stays
      // fully silent (the note is per-session).
      await _limit(scene.runtime.invoke('__extAdvanceClock', [3000]));
      final second = await writeEdit(scene.host, 'lib/b.dart');
      expect(second, isNull, reason: 'silent degradation: no append at all');

      expect(scene.shell.commands.length, 2, reason: 'both checks ran');
      expect(notes, isEmpty, reason: 'degradation rides the append, not notes');
      await _limit(scene.host.dispose());
    },
    skip: _qjsSkip,
  );

  test(
    'onSessionEnd: fake crap4dart offender => appendNote + followUp recorded',
    () async {
      final scene = await guardHost(
        execResponses: [
          _analyzeResult(),
          _analyzeResult(row: '$_offenderRow\n'),
          _analyzeResult(row: '$_offenderRow\n'),
        ],
        files: {'lib/x.dart': '// x\n'},
      );

      // A guarded edit with a clean report: the session now has guarded
      // edits (the sessionEnd pre-condition) and nothing to append.
      final check = await writeEdit(scene.host, 'lib/x.dart');
      expect(appendOf(check), isNull, reason: 'clean analyze: no append');

      // sessionEnd: the full analyze reports the offender via appendNote;
      // the follow-up stays pending (E14) and lands at the NEXT delivery.
      await _limit(scene.runtime.invoke('__extAdvanceClock', [3000]));
      await _limit(scene.host.sessionEnd());
      expect(notes, hasLength(1));
      expect(notes.single, contains('crap-guard session report:'));
      expect(notes.single, contains('CRAP regression in Foo.bar'));
      expect(notes.single, contains('score 15.50 (max 12)'));
      expect(
        followUps,
        isEmpty,
        reason: 'follow-up enqueued during the hook stays pending',
      );

      // The next sessionEnd delivers the queued follow-up first (E14).
      await _limit(scene.runtime.invoke('__extAdvanceClock', [3000]));
      await _limit(scene.host.sessionEnd());
      expect(followUps, [
        '[ext:crap-guard] CRAP regressions: Foo.bar — fix before next session',
      ]);
      await _limit(scene.host.dispose());
    },
    skip: _qjsSkip,
  );
}
