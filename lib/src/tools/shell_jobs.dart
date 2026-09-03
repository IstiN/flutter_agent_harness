/// Session-scoped registry of background shell jobs (`bash background: true`
/// and steer-yielded foreground commands).
///
/// A job is a [ShellJob] started through the [BackgroundShell] capability of
/// the environment (local processes only — sandboxed/web environments do not
/// implement it and the tools answer a clean "not supported here" note).
/// stdout/stderr stream into a log file under `.fah/bash_jobs/` so both the
/// model (`bash_job output`, the `read` tool) and the user can inspect it
/// while the job runs.
///
/// When a job settles, [ShellJobRegistry.onSettled] fires — the host turns
/// it into a follow-up/steer message (omp's async-result flow, the same one
/// background `task` jobs use), so the model learns about completions at the
/// next step boundary without polling. A foreground bash call that consumed
/// its job's result inline suppresses that notification
/// ([ShellJobEntry.suppressSettleNotification]) to avoid a duplicate.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_sandbox/flutter_sandbox.dart';

final Random _shellJobRandom = Random.secure();

/// Globally-unique background job id: several fa processes share one
/// workspace, so per-process counters alone (`sh-1`, `sh-2`) would make
/// them append to the SAME `.fah/bash_jobs/<id>.log` and interleave each
/// other's captured output. The microsecond stamp plus a random tail makes
/// cross-process collisions practically impossible.
String newShellJobId(int n) {
  final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = _shellJobRandom.nextInt(1 << 32).toRadixString(36);
  return 'sh-$n-$micros$rand';
}

/// One registered background shell job.
final class ShellJobEntry {
  ShellJobEntry._(this.job);

  /// The backend handle.
  final ShellJob job;

  bool _notifyOnSettle = true;

  String get id => job.id;

  /// The command line being executed.
  String get command => job.command;

  /// The log file receiving the job's stdout and stderr.
  String get logPath => job.logPath;

  /// Whether the process is still running.
  bool get isRunning => job.isRunning;

  /// The process exit code, or null while running.
  int? get exitCode => job.exitCode;

  /// Why the job was stopped early ('timeout'/'cancelled'/'stopped'), or
  /// null when it exited on its own.
  String? get stopReason => job.stopReason;

  /// Completes when the process exits.
  Future<void> get settled => job.settled;

  /// Terminates the process.
  Future<void> stop() => job.stop();

  /// The caller that awaited this job inline (foreground bash that finished
  /// before a steer-yield) reports the result itself — suppress the
  /// registry's settle notification so the model is not told twice.
  void suppressSettleNotification() => _notifyOnSettle = false;
}

/// `sh-7.log` — the pre-unique-id job-log name scheme. Every fa build older
/// than the collision fix starts its background-job counter at 1 per
/// process, so a file with this shape freshly modified in OUR bash_jobs
/// directory means a stale fa process is also writing here.
bool isOldFormatJobLogName(String name) {
  if (!name.startsWith('sh-') || !name.endsWith('.log')) return false;
  final n = name.substring(3, name.length - 4);
  return n.isNotEmpty && int.tryParse(n) != null;
}

/// The session's background shell jobs. See the library doc.
final class ShellJobRegistry {
  /// Creates a registry over [env]; [onSettled] fires when a job exits and
  /// nobody consumed its result inline.
  ShellJobRegistry({
    required this.env,
    this.onSettled,
    this.onStaleJobLog,
    DateTime? bootTime,
  }) : _bootTime = bootTime ?? DateTime.now();

  /// The environment jobs run in.
  final ExecutionEnv env;

  /// Fires when a job exits and nobody consumed its result inline.
  final void Function(ShellJobEntry job)? onSettled;

  /// Fires at most ONCE per session when a background-job log with the
  /// old, pre-unique-id name (`sh-<n>.log`) is modified after this registry
  /// was created — proof that another fa process on an older build shares
  /// this directory and its job output can interleave with stale files.
  /// Hosts surface it as a "restart that instance" hint.
  final void Function(String path)? onStaleJobLog;

  /// Registry creation time; old-format logs modified before it are
  /// historical debris, not a live stale instance.
  final DateTime _bootTime;
  var _staleJobLogWarned = false;
  final _jobs = <ShellJobEntry>[];
  var _nextId = 1;

  /// Whether the environment can run detached jobs at all.
  bool get isSupported {
    final baseEnv = env;
    if (baseEnv case final BackgroundShell bg) {
      return bg.backgroundJobsSupported;
    }
    return false;
  }

  /// All jobs of this session, oldest first.
  List<ShellJobEntry> get jobs => List.unmodifiable(_jobs);

  /// Looks up a job by id, or null.
  ShellJobEntry? job(String id) {
    for (final entry in _jobs) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Starts [command] as a background job. Throws [StateError] with a clean
  /// note when the environment has no [BackgroundShell] capability.
  Future<ShellJobEntry> start(
    String command, {
    ShellExecOptions? options,
  }) async {
    final baseEnv = env;
    if (baseEnv is! BackgroundShell) {
      throw StateError(
        'Background shell jobs are not supported in this environment '
        '(the shell cannot detach processes).',
      );
    }
    final bg = baseEnv as BackgroundShell;
    final id = newShellJobId(_nextId++);
    final dir = '${baseEnv.cwd}/.fah/bash_jobs';
    await baseEnv.createDir(dir);
    final logPath = '$dir/$id.log';
    unawaited(_checkStaleOldFormatJobLogs(dir));
    final started = await bg.startShellJob(
      command,
      id: id,
      logPath: logPath,
      options: options,
    );
    if (started.isErr) {
      throw StateError(started.errorOrNull!.message);
    }
    final entry = ShellJobEntry._(started.valueOrNull!);
    _jobs.add(entry);
    unawaited(
      entry.settled.then((_) async {
        // An inline consumer (foreground bash that awaited this same settle)
        // resumes on the same microtask train AFTER this listener was
        // registered — give it one event-loop turn to suppress the
        // notification so the model is not told twice.
        await Future<void>.delayed(Duration.zero);
        if (entry._notifyOnSettle) onSettled?.call(entry);
      }),
    );
    return entry;
  }

  /// Reads the last [maxLines] lines of the job's log (the whole log when
  /// shorter). Returns an empty string when nothing has been written yet.
  Future<String> tail(String id, {int maxLines = 50}) async {
    final entry = job(id);
    if (entry == null) {
      throw StateError('unknown background job: $id');
    }
    final content = await env.readTextFile(entry.logPath);
    if (content.isErr) return '';
    final lines = content.valueOrNull!.split('\n');
    // A trailing newline is the line terminator, not an extra empty line.
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    return lines.sublist(start).join('\n').trimRight();
  }

  /// One-per-session scan for freshly-written old-format job logs (see
  /// [onStaleJobLog]). Runs after each job start — a stale sibling instance
  /// may wake up at any point during the session.
  Future<void> _checkStaleOldFormatJobLogs(String dir) async {
    if (_staleJobLogWarned || onStaleJobLog == null) return;
    final listed = await env.listDir(dir);
    if (listed.isErr) return;
    for (final info in listed.valueOrNull!) {
      if (!isOldFormatJobLogName(info.name)) continue;
      final modified = DateTime.fromMillisecondsSinceEpoch(info.mtimeMs);
      if (modified.isAfter(_bootTime)) {
        _staleJobLogWarned = true;
        onStaleJobLog?.call(info.path);
        return;
      }
    }
  }
}
