@TestOn('vm')
library;

/// gh-1590 acceptance: N shell-job state changes leave at most a small
/// constant of `shell_job_registry` records in the session file, and the
/// last record carries the FINAL board state (every job terminal) so a
/// resume rehydrates truthfully.
///
/// Before the fix every board mutation appended one full snapshot — the
/// deduper only suppressed byte-identical payloads, so k jobs starting
/// and settling appended 2k records (1,635 records / 136 MB on the
/// ticket's session). With the write-time throttle the mutations inside
/// the persist window coalesce into ONE snapshot plus the run-finalize
/// flush.
///
/// The persist window is pinned through the CLI's `ledgerClock` seam
/// (frozen): the record count no longer depends on all 8 mutations
/// landing inside one real 30 s window — a CI stall cannot open a
/// second window and flake the count.
///
/// gh-1622 carves ONE mutation class out of the window: a job START is
/// crash-critical. A hard kill inside the window skips the trailing
/// flush and the shutdown flush alike, so an unpersisted start would
/// silently vanish from the resume-lost count (the nightly PTY restart
/// test saw "1 background task lost" for 5 live jobs). Starts append
/// immediately; terminal churn keeps coalescing.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [Shell] + [BackgroundShell] whose detached jobs stay RUNNING until
/// the test finishes them — the controllable background job.
class _ThrottleShell implements Shell, BackgroundShell {
  final jobs = <_ThrottleJob>[];

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    // Foreground exec stays unavailable so boot probes stay out of the
    // way; only detached jobs work here.
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'No shell is available in this environment',
      ),
    );
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _ThrottleJob(command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _ThrottleJob implements ShellJob {
  _ThrottleJob({required this.command, required this.logPath});

  /// The registry id the board assigns (overrides the shell-provided one).
  @override
  String get id => logPath.split('/').last;

  @override
  final String command;
  @override
  final String logPath;
  int? _exitCode;
  final _settled = Completer<void>();

  @override
  int? get pid => null;
  @override
  bool get isRunning => !_settled.isCompleted;
  @override
  int? get exitCode => _exitCode;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  /// The test's settle trigger.
  void finish(int code) {
    if (_settled.isCompleted) return;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Future<void> stop() async => finish(9);
}

/// Streams the scripted turns: run 1 opens all [jobCount] background jobs
/// in one tool round and ends the turn; every later run (settle-notice
/// reactions) answers 'ack.'.
class _JobSpawnerStream {
  _JobSpawnerStream({required this.jobCount});

  final int jobCount;
  var leadPlayed = false;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final script = leadPlayed
        ? textTurn('ack.')
        : toolTurn([
            for (var i = 1; i <= jobCount; i++)
              ToolCall(
                id: 't$i',
                name: 'bash',
                arguments: {'command': 'sleep 60 # job $i', 'background': true},
              ),
          ]);
    leadPlayed = true;
    final stream = AssistantMessageEventStream();
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 4000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: $reason');
}

/// Every `.jsonl` file under [root] (sessions live one cwd-slug level
/// down; MemoryFileSystem has no recursive listing).
Future<List<String>> _sessionFiles(FileSystem fs, String root) async {
  final found = <String>[];
  final listed = await fs.listDir(root);
  if (listed.isErr) return found;
  for (final info in listed.valueOrNull!) {
    if (info.kind == FileKind.directory) {
      found.addAll(await _sessionFiles(fs, info.path));
    } else if (info.name.endsWith('.jsonl')) {
      found.add(info.path);
    }
  }
  return found;
}

/// The `shell_job_registry` payloads of a session file, in file order.
Future<List<List<dynamic>>> shellJobRegistryRecords(
  FileSystem fs,
  String path,
) async {
  final content = (await fs.readTextFile(path)).getOrThrow();
  final payloads = <List<dynamic>>[];
  for (final line in content.split('\n')) {
    if (line.trim().isEmpty) continue;
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    if (decoded['type'] != 'custom') continue;
    if (decoded['customType'] != 'shell_job_registry') continue;
    final data = decoded['data'];
    if (data is List) payloads.add(data);
  }
  return payloads;
}

void main() {
  test(
    'N shell-job state changes leave a small constant of '
    'shell_job_registry records; the last carries every terminal state '
    '(gh-1590)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const jobCount = 4;
      final io = FakeCliIO();
      final shell = _ThrottleShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final stream = _JobSpawnerStream(jobCount: jobCount);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: stream.call,
        // The frozen clock pins the persist window (review, gh-1590):
        // the record-count pin below is deterministic, not dependent on
        // a healthy runner finishing the run inside 30 s.
        ledgerClock: () => DateTime(2026, 10, 13, 12),
      );
      final run = cli.runHeadless('spawn the background jobs');
      await _waitFor(
        () => shell.jobs.length == jobCount,
        reason: 'all $jobCount jobs register',
      );
      // Every job settles — with the old per-mutation append that alone
      // wrote jobCount more full snapshots.
      for (final job in shell.jobs) {
        job.finish(0);
      }
      final code = await run;
      expect(code, 0, reason: 'the run completes with the settled jobs');

      final files = await _sessionFiles(env, '/sessions');
      expect(files, hasLength(1), reason: 'one session file was written');
      final payloads = await shellJobRegistryRecords(env, files.single);
      expect(
        payloads,
        isNotEmpty,
        reason: 'the board state persisted at least once',
      );
      // gh-1590 acceptance: state changes leave a small constant of
      // records instead of one per change. gh-1622 carves out one
      // exception: a job START bypasses the window (a crash inside it
      // must never strand a started job off the record), so k starts
      // append k snapshots; the settles still coalesce into the
      // run-finalize flush.
      expect(
        payloads.length,
        lessThanOrEqualTo(jobCount + 1),
        reason:
            'starts are crash-critical appends; terminal churn '
            'coalesces behind the finalize flush',
      );
      // The FINAL state reached the file: every job terminal — a resume
      // rehydrates through the LAST record and must never show running.
      final finalBoard = payloads.last;
      expect(finalBoard, hasLength(jobCount));
      for (final card in finalBoard) {
        expect(
          (card as Map)['state'],
          'done',
          reason: 'the flush lands the final board state',
        );
      }
    },
  );
  test(
    'a job start reaches the file inside the persist window: a crash '
    'cannot strand started jobs off the record (gh-1622)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Mirrors the PTY restart repro (scenario B): 5 live jobs, then a
      // hard kill — no settle, no finalize flush. The resume reads only
      // the LAST `shell_job_registry` snapshot; before the fix the
      // persist window coalesced starts 2..k away and that snapshot
      // carried only job 1 ("1 background task lost" for 5 live jobs).
      const jobCount = 5;
      final io = FakeCliIO();
      final shell = _ThrottleShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final stream = _JobSpawnerStream(jobCount: jobCount);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: stream.call,
        ledgerClock: () => DateTime(2026, 10, 15, 12),
      );
      final run = cli.runHeadless('spawn the background jobs');
      await _waitFor(
        () => shell.jobs.length == jobCount,
        reason: 'all $jobCount jobs register',
      );
      // The crash moment: the file must already carry every started job
      // as running — the fix appends each start instead of waiting for a
      // flush a SIGKILL would skip. (Pre-fix this stalls at 1.)
      var last = const <dynamic>[];
      for (var i = 0; i < 4000; i++) {
        final files = await _sessionFiles(env, '/sessions');
        if (files.length == 1) {
          final payloads = await shellJobRegistryRecords(env, files.single);
          if (payloads.isNotEmpty) last = payloads.last;
          if (last.length == jobCount) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        last,
        hasLength(jobCount),
        reason:
            'every started job is in the last snapshot before any '
            'flush — a crash here resumes with the full lost count',
      );
      for (final card in last) {
        expect(
          (card as Map)['state'],
          'running',
          reason: 'the jobs were live at the crash moment',
        );
      }
      // Clean teardown only — the pins above were taken before this.
      for (final job in shell.jobs) {
        job.finish(0);
      }
      final code = await run;
      expect(code, 0, reason: 'the run completes with the settled jobs');
    },
  );
  test(
    'a session with NO background jobs never grows a shell_job_registry '
    'record (gh-1590: the finalize flush must not append empty '
    'snapshots)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final shell = _ThrottleShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          for (final event in textTurn('plain answer, no jobs')) {
            stream.push(event);
          }
          stream.end();
          return stream;
        },
        ledgerClock: () => DateTime(2026, 10, 13, 12),
      );
      final code = await cli.runHeadless('answer without any jobs');
      expect(code, 0);
      final files = await _sessionFiles(env, '/sessions');
      expect(files, hasLength(1), reason: 'one session file was written');
      final payloads = await shellJobRegistryRecords(env, files.single);
      expect(
        payloads,
        isEmpty,
        reason:
            'an empty board must never append '
            'an empty `[]` snapshot — that would grow every no-job session '
            'and defeat the empty-session cleanup',
      );
    },
  );
}
