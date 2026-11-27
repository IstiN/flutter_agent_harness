// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Issue #2415, tool-layer fd-pressure guard: an EMFILE spawn failure is a
// typed, environmental error — retried ONCE (a settle beat lets in-flight
// drains finish), then reported honestly. The simulated Err rides the
// same seam a real `Process.start` EMFILE produces (typed at
// IoExecutionEnv._start) — no real fd is ever exhausted here.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// An exec shell with a scripted fd-pressure failure count, then success.
final class _PressureShell implements Shell {
  _PressureShell(this.pressuredCalls);

  int pressuredCalls;
  int execCalls = 0;

  static ExecutionError _fdPressure() => ExecutionError(
    ExecutionErrorCode.fdExhausted,
    'fd pressure: cannot spawn "sh" (ProcessException: Too many open '
    'files, errno = 24) — the process fd soft limit is 256. Not a command '
    'failure: the session is out of open file descriptors (pipes of '
    'running bash jobs, hooks, watchers). Wait for background jobs to '
    'settle, stop unneeded jobs, or raise the limit (ulimit -n).',
  );

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    execCalls++;
    if (pressuredCalls > 0) {
      pressuredCalls--;
      return Err(_fdPressure());
    }
    return const Ok(ShellExecResult(stdout: 'ran', stderr: '', exitCode: 0));
  }
}

/// A plain fake env whose exec rides the scripted shell (the
/// bash_auto_background_test pattern, no background capability).
final class _FakeEnv implements ExecutionEnv {
  _FakeEnv(Shell shell) : _shell = shell;

  final Shell _shell;

  @override
  String get cwd => '/work';

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _shell.exec(command, options: options);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

void main() {
  test('an fd-pressure spawn failure is retried once, then succeeds', () async {
    final shell = _PressureShell(1);
    final tool = shellTool(_FakeEnv(shell), retryBackoff: Duration.zero);
    final result = await tool.execute({'command': 'make'}, null, null);
    expect(_text(result), contains('ran'));
    expect(shell.execCalls, 2);
    expect(_text(result), contains('fd pressure'));
  });

  test('persistent fd pressure fails with the typed, honest text — '
      'exactly one retry, no uncaught mislabel', () async {
    final shell = _PressureShell(99);
    final tool = shellTool(_FakeEnv(shell), retryBackoff: Duration.zero);
    await expectLater(
      tool.execute({'command': 'make'}, null, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('fd pressure'), contains('ulimit -n')),
        ),
      ),
    );
    // One retry, then the wall: 2 exec attempts total.
    expect(shell.execCalls, 2);
    // The thrown text is the spawn failure, never a harness defect.
    // (The agent loop renders this StateError as operational — see
    // tool_cancelled_error_test.)
  });

  test('a plain spawn failure is NOT retried as fd pressure', () async {
    final env = _PlainSpawnFailEnv();
    final tool = shellTool(env, retryBackoff: Duration.zero);
    await expectLater(
      tool.execute({'command': 'make'}, null, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('spawnError'),
        ),
      ),
    );
    expect(env.execCalls, 1);
  });
}

/// An env whose exec fails with a NON-fd spawn error (single-shot).
final class _PlainSpawnFailEnv implements ExecutionEnv {
  int execCalls = 0;

  @override
  String get cwd => '/work';

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    execCalls++;
    return Err(
      ExecutionError(
        ExecutionErrorCode.spawnError,
        'ExecutionError(spawnError): ProcessException: No such file or '
        'directory',
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
