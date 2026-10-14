// gh-1604 AC1 — the bounded model-facing job label and the 60-job registry
// fixture. The model-visible registry material (settle notices + the
// `bash_job status` wall) must stop accreting full command strings: every
// job card keeps id/state/exit code and the first/last ~120 chars of the
// (whitespace-flattened) command, the per-session notice stream shrinks
// >=10x against the pre-gh-1604 shape, and the status wall never exceeds
// K lines (running + last K completed + the overflow tail).
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A controllable fake background job over the in-memory fs (the
/// shell_jobs_test.dart pattern).
final class _FakeShellJob implements ShellJob {
  _FakeShellJob(this.id, this.command, this.logPath);

  final _output = StreamController<String>.broadcast();
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;
  @override
  bool get isRunning => _exitCode == null;
  @override
  int? get exitCode => _exitCode;
  @override
  String? get stopReason => _stopReason;
  @override
  Future<void> get settled => _settled.future;
  @override
  Stream<String> get output => _output.stream;
  @override
  bool writeStdin(String data) => true;
  @override
  Future<void> stop() async {
    _stopReason = 'stopped';
    complete(143);
  }

  void complete(int code, {String? reason}) {
    if (_exitCode != null) return;
    _stopReason = reason;
    _exitCode = code;
    _settled.complete();
  }
}

/// MemoryExecutionEnv wrapper with the [BackgroundShell] capability
/// (the shell_jobs_test.dart pattern: explicit delegation for the members
/// the registry/tools use, loud noSuchMethod for the rest).
final class _FakeBackgroundEnv implements ExecutionEnv, BackgroundShell {
  _FakeBackgroundEnv(this._delegate);

  final MemoryExecutionEnv _delegate;
  final jobs = <_FakeShellJob>[];

  @override
  bool get backgroundJobsSupported => true;
  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _FakeShellJob(id, command, logPath);
    jobs.add(job);
    return Ok(job);
  }

  @override
  String get cwd => _delegate.cwd;
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);
  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// One evidence-shaped job command: a long single-line pipeline. The bench
/// evidence (`make-mips-interpreter__jF7GNFh`) showed ~10 KB registry
/// snapshots whose entries carried complete command strings — multi-KB
/// single-line pipelines are the shape that flooded the model-visible
/// material.
String _longPipeline(int chars, int seed) {
  final buffer = StringBuffer('cd /app && python3 mips.py --trace --dump ');
  while (buffer.length < chars) {
    buffer.write('x$seed');
  }
  return buffer.toString().substring(0, chars);
}

void main() {
  group('shellJobCommandLabel (gh-1604 item 1)', () {
    test('short commands pass through (flattened)', () {
      expect(shellJobCommandLabel('make all'), 'make all');
    });

    test('multi-line commands flatten to one line', () {
      final label = shellJobCommandLabel('cat > x.md << \'EOF\'\nbody\nEOF');
      expect(label, isNot(contains('\n')), reason: 'never multi-line');
      expect(label, 'cat > x.md << \'EOF\' body EOF');
    });

    test('long commands keep first/last ~120 chars with a true count', () {
      final command = _longPipeline(2400, 1);
      final label = shellJobCommandLabel(command);
      expect(label.length, lessThan(300));
      expect(label, startsWith(command.substring(0, 120)));
      expect(label, endsWith(command.substring(command.length - 120)));
      final match = RegExp(r'\[…(\d+) chars…\]').firstMatch(label);
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), command.length - 240);
      // The head and tail never blur together: the marker separates them.
      expect(label.indexOf('…'), lessThan(label.lastIndexOf('…')));
    });

    test('cuts never split a surrogate pair', () {
      // 119 ASCII + a surrogate pair + tail filler: a naive 120-char head
      // cut would land between the pair's halves.
      final command = '${'a' * 119}𐀀${'b' * 400}';
      final label = shellJobCommandLabel(command);
      // The head cut moved INWARD (dropped the whole pair from the head)
      // instead of splitting it: no half a pair ever dangles at a cut.
      expect(label.startsWith('a' * 119), isTrue);
      expect(
        label.startsWith('a' * 119 + String.fromCharCode(0xDC00)),
        isFalse,
      );
    });

    test('a multi-line command with an empty first line keeps a command '
        'face (gh-1604 rework)', () {
      // The first line is taken from the TRIMMED command: a leading
      // newline must not degenerate the label to " […N chars…]" —
      // leading space, no command face.
      final command = '\ncat data.bin\n${'payload' * 40}';
      final label = shellJobCommandLabel(command);
      expect(label, startsWith('cat data.bin'));
      expect(label, isNot(startsWith(' ')));
      expect(label, isNot(contains('\n')));
    });

    test('a heredoc body never re-enters the label through the tail '
        '(issue #599 RED contract)', () {
      // The bench command shape at heredoc scale: the opener, a long
      // multi-line body, the terminator. A multi-line command's label is
      // HEAD-ONLY — the tail chars of a heredoc are body lines, and the
      // #599 owner contract says the body is never a transcript row
      // source, so a settle notice must not be able to echo them back.
      final command = [
        "cat > heredoc-target.md << 'EOF'",
        for (var i = 1; i <= 58; i++) 'heredoc body line $i padding',
        'EOF',
      ].join('\n');
      final label = shellJobCommandLabel(command);
      expect(label, isNot(contains('heredoc body line')));
      expect(label, startsWith("cat > heredoc-target.md << 'EOF'"));
      final match = RegExp(r'\[…(\d+) chars…\]').firstMatch(label);
      expect(match, isNotNull);
      expect(
        int.parse(match!.group(1)!),
        command.replaceAll(RegExp(r'\s+'), ' ').trim().length -
            "cat > heredoc-target.md << 'EOF'".length,
      );
    });
  });

  group('bash_job status wall (gh-1604 item 1)', () {
    late _FakeBackgroundEnv env;
    late ShellJobRegistry registry;
    late AgentTool tool;

    setUp(() {
      env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      registry = ShellJobRegistry(env: env);
      tool = bashJobTool(registry);
    });

    test(
      'status lines carry id, state, exit code and the bounded label',
      () async {
        final entry = await registry.start(_longPipeline(2000, 2));
        env.jobs.single.complete(0);
        // Settle bookkeeping runs on the registry listener.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        final result = await tool.execute(_statusArgs(), null, null);
        final text = _textOf(result);
        expect(text, contains('${entry.id}: exited(0)'));
        expect(text, contains('…'));
        // Every status line stays bounded — a 2000-char command can never
        // render in full again.
        for (final line in text.split('\n')) {
          expect(line.length, lessThan(400), reason: line);
        }
      },
    );

    test('a running job renders the bounded label too', () async {
      await registry.start(_longPipeline(2000, 3));
      final result = await tool.execute(_statusArgs(), null, null);
      expect(_textOf(result), contains(': running — '));
      expect(_textOf(result).length, lessThan(500));
    });
  });

  group('gh-1604 AC1: the 60-job registry fixture', () {
    test('model-visible registry material shrinks >=10x; the wall stays '
        'within K lines', () async {
      const jobCount = 60;
      const commandChars = 2400;
      final env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      final registry = ShellJobRegistry(env: env);
      final tool = bashJobTool(registry);
      final entries = <ShellJobEntry>[];
      for (var i = 0; i < jobCount; i++) {
        entries.add(await registry.start(_longPipeline(commandChars, i)));
      }
      for (final job in env.jobs) {
        job.complete(0);
      }
      // The registry's settle listeners run their bookkeeping.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // NEW: the model-visible registry material — one bounded settle
      // notice per job (one-shot, never re-rendered) plus the on-demand
      // status wall.
      final notices = [
        for (final entry in entries) shellJobSettleNoticeText(entry),
      ];
      final statusResult = await tool.execute(_statusArgs(), null, null);
      final statusText = _textOf(statusResult);
      final newBytes = notices.join().length + statusText.length;

      // OLD (pre-gh-1604): the accreting shape from the bench evidence —
      // the full registry re-rendered per turn (60 cards with COMPLETE
      // command strings, ~10 KB per snapshot) for every turn of a
      // 60-turn session, plus the same per-job notices at the old
      // unbounded shape (full first line each).
      final oldSnapshot = [
        for (final entry in entries)
          // The old status/card line carried the full command.
          '${entry.id}: exited(0) — ${entry.command}',
      ].join('\n').length;
      final oldNotices = [
        for (final entry in entries)
          // The old notice embedded the full first line (single-line
          // commands: the whole command).
          'Background shell job ${entry.id} finished with exit code 0.\n'
              'Command: ${entry.command}\n',
      ].join().length;
      const turns = jobCount;
      final oldBytes = oldSnapshot * turns + oldNotices;

      expect(
        newBytes * 10,
        lessThanOrEqualTo(oldBytes),
        reason:
            'registry material must shrink >=10x: old=$oldBytes new=$newBytes',
      );

      // The wall never exceeds K lines: running + last K completed +
      // the honest overflow tail. All 60 jobs are settled here, so the
      // default listing shows the last 20 exited plus the tail line.
      expect(statusText.split('\n').length, lessThanOrEqualTo(30));
    });
  });
}

Map<String, dynamic> _statusArgs() => {'action': 'status'};

String _textOf(ToolExecutionResult result) => result.content
    .whereType<TextContent>()
    .map((block) => block.text)
    .join('\n');
