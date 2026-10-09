/// Session-scoped registry of background shell jobs (`bash background: true`
/// and steer-yielded foreground commands).
///
/// A job is a [ShellJob] started through the [BackgroundShell] capability of
/// the environment (local processes only — sandboxed/web environments do not
/// implement it and the tools answer a clean "not supported here" note).
/// stdout/stderr stream into a log file under `.fah/bash_jobs/` so both the
/// model (`bash_job output`, the `read` tool) and the user can inspect it
/// while the job runs. Bench/unattended runs relocate the directory
/// ([jobLogDir], env `FAH_JOB_LOG_DIR`) so the harness's own artifacts never
/// land in the graded task workspace (issue #1408 AC1), and pipe the writes
/// through a redactor ([jobLogRedactor]) so secret values never rest in the
/// logs (issue #1408 AC2).
///
/// When a job settles, [ShellJobRegistry.onSettled] fires — the host's
/// terminal bookkeeping (the job board's Running count, the waiting row)
/// hangs off it. The host turns it into a follow-up/steer message (omp's
/// async-result flow, the same one background `task` jobs use) so the
/// model learns about completions at the next step boundary without
/// polling. A foreground bash call that consumed its job's result inline
/// skips only that model-facing notice
/// ([ShellJobEntry.suppressSettleNotification]) to avoid a duplicate —
/// the bookkeeping itself always runs (issue #562).
library;

import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../env/execution_env.dart';
import '../env/job_log_ceiling.dart';
import '../env/job_log_redaction.dart';
import 'job_id_resolution.dart';
// The boot-sweep process-table probe is VM-only infrastructure (`ps` via
// dart:io); web builds get a stub that always reports "no process table".
import '../env/process_probe_stub.dart'
    if (dart.library.io) '../env/process_probe_io.dart';

final Random _shellJobRandom = Random.secure();

/// The environment variable a bench/unattended run sets to relocate the
/// bash-job log directory OUTSIDE the task workspace (issue #1408 AC1) —
/// the in-container twin of the runner's `$RUNNER_TEMP`. The CLI resolves
/// it at boot (lib/ stays dart:io-free) and hands the value to
/// [ShellJobRegistry.jobLogDir].
const shellJobLogDirEnvVar = 'FAH_JOB_LOG_DIR';

/// The [shellJobLogDirEnvVar] value from [env], trimmed; null when unset or
/// blank. Pure — the executable owns the `Platform.environment` read.
String? jobLogDirOverride(Map<String, String> env) {
  final value = env[shellJobLogDirEnvVar]?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

/// Globally-unique background job id: several fa processes share one
/// workspace, so per-process counters alone (`sh-1`, `sh-2`) would make
/// them append to the SAME `.fah/bash_jobs/<id>.log` and interleave each
/// other's captured output. The microsecond stamp plus a random tail makes
/// cross-process collisions practically impossible.
String newShellJobId(int n) {
  final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  // dart2js: shifts are 32-bit — `1 << 32` == 0, so nextInt(0) would throw
  // on web and kill every bash call (issue #1074). Spell the bound literally.
  final rand = _shellJobRandom.nextInt(0xFFFFFFFF).toRadixString(36);
  return 'sh-$n-$micros$rand';
}

/// One registered background shell job.
final class ShellJobEntry {
  ShellJobEntry._(this.job, {this.cwd}) : startedAt = DateTime.now();

  /// The backend handle.
  final ShellJob job;

  /// When the job registered (drives the terminal card's elapsed).
  final DateTime startedAt;

  /// When the registry observed the job's exit (gh-1438) — null while
  /// running. Drives the status line's "exited Nm ago" context and the
  /// retained-entry GC's LRU order. Stamped by the registry's settle
  /// listener; first observation wins.
  DateTime? _settledAt;
  DateTime? get settledAt => _settledAt;

  /// The working directory the job was started from (the dim detail's cwd
  /// tail, issue #429 AC2).
  final String? cwd;

  /// Whether the model-facing settle notice should still be delivered (a
  /// foreground consumer that took the result inline clears it). The
  /// registry's settle bookkeeping runs regardless — see
  /// [ShellJobRegistry.onSettled].
  bool _notifyOnSettle = true;

  String get id => job.id;

  /// The command line being executed.
  String get command => job.command;

  /// The log file receiving the job's stdout and stderr.
  String get logPath => job.logPath;

  /// The job's root process id, when the environment exposes one.
  int? get pid => job.pid;

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
  /// before a steer-yield) reports the result itself — clear the model
  /// notice so the model is not told twice. The job board and waiting row
  /// still settle through [ShellJobRegistry.onSettled] (issue #562).
  void suppressSettleNotification() => _notifyOnSettle = false;

  /// Whether the model-facing settle notice is still pending; hosts check
  /// this before steering the completion into the conversation.
  bool get notifyOnSettle => _notifyOnSettle;
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
  /// Creates a registry over [env]; [onStart] fires when a job starts
  /// (the hub's start block), [onSettled] when a job exits. [jobLogMaxBytes]
  /// and [onJobLogWarning] (issue #919) are merged into every start's
  /// options — the size ceiling and the low-disk warning channel; null
  /// bytes means the shells' built-in default. A caller's own options
  /// values take precedence over these session defaults.
  ShellJobRegistry({
    required this.env,
    this.onStart,
    this.onSettled,
    this.onStaleJobLog,
    this.jobLogMaxBytes,
    this.onJobLogWarning,
    this.jobLogDir,
    this.jobLogRedactor,
    this.maxRetainedExitedJobs = defaultMaxRetainedExitedJobs,
    DateTime? bootTime,
  }) : _bootTime = bootTime ?? DateTime.now();

  /// How many exited jobs the registry retains (gh-1438 second tier).
  /// Production monitor sessions ran thousands of short-lived jobs and the
  /// grow-only list kept every entry — with its log text — for the process
  /// lifetime. Beyond the cap the oldest-settled entries are pruned (LRU by
  /// settle time); their log FILES stay on disk and exact-id lookups fall
  /// back to them ([prunedLogPath]/[tailFromLog], AC4). Running jobs are
  /// never pruned.
  static const defaultMaxRetainedExitedJobs = 100;

  /// The exited-entry retention cap; see [defaultMaxRetainedExitedJobs].
  final int maxRetainedExitedJobs;

  /// The environment jobs run in.
  final ExecutionEnv env;

  /// Fires on every job exit — the host's terminal bookkeeping (job
  /// board, waiting row) hangs off it. Whether the MODEL is also told is
  /// the host's call, via [ShellJobEntry.notifyOnSettle] (issue #562).
  final void Function(ShellJobEntry job)? onSettled;

  /// Fires when a job successfully starts (issue #277 task blocks).
  final void Function(ShellJobEntry job)? onStart;

  /// Fires at most ONCE per session when a background-job log with the
  /// old, pre-unique-id name (`sh-<n>.log`) is modified after this registry
  /// was created — proof that another fa process on an older build shares
  /// this directory and its job output can interleave with stale files.
  /// Hosts surface it as a "restart that instance" hint.
  final void Function(String path)? onStaleJobLog;

  /// Log size ceiling merged into every job start (issue #919); null lets
  /// the shell apply its built-in default ([defaultJobLogMaxBytes]).
  final int? jobLogMaxBytes;

  /// Low-disk warning channel merged into every job start (issue #919) —
  /// fired at most once per job, when log writes stop.
  final void Function(String message)? onJobLogWarning;

  /// Where job logs live (issue #1408 AC1); defaults to
  /// `<cwd>/.fah/bash_jobs`. Bench/unattended runs point this OUTSIDE the
  /// task workspace (env `FAH_JOB_LOG_DIR`, e.g. the container's /tmp) so
  /// the graded diff never sees harness artifacts.
  final String? jobLogDir;

  /// At-rest redaction merged into every job start (issue #1408 AC2) —
  /// typically `RedactionPipeline.redact`. Secret-shaped output becomes
  /// `[REDACTED:<kind>]` markers in the log FILE; null keeps raw bytes
  /// (hosts that run no pipeline). A caller's per-call
  /// [ShellExecOptions.jobLogRedactor] wins over this session default.
  final String Function(String text)? jobLogRedactor;

  /// Registry creation time; old-format logs modified before it are
  /// historical debris, not a live stale instance.
  final DateTime _bootTime;
  var _staleJobLogWarned = false;
  final _jobs = <ShellJobEntry>[];
  var _nextId = 1;

  /// GC tombstones: pruned exited ids → their on-disk log path (gh-1438
  /// AC4). Ids and paths only — cheap enough to keep for the session.
  final _prunedLogPaths = <String, String>{};

  /// The on-disk log of a GC'd (pruned) exited job, or null when [id] was
  /// never pruned. The log may itself be gone (deleted by retention sweeps)
  /// — callers treat a failed read as today's clean unknown-id error (E2).
  String? prunedLogPath(String id) => _prunedLogPaths[id];

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
    // Issue #1408 AC1: the bench relocation keeps harness artifacts outside
    // the graded task workspace.
    final dir = jobLogDir ?? '${baseEnv.cwd}/.fah/bash_jobs';
    await baseEnv.createDir(dir);
    final logPath = '$dir/$id.log';
    unawaited(_checkStaleOldFormatJobLogs(dir));
    // Issue #919: the ceiling and its warning channel ride the options so
    // every BackgroundShell (local, sandboxed, WASI) enforces the same
    // policy through the shared seam. Issue #1408 AC2: the at-rest
    // redactor rides the same seam, wrapped in the line-buffered
    // [JobLogRedactor] so a secret split across stream chunks still masks.
    // The hoisted local is what makes the null-check promote (public
    // fields never do).
    final sessionRedactor = jobLogRedactor;
    final redactor = options?.jobLogRedactor ??
        (sessionRedactor == null ? null : JobLogRedactor(sessionRedactor));
    final mergedOptions = ShellExecOptions(
      cwd: options?.cwd,
      env: options?.env,
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
      stdinData: options?.stdinData,
      liveStdin: options?.liveStdin,
      // Caller-supplied values win — the registry fields are session
      // defaults, not a black hole for per-call overrides (issue #919).
      jobLogMaxBytes: options?.jobLogMaxBytes ?? jobLogMaxBytes,
      onJobLogWarning: options?.onJobLogWarning ?? onJobLogWarning,
      jobLogRedactor: redactor,
    );
    final started = await bg.startShellJob(
      command,
      id: id,
      logPath: logPath,
      options: mergedOptions,
    );
    if (started.isErr) {
      throw StateError(started.errorOrNull!.message);
    }
    final entry = ShellJobEntry._(started.valueOrNull!, cwd: options?.cwd);
    _jobs.add(entry);
    unawaited(
      entry.settled.then((_) async {
        // An inline consumer (foreground bash that awaited this same settle)
        // resumes on the same microtask train AFTER this listener was
        // registered — give it one event-loop turn to clear the model
        // notice. The bookkeeping callback fires regardless: gating it on
        // the flag left settled jobs counted as running forever on the
        // board (issue #562).
        await Future<void>.delayed(Duration.zero);
        entry._settledAt ??= DateTime.now();
        _gcExitedJobs();
        onSettled?.call(entry);
      }),
    );
    onStart?.call(entry);
    return entry;
  }

  /// Prunes exited entries beyond [maxRetainedExitedJobs], oldest settle
  /// first, tombstoning each prune's log path (gh-1438 second tier). Runs
  /// on every settle; running jobs are never pruned.
  void _gcExitedJobs() {
    final exited = <ShellJobEntry>[
      for (final entry in _jobs)
        if (!entry.isRunning) entry,
    ];
    final overflow = exited.length - maxRetainedExitedJobs;
    if (overflow <= 0) return;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    // Oldest settle first; equal stamps fall back to start order
    // (List.sort is not stable, and rapid test loops do collide).
    final order = List<int>.generate(exited.length, (i) => i);
    order.sort((a, b) {
      final bySettled = (exited[a].settledAt ?? epoch).compareTo(
        exited[b].settledAt ?? epoch,
      );
      return bySettled != 0 ? bySettled : a.compareTo(b);
    });
    final pruneIds = {for (var i = 0; i < overflow; i++) exited[order[i]].id};
    _jobs.removeWhere((entry) => pruneIds.contains(entry.id));
    for (final entry in exited) {
      if (pruneIds.contains(entry.id)) _prunedLogPaths[entry.id] = entry.logPath;
    }
  }

  /// Reads the last [maxLines] lines of any job log path on disk — the
  /// post-GC exact-id fallback (gh-1438 AC4). Returns null when the file
  /// cannot be read (gone, deleted by retention sweeps).
  Future<String?> tailFromLog(String path, {int maxLines = 50}) async {
    final content = await env.readTextFile(path);
    if (content.isErr) return null;
    return _tailOfContent(content.valueOrNull!, maxLines);
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
    return _tailOfContent(content.valueOrNull!, maxLines);
  }

  /// Classifies [id] against the registry (gh-1438): an exact hit, a
  /// unique `sh-<n>-` near-miss resolved to its retained job (read-only —
  /// destructive actions never consume this), an ambiguous shared-`n`
  /// match, or unknown with the closest retained ids. Resolution never
  /// reads the disk — the post-GC log fallback is the caller's step.
  ShellJobLookup lookup(String id) {
    final exact = job(id);
    if (exact != null) return ShellJobHit(id, exact);
    final match = matchShellJobId(id, [for (final entry in _jobs) entry.id]);
    return switch (match) {
      ShellJobIdUnique(id: final resolved) => ShellJobNearMiss(
        id,
        job(resolved)!,
      ),
      ShellJobIdAmbiguous(ids: final resolved) => ShellJobPrefixAmbiguous(id, [
        for (final matched in resolved) job(matched)!,
      ]),
      ShellJobIdNoMatch(closest: final closest) => ShellJobUnknownId(
        id,
        closest,
      ),
    };
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

/// The outcome of classifying a `bash_job` id against a
/// [ShellJobRegistry] (gh-1438). The tool layer renders these; the
/// registry stays message-free.
sealed class ShellJobLookup {
  ShellJobLookup(this.id);

  /// The id exactly as requested (the corrected id rides the resolution).
  final String id;
}

/// Exact match among retained jobs.
final class ShellJobHit extends ShellJobLookup {
  ShellJobHit(super.id, this.entry);

  final ShellJobEntry entry;
}

/// A stale near-miss: exactly one retained job shares the requested
/// `sh-<n>-` numeric part (AC1). Read-only resolution — `output`/`status`
/// act on it, `stop` never does (AC5).
final class ShellJobNearMiss extends ShellJobLookup {
  ShellJobNearMiss(super.id, this.entry);

  final ShellJobEntry entry;
}

/// Two or more retained jobs share the `sh-<n>-` numeric part (edge case
/// E1) — no silent pick; the caller lists the candidates.
final class ShellJobPrefixAmbiguous extends ShellJobLookup {
  ShellJobPrefixAmbiguous(super.id, this.entries);

  final List<ShellJobEntry> entries;
}

/// Unresolvable (AC2). [closestIds] is empty for malformed ids (edge case
/// E3 — resolution skipped, the caller renders the shortest error) and
/// otherwise lists up to 3 nearest retained ids.
final class ShellJobUnknownId extends ShellJobLookup {
  ShellJobUnknownId(super.id, this.closestIds);

  final List<String> closestIds;
}

/// Tail-caps [content] to its last [maxLines] lines (a trailing newline is
/// the line terminator, not an extra empty line).
String _tailOfContent(String content, int maxLines) {
  final lines = content.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  final start = lines.length > maxLines ? lines.length - maxLines : 0;
  return lines.sublist(start).join('\n').trimRight();
}

/// Boot sweep (issue #517): reap the process groups of previous-run jobs —
/// entries whose leader pid is dead but whose group members (the toolchain
/// grandchildren: dartvm, flutter_tester) survived for hours. Only jobs
/// that ran as their own group leader (posix `setsid`) can be recognized —
/// a live group keyed by a DEAD pid can only be a leftover job group, never
/// this process's own. Best-effort: any shell/platform failure yields a
/// zero sweep, and [onWarn] fires at most once. Returns the counts.
Future<({int groups, int processes})> reapOrphanJobGroups({
  required ExecutionEnv env,
  required Iterable<int> candidatePids,
  void Function(String message)? onWarn,
  @visibleForTesting Future<String?> Function()? groupTableOverride,
}) async {
  const zero = (groups: 0, processes: 0);
  final pids = candidatePids.where((pid) => pid > 1).toSet();
  if (pids.isEmpty) return zero;
  // The process-table read is infrastructure evidence, never an agent
  // command: it bypasses [Shell.exec] (and its decorations) so no
  // phantom `ps` surfaces in the recorded command stream (CI run
  // 35213198081). The `kill` below stays a real shell action.
  final listed = await (groupTableOverride ?? processGroupTableSnapshot)();
  if (listed == null) return zero;
  final livePids = <int>{};
  final groupOf = <int, int>{};
  for (final line in listed.split('\n')) {
    final cols = line.trim().split(RegExp(r'\s+'));
    if (cols.length < 2) continue;
    final pid = int.tryParse(cols[0]);
    final pgid = int.tryParse(cols[1]);
    if (pid != null && pgid != null) {
      livePids.add(pid);
      groupOf[pid] = pgid;
    }
  }
  var groups = 0;
  var processes = 0;
  for (final pid in pids) {
    // A live leader is a still-running job (or a recycled pid) — never
    // ours to reap.
    if (livePids.contains(pid)) continue;
    final members = [
      for (final entry in groupOf.entries)
        if (entry.value == pid) entry.key,
    ];
    if (members.isEmpty) continue;
    final killed = await env.exec('kill -9 ${members.join(' ')}');
    if (killed.isErr) continue;
    groups++;
    processes += members.length;
  }
  if (groups > 0) {
    onWarn?.call(
      'reaped $groups orphaned job process group(s) '
      '($processes processes) from previous-run jobs',
    );
  }
  return (groups: groups, processes: processes);
}
