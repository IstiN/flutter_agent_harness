// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the pure shell-semantics helpers extracted from
// WasiSandboxShell (issue #475 CRAP descent). No WASM cores are loaded.

import 'dart:convert';

import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/sandbox/wasm_shell_builtins.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseGrepArgs', () {
    test('positional pattern and files', () {
      final r = parseGrepArgs(['foo', 'a.txt', 'b.txt'])!;
      expect(r.pattern, 'foo');
      expect(r.files, ['a.txt', 'b.txt']);
      expect(r.flags, isEmpty);
      expect(r.quiet, isFalse);
    });

    test('-e consumes the next arg as pattern', () {
      final r = parseGrepArgs(['-e', 'pat', 'file'])!;
      expect(r.pattern, 'pat');
      expect(r.files, ['file']);
    });

    test('-e without a value returns null', () {
      expect(parseGrepArgs(['-e']), isNull);
      expect(parseGrepArgs(['file', '-e']), isNull);
    });

    test('quiet flags set quiet', () {
      for (final f in ['-q', '--quiet', '--silent']) {
        expect(parseGrepArgs([f, 'p'])!.quiet, isTrue, reason: f);
      }
      expect(parseGrepArgs(['p'])!.quiet, isFalse);
    });

    test('recursive/extended flags accepted and ignored', () {
      final r = parseGrepArgs(['-r', '-R', '-E', '--', 'p'])!;
      expect(r.flags, isEmpty);
      expect(r.pattern, 'p');
    });

    test('pass-through flags forwarded verbatim', () {
      final r = parseGrepArgs([
        '-i',
        '-v',
        '-w',
        '-x',
        '-F',
        '-n',
        '-c',
        '-l',
        'p',
      ])!;
      expect(r.flags, ['-i', '-v', '-w', '-x', '-F', '-n', '-c', '-l']);
      expect(r.pattern, 'p');
    });

    test('-m consumes its count, -mN stays as-is', () {
      expect(parseGrepArgs(['-m', '3', 'p'])!.flags, ['-m', '3']);
      expect(parseGrepArgs(['-m3', 'p'])!.flags, ['-m3']);
    });

    test('-m at end of argv consumes the following token', () {
      final r = parseGrepArgs(['-m', 'p'])!;
      expect(r.flags, ['-m', 'p']);
      expect(r.pattern, isNull);
    });

    test('empty argv yields no pattern', () {
      expect(parseGrepArgs([])!.pattern, isNull);
    });
  });

  group('collectStageRedirects', () {
    test('stdin read redirect', () {
      final r = collectStageRedirects([
        Redirect(kind: RedirectKind.read, fd: 0, target: 'in.txt'),
      ]);
      expect(r.stdinFile, 'in.txt');
      expect(r.stdoutFile, isNull);
      expect(r.stderrFile, isNull);
    });

    test('stdout write and append', () {
      final w = collectStageRedirects([
        Redirect(kind: RedirectKind.write, fd: 1, target: 'o.txt'),
      ]);
      expect(w.stdoutFile, 'o.txt');
      expect(w.appendStdout, isFalse);

      final a = collectStageRedirects([
        Redirect(kind: RedirectKind.append, fd: 1, target: 'o.txt'),
      ]);
      expect(a.stdoutFile, 'o.txt');
      expect(a.appendStdout, isTrue);
    });

    test('stderr write and append', () {
      final w = collectStageRedirects([
        Redirect(kind: RedirectKind.write, fd: 2, target: 'e.txt'),
      ]);
      expect(w.stderrFile, 'e.txt');
      expect(w.appendStderr, isFalse);

      final a = collectStageRedirects([
        Redirect(kind: RedirectKind.append, fd: 2, target: 'e.txt'),
      ]);
      expect(a.stderrFile, 'e.txt');
      expect(a.appendStderr, isTrue);
    });

    test('fd -1 write lands on stdout only', () {
      final r = collectStageRedirects([
        Redirect(kind: RedirectKind.write, fd: -1, target: 'both.txt'),
      ]);
      expect(r.stdoutFile, 'both.txt');
      expect(r.appendStdout, isFalse);
      expect(r.stderrFile, isNull);
    });

    test('fd -1 append lands on stdout append only', () {
      final r = collectStageRedirects([
        Redirect(kind: RedirectKind.append, fd: -1, target: 'both.txt'),
      ]);
      expect(r.stdoutFile, 'both.txt');
      expect(r.appendStdout, isTrue);
      expect(r.stderrFile, isNull);
    });

    test('later redirect for the same stream wins', () {
      final r = collectStageRedirects([
        Redirect(kind: RedirectKind.write, fd: 1, target: 'first.txt'),
        Redirect(kind: RedirectKind.append, fd: 1, target: 'second.txt'),
      ]);
      expect(r.stdoutFile, 'second.txt');
      expect(r.appendStdout, isTrue);
    });

    test('combined stdin/stdout/stderr in one stage', () {
      final r = collectStageRedirects([
        Redirect(kind: RedirectKind.read, fd: 0, target: 'i'),
        Redirect(kind: RedirectKind.write, fd: 1, target: 'o'),
        Redirect(kind: RedirectKind.write, fd: 2, target: 'e'),
      ]);
      expect(r.stdinFile, 'i');
      expect(r.stdoutFile, 'o');
      expect(r.stderrFile, 'e');
    });

    test('no redirects yields all-null targets', () {
      final r = collectStageRedirects(const []);
      expect(r.stdinFile, isNull);
      expect(r.stdoutFile, isNull);
      expect(r.stderrFile, isNull);
      expect(r.appendStdout, isFalse);
      expect(r.appendStderr, isFalse);
    });
  });

  group('stripSigpipeNoise', () {
    test('strips bare Broken pipe line', () {
      final input = utf8.encode('before\nBroken pipe\nafter\n');
      expect(utf8.decode(stripSigpipeNoise(input)), 'before\nafter\n');
    });

    test('strips tool-scoped broken pipe lines', () {
      final input = utf8.encode('cat: stdout: Broken pipe\nkept\n');
      expect(utf8.decode(stripSigpipeNoise(input)), 'kept\n');
    });

    test('keeps python BrokenPipeError tracebacks', () {
      final input = utf8.encode('BrokenPipeError: [Errno 32] Broken pipe\n');
      expect(stripSigpipeNoise(input), same(input));
    });

    test('returns identical bytes when no noise present', () {
      final input = utf8.encode('plain output\n');
      expect(stripSigpipeNoise(input), same(input));
    });

    test('mixed noise and signal in one buffer', () {
      final input = utf8.encode('head: stdout: Broken pipe\nreal error\n');
      expect(utf8.decode(stripSigpipeNoise(input)), 'real error\n');
    });
  });

  group('evalTestBinaryOp', () {
    test('string equality operators', () {
      expect(evalTestBinaryOp('=', 'a', 'a'), isTrue);
      expect(evalTestBinaryOp('=', 'a', 'b'), isFalse);
      expect(evalTestBinaryOp('!=', 'a', 'b'), isTrue);
      expect(evalTestBinaryOp('!=', 'a', 'a'), isFalse);
    });

    test('numeric comparisons', () {
      expect(evalTestBinaryOp('-eq', '2', '2'), isTrue);
      expect(evalTestBinaryOp('-ne', '2', '3'), isTrue);
      expect(evalTestBinaryOp('-lt', '2', '3'), isTrue);
      expect(evalTestBinaryOp('-le', '3', '3'), isTrue);
      expect(evalTestBinaryOp('-gt', '5', '3'), isTrue);
      expect(evalTestBinaryOp('-ge', '3', '3'), isTrue);
      expect(evalTestBinaryOp('-lt', '5', '3'), isFalse);
    });

    test('unsupported operator returns null', () {
      expect(evalTestBinaryOp('-z', 'a', 'b'), isNull);
      expect(evalTestBinaryOp('~~', 'a', 'b'), isNull);
    });

    test('non-numeric operands propagate FormatException', () {
      expect(() => evalTestBinaryOp('-eq', 'x', '1'), throwsFormatException);
    });
  });

  group('WasiSandboxShell.resolveStageOutcome', () {
    final timeout = const Duration(seconds: 30);

    test('callback error wins over everything', () {
      final callbackErr = ExecutionError(
        ExecutionErrorCode.callbackError,
        'cb',
      );
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: callbackErr,
        timedOut: true,
        runError: StateError('trap'),
        timeout: timeout,
        cancelled: true,
        hasOutput: true,
      );
      expect(r.isErr, isTrue);
      expect(r.errorOrNull, same(callbackErr));
    });

    test('timeout surfaces a timeout error', () {
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: null,
        timedOut: true,
        runError: null,
        timeout: timeout,
        cancelled: false,
        hasOutput: true,
      );
      expect(r.errorOrNull?.message, 'timeout: $timeout');
    });

    test('cancellation surfaces aborted', () {
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: null,
        timedOut: false,
        runError: null,
        timeout: timeout,
        cancelled: true,
        hasOutput: true,
      );
      expect(r.errorOrNull?.message, 'aborted');
    });

    test('normal exit parses from the trap', () {
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: null,
        timedOut: false,
        runError: Exception('Exited with i32 exit status 7'),
        timeout: timeout,
        cancelled: false,
        hasOutput: false,
      );
      expect(r.valueOrNull, 7);
    });

    test('clean run exits 0', () {
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: null,
        timedOut: false,
        runError: null,
        timeout: timeout,
        cancelled: false,
        hasOutput: false,
      );
      expect(r.valueOrNull, 0);
    });

    test('unparsable trap without output surfaces the raw error', () {
      final trap = StateError('wasi trap');
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: null,
        timedOut: false,
        runError: trap,
        timeout: timeout,
        cancelled: false,
        hasOutput: false,
      );
      expect(r.isErr, isTrue);
      expect(r.errorOrNull?.cause, same(trap));
    });

    test('unparsable trap with output degrades to exit 1', () {
      final r = WasiSandboxShell.resolveStageOutcome(
        callbackError: null,
        timedOut: false,
        runError: StateError('wasi trap'),
        timeout: timeout,
        cancelled: false,
        hasOutput: true,
      );
      expect(r.valueOrNull, 1);
    });
  });
}
