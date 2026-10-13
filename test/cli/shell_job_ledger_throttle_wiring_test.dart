@TestOn('vm')
library;

/// gh-1590 acceptance: N shell-job state changes leave at most a small
/// constant of `shell_job_registry` records in the session file.
///
/// Before the fix every board mutation appended one full snapshot — the
/// deduper only suppressed byte-identical payloads, so k jobs starting
/// and settling appended 2k records (1,635 records / 136 MB on the
/// ticket's session). With the write-time throttle the mutations inside
/// the window coalesce into ONE snapshot, and the run-finalize flush
/// lands the final state (every job terminal) so resume never loses a
/// settle.

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

  @Override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _ThrottleJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _ThrottleJob implements ShellJob {
  _ThrottleJob({
    required this.id,
    required this.command,
    required this.logPath,
  });

  final String id;
  final String command;
  final String logPath;
  int? _exitCode;
  final _settled = Completer<void>();

  @override
  String get id => id;
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

Future<void> _waitFor(bool Function() condition, {required String reason}) async {
  for (var i = 0; i < 4000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: $reason');
}

/// Every `.jsonl` file under [root] (MemoryFileSystem has no recursive
/// listing — sessions live one cwd-slug level down).
Future<List<String>> _sessionFiles(FileSystem fs, String root) async {
  final found = <String>[];
  final listed = await fs.listDir(root);
  if (listed.isErr) return found;
  for (final entry in listed.valueOrNull!) {
    if (entry.kind == FileKind.directory) {
      found.addAll(await _sessionFiles(fs, '$root/${entry.name}'));
    } else if (entry.name.endsWith('.jsonl')) {
      found.add('$root/${entry.name}');
    }
  }
  return found;
}

/// The `shell_job_registry` records of a session file, in file order.
Future<List<List<dynamic>>> shellJobRegistryRecords(
  FileSystem fs,
  String path,
) async {
  final content = (await fs.readTextFile(path)).getOrThrow();
  final records = <List<dynamic>>[];
  for (final line in content.split('\n')) {
    if (line.trim().isEmpty) continue;
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    if (decoded['type'] != 'custom') continue;
    if (decoded['customType'] != 'shell_job_registry') continue;
    final data = decoded['data'];
    if (data is List) records.add(data);
  }
  return records;
}

void main() {
  test(
    'N shell-job state changes leave a small constant of '
    'shell_job_registry records, the last carrying every terminal state '
    '(gh-1590)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const jobCount = 4;
      final io = FakeCliIO();
      final shell = _ThrottleShell();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(cwd: '/work', shell: shell),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        // The lead turn starts every job in one tool round and ends the
        // turn; the settle-notice reaction runs answer 'ack.'.
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          final firstRun = context.messages
              .whereType<UserMessage>()
              .where((m) => m.content.toString().contains('spawn the jobs'))
              .isNotEmpty;
          for (final event in firstRun
              ? toolTurn([
                  for (var i = 1; i <= jobCount; i++)
                    ToolCall(
                      id: 't$i',
                      name: 'bash',
                      arguments: {
                        'command': 'sleep 60 & # job $i',
                        'background': true,
                      },
                    ),
                ])
              : textTurn('ack.')).withTimeout()
          // ignore: unnecessary_statements
              ;
          stream.end();
          return stream;
        },
      );
      final run = cli.runHeadless('spawn the jobs');
      await _waitFor(
        () => shell.jobs.length == jobCount,
        reason: 'all $jobCount jobs register',
      );
      // Every job settles — with a per-mutation append that alone would
      // write jobCount more snapshots.
      for (final job in shell.jobs) {
        job.finish(0);
      }
      final code = await run;
      expect(code, 0, reason: 'the run completes with the settled jobs');

      final files = await _sessionFiles(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        '/sessions',
      );
      // The env above is the CLI's own store; resolve through a fresh
      // view of the SAME in-memory tree is impossible — read via the
      // config env captured at construction instead.
      fail('placeholder — replaced below');
    },
  );
}
