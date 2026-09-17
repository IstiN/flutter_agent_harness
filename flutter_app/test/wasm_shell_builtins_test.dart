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

  group('scanFlags', () {
    const empty = FlagSpec();
    const spec = FlagSpec(flags: {'-h', '--long'}, valueFlags: {'-c'});

    test('positional operands collect in order', () {
      final r = scanFlags(['a', 'b'], empty);
      expect(r.positional, ['a', 'b']);
      expect(r.flags, isEmpty);
      expect(r.values, isEmpty);
    });

    test('known boolean flags toggle', () {
      final r = scanFlags(['-h', 'x', '--long'], spec);
      expect(r.has('-h'), isTrue);
      expect(r.has('--long'), isTrue);
      expect(r.has('-c'), isFalse);
      expect(r.positional, ['x']);
    });

    test('value flags consume the next token', () {
      final r = scanFlags(['-c', 'fmt', 'file'], spec);
      expect(r.values['-c'], 'fmt');
      expect(r.positional, ['file']);
    });

    test('value flag at end of argv captures nothing', () {
      final r = scanFlags(['-c'], spec);
      expect(r.values, isEmpty);
    });

    test('unknown dash-args are skipped', () {
      final r = scanFlags(['-q', '--wat', 'path'], spec);
      expect(r.flags, isEmpty);
      expect(r.positional, ['path']);
    });
  });

  group('parseDuArgs', () {
    test('short and long flags', () {
      expect(parseDuArgs(['-h']).human, isTrue);
      expect(parseDuArgs(['--human-readable']).human, isTrue);
      expect(parseDuArgs(['-s']).summarize, isTrue);
      expect(parseDuArgs(['--summarize']).summarize, isTrue);
      expect(parseDuArgs([]).human, isFalse);
      expect(parseDuArgs([]).summarize, isFalse);
    });

    test('positional paths collect; empty argv defaults to dot', () {
      expect(parseDuArgs(['a', 'b']).paths, ['a', 'b']);
      expect(parseDuArgs([]).paths, ['.']);
    });

    test('unknown dash-args are ignored', () {
      final r = parseDuArgs(['-x', 'dir']);
      expect(r.human, isFalse);
      expect(r.paths, ['dir']);
    });
  });

  group('formatDuSize', () {
    test('non-human rounds up to K blocks', () {
      expect(formatDuSize(0, human: false), '0');
      expect(formatDuSize(1, human: false), '1');
      expect(formatDuSize(1024, human: false), '1');
      expect(formatDuSize(1025, human: false), '2');
    });

    test('human ladder rounds below 10 to one decimal', () {
      expect(formatDuSize(0, human: true), '0B');
      expect(formatDuSize(512, human: true), '512B');
      expect(formatDuSize(1024, human: true), '1.0K');
      expect(formatDuSize(1536, human: true), '1.5K');
      expect(formatDuSize(10240, human: true), '10K');
      expect(formatDuSize(1048576, human: true), '1.0M');
      expect(formatDuSize(1073741824, human: true), '1.0G');
      expect(formatDuSize(1099511627776, human: true), '1.0T');
    });

    test('human ladder stops at the last unit', () {
      expect(formatDuSize(1125899906842624, human: true), '1024T');
    });
  });

  group('reverseLines', () {
    test('reverses lines keeping the trailing newline', () {
      expect(reverseLines('a\nb\nc\n'), 'c\nb\na\n');
    });

    test('reverses lines without a trailing newline', () {
      expect(reverseLines('a\nb\nc'), 'c\nb\na\n');
    });

    test('empty content stays empty', () {
      expect(reverseLines(''), '');
    });

    test('single line with newline stays put', () {
      expect(reverseLines('solo\n'), 'solo\n');
    });

    test('inner empty lines reverse like records', () {
      expect(reverseLines('a\n\nb\n'), 'b\n\na\n');
    });
  });

  group('expandTrSet', () {
    test('ranges expand inclusively', () {
      expect(expandTrSet('a-c'), ['a', 'b', 'c']);
      expect(expandTrSet('0-2'), ['0', '1', '2']);
    });

    test('plain characters pass through', () {
      expect(expandTrSet('x!'), ['x', '!']);
    });

    test('character classes expand fully and mix with literals', () {
      expect(expandTrSet('[:digit:]'), '0123456789'.split(''));
      expect(expandTrSet('[:lower:]'), 'abcdefghijklmnopqrstuvwxyz'.split(''));
      expect(expandTrSet('[:upper:]'), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''));
      expect(
        expandTrSet('[:alnum:]'),
        ('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')
            .split(''),
      );
      expect(expandTrSet('[:space:]'), ' \t\n\r\f\v'.split(''));
      expect(expandTrSet('a[:digit:]z'), ['a', ...'0123456789'.split(''), 'z']);
    });

    test('adjacent range and class expand in sequence', () {
      expect(expandTrSet('a-c[:digit:]'), [
        ...'abc'.split(''),
        ...'0123456789'.split(''),
      ]);
    });
  });

  group('parseTrArgs / validateTrInvocation', () {
    test('plain translate operands', () {
      final r = parseTrArgs(['abc', 'xyz']);
      expect(r.delete, isFalse);
      expect(r.set1, 'abc');
      expect(r.set2, 'xyz');
      expect(validateTrInvocation(r), isNull);
    });

    test('-d toggles delete mode with one set', () {
      final r = parseTrArgs(['-d', 'aeiou']);
      expect(r.delete, isTrue);
      expect(r.set1, 'aeiou');
      expect(validateTrInvocation(r), isNull);
    });

    test('missing set1 reports missing operand', () {
      expect(validateTrInvocation(parseTrArgs([])), 'tr: missing operand');
      expect(validateTrInvocation(parseTrArgs(['-d'])), 'tr: missing operand');
    });

    test('translate without set2 names set1', () {
      final r = parseTrArgs(['abc']);
      expect(validateTrInvocation(r), 'tr: missing operand after "abc"');
    });
  });

  group('applyTr', () {
    test('translates characters through the sets', () {
      final inv = parseTrArgs(['abc', 'xyz']);
      expect(applyTr('callback', inv), 'zxllyxzk');
    });

    test('the last set2 char extends over the set1 tail', () {
      final inv = parseTrArgs(['abcd', 'xy']);
      expect(applyTr('abcd', inv), 'xyyy');
    });

    test('delete removes every set1 character', () {
      final inv = parseTrArgs(['-d', 'aeiou']);
      expect(applyTr('hello world', inv), 'hll wrld');
    });

    test('unmapped characters pass through untouched', () {
      final inv = parseTrArgs(['-d', 'z']);
      expect(applyTr('abc', inv), 'abc');
    });
  });

  group('parseXargsArgs', () {
    test('no flags: first positional is the command', () {
      final r = parseXargsArgs(['echo', 'hi']);
      expect(r.placeholder, isNull);
      expect(r.commandIndex, 0);
    });

    test('-I takes an attached placeholder', () {
      final r = parseXargsArgs(['-I{}', 'echo']);
      expect(r.placeholder, '{}');
      expect(r.commandIndex, 1);
    });

    test('-I consumes the next token as the placeholder', () {
      final r = parseXargsArgs(['-I', '%%', 'echo']);
      expect(r.placeholder, '%%');
      expect(r.commandIndex, 2);
    });

    test('-I consumes a trailing command-looking token (frozen)', () {
      final r = parseXargsArgs(['-I', 'echo']);
      expect(r.placeholder, 'echo');
      expect(r.commandIndex, 2);
    });

    test('lone -I at end of argv falls back to braces', () {
      final r = parseXargsArgs(['-I']);
      expect(r.placeholder, '{}');
      expect(r.commandIndex, 1);
    });

    test('unknown dash-args are skipped before the command', () {
      final r = parseXargsArgs(['-r', '-0', 'echo', 'x']);
      expect(r.placeholder, isNull);
      expect(r.commandIndex, 2);
    });
  });

  group('xargsInvocations', () {
    test('no placeholder appends all lines in one invocation', () {
      final r = xargsInvocations(['echo'], ['a', 'b'], null);
      expect(r, [
        ['echo', 'a', 'b'],
      ]);
    });

    test('placeholder substitutes per line', () {
      final r = xargsInvocations(['echo', 'X=1'], ['a', 'b'], 'X');
      expect(r, [
        ['echo', 'a=1'],
        ['echo', 'b=1'],
      ]);
    });

    test('empty input plans nothing in placeholder mode', () {
      expect(xargsInvocations(['echo'], [], '{}'), isEmpty);
    });
  });

  group('validateTestInvocation', () {
    test('test with no args is a missing expression', () {
      expect(validateTestInvocation('test', []), 'test: missing expression');
    });

    test('[ without the closing bracket names it', () {
      expect(validateTestInvocation('[', ['1', '=']), '[[: missing `]]');
      expect(validateTestInvocation('[', []), '[[: missing `]]');
    });

    test('well-formed argv validates clean', () {
      expect(validateTestInvocation('test', ['-z', '']), isNull);
      expect(validateTestInvocation('[', ['1', '=', '1', ']']), isNull);
    });
  });

  group('TestEvaluator', () {
    late List<String> files;
    late List<String> dirs;
    late Map<String, int> sizes;

    TestEvaluator evaluator() => TestEvaluator(
      fileExists: (p) async => files.contains(p) || dirs.contains(p),
      dirExists: (p) async => dirs.contains(p),
      fileSize: (p) async => sizes[p] ?? 0,
    );

    setUp(() {
      files = ['f.txt'];
      dirs = ['d'];
      sizes = {'f.txt': 12, 'd': 4096};
    });

    Future<bool> eval(List<String> args) => evaluator().evaluate(args);

    test('-e checks any entity existence', () async {
      expect(await eval(['-e', 'f.txt']), isTrue);
      expect(await eval(['-e', 'd']), isTrue);
      expect(await eval(['-e', 'nope']), isFalse);
    });

    test('-f is true only for files', () async {
      expect(await eval(['-f', 'f.txt']), isTrue);
      expect(await eval(['-f', 'd']), isFalse);
    });

    test('-d is true only for directories', () async {
      expect(await eval(['-d', 'd']), isTrue);
      expect(await eval(['-d', 'f.txt']), isFalse);
    });

    test('-s is true for non-empty files only', () async {
      expect(await eval(['-s', 'f.txt']), isTrue);
      files.add('empty');
      expect(await eval(['-s', 'empty']), isFalse);
    });

    test('-z and -n test string emptiness', () async {
      expect(await eval(['-z', '']), isTrue);
      expect(await eval(['-z', 'x']), isFalse);
      expect(await eval(['-n', 'x']), isTrue);
      expect(await eval(['-n', '']), isFalse);
    });

    test('binary comparisons delegate to evalTestBinaryOp', () async {
      expect(await eval(['a', '=', 'a']), isTrue);
      expect(await eval(['3', '-gt', '2']), isTrue);
      expect(await eval(['3', '-lt', '2']), isFalse);
    });

    test('! negates the following expression', () async {
      expect(await eval(['!', '-e', 'nope']), isTrue);
      expect(await eval(['!', '!', '-e', 'f.txt']), isTrue);
    });

    test('-a and -o chain with the right precedence', () async {
      expect(await eval(['-e', 'f.txt', '-a', '-e', 'd']), isTrue);
      expect(await eval(['-e', 'nope', '-o', '-e', 'd']), isTrue);
      // `-o` binds looser than `-a`: (t AND f) OR t.
      expect(
        await eval(['-e', 'f.txt', '-a', '-e', 'nope', '-o', '-e', 'd']),
        isTrue,
      );
    });

    test('parentheses group subexpressions', () async {
      expect(await eval(['(', '-e', 'nope', '-o', '-e', 'd', ')']), isTrue);
      expect(await eval(['(', '-e', 'f.txt', ')', '-a', '-d', 'd']), isTrue);
    });

    test('missing closing paren throws', () async {
      await expectLater(
        eval(['(', '-e', 'f.txt']),
        throwsA(isA<TestExpressionError>()),
      );
    });

    test('unsupported unary operator throws', () async {
      await expectLater(eval(['-q', 'x']), throwsA(isA<TestExpressionError>()));
    });

    test('unsupported binary operator throws', () async {
      await expectLater(
        eval(['a', '~~', 'b']),
        throwsA(isA<TestExpressionError>()),
      );
    });
  });
}
