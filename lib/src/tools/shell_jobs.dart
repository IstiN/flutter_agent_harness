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

/// How many leading characters of a job's command the model-facing
/// surfaces keep (gh-1604 item 1): the bench evidence showed multi-KB
/// single-line commands riding every registry card and settle notice.
const shellJobLabelHeadChars = 120;

/// How many trailing characters of a job's command the model-facing
/// surfaces keep (gh-1604 item 1) — the tail names the actual action of a
/// long pipeline (`... ; make test`), which a head-only cut loses.
const shellJobLabelTailChars = 120;

/// The bounded model-facing command label (gh-1604 item 1): whitespace
/// (newlines included) flattened to single spaces, then bounded —
/// single-line commands keep the first [headChars] and last [tailChars]
/// characters joined by a `[…N chars…]` marker that names the TRUE
/// omitted size; multi-line commands keep the HEAD only, no tail.
/// Commands that already fit pass through untouched. Cuts never split a
/// UTF-16 surrogate pair. Pure.
///
/// Why multi-line commands keep only the first line (issue #599 RED
/// contract): the heredoc body is never a transcript row source, and for
/// a multi-line command both the flattened head-crossing and the tail
/// chars are body lines more often than they are the action — echoing
/// them back through every settle notice re-floods the transcript the
/// #599 fix drained. A one-line command's tail is the bench pipeline's
/// action (`… ; make test`), so the single-line class keeps it.
String shellJobCommandLabel(
  String command, {
  int headChars = shellJobLabelHeadChars,
  int tailChars = shellJobLabelTailChars,
}) {
  final flat = command.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Fits: any command whose flattened form fits the head bound passes
  // through untouched — including short multi-line ones (pre-existing
  // flatten-and-show behavior).
  if (flat.length <= headChars) return flat;
  if (!command.trim().contains('\n')) {
    final head = _codepointSafeSlice(flat, 0, headChars);
    final tail = _codepointSafeSlice(
      flat,
      max(0, flat.length - tailChars),
      flat.length,
    );
    final omitted = flat.length - head.length - tail.length;
    if (omitted <= 0) return flat;
    return '$head […$omitted chars…] $tail';
  }
  // Overflows: single-line commands keep head + tail; multi-line
  // commands (issue #599 RED contract) keep the FIRST LINE only,
  // bounded — the first line is the command's face (a heredoc opener,
  // a script's shebang), while everything after it is body more often
  // than it is action. A flattened 120-char head would leak the first
  // body lines; a first-line head cannot. The first line comes from the
  // TRIMMED command: a leading newline must not blank the face
  // (gh-1604 rework).
  final trimmed = command.trim();
  final firstLineEnd = trimmed.indexOf('\n');
  final firstLine =
      (firstLineEnd < 0 ? trimmed : trimmed.substring(0, firstLineEnd))
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
  final head = _codepointSafeSlice(firstLine, 0, headChars);
  final omitted = flat.length - head.length;
  return '$head […$omitted chars…]';
}

/// The substring of [text] over `[start, end)`, nudged inward so a cut
/// never separates a surrogate pair (the spill previews' rule).
String _codepointSafeSlice(String text, int start, int end) {
  var s = start.clamp(0, text.length);
  var e = end.clamp(s, text.length);
  if (s > 0 &&
      s < text.length &&
      text.codeUnitAt(s) >= 0xDC00 &&
      text.codeUnitAt(s) <= 0xDFFF) {
    s++;
  }
  if (e > s && e < text.length) {
    final unit = text.codeUnitAt(e - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) e--;
  }
  if (e <= s) return '';
  return text.substring(s, e);
}

/// The model-facing settle notice for [job] — the text the host steers
/// into the conversation (mid-run) or runs as a fresh turn (idle) when a
/// background shell job exits. The command rides the bounded
/// [shellJobCommandLabel], never the full body (gh-1604: a multi-KB
/// command must not enter the transcript through every settle).
///
/// gh-1835 review (threads 2/7 related note): a job killed by its timeout
/// cap exits with the SIGKILL code (-9) — without naming the stop reason
/// the model misreads its own carried cap firing as a crash. The timeout
/// line rides the notice exactly when the job's `stopReason` is
/// `'timeout'`, with the same retry guidance the bash tool description
/// gives for converted calls.
String shellJobSettleNoticeText(ShellJobEntry job) {
  final capSeconds = job.timeout?.inSeconds;
  final timeoutLine = job.stopReason == 'timeout'
      ? 'Stop reason: timeout — the job\'s timeout cap '
            '${capSeconds == null || capSeconds <= 0 ? '' : 'of ${capSeconds}s '}'
            'fired; this is the cap the command was started with, not a '
            'crash. Retry the command yourself if you still need the '
            'result.\n'
      : '';
  return '<system-notice>\n'
      'Background shell job ${job.id} finished with exit code '
      '${job.exitCode}.\n'
      '$timeoutLine'
      // Issue #599: the preview, never the multi-line body — this
      // notice is echoed into the transcript verbatim, and the full
      // command lives in the job log (right below).
      'Command: ${shellJobCommandLabel(job.command)}\n'
      'Log: ${job.logPath}\n'
      'Check the result with bash_job (action: output) or by reading the '
      'log file, and act on it when the result was awaited.\n'
      '</system-notice>';
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
  ShellJobEntry._(
    this.job, {
    this.cwd,
    this.timeout,
    bool adopted = false,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now(),
       isAdopted = adopted;

  /// The backend handle.
  final ShellJob job;

  /// Whether this entry was ADOPTED (issue #2201) instead of spawned by
  /// the registry: a detached survivor of a foreground call, or a
  /// previous-run manifest entry re-adopted at boot. Liveness-only —
  /// surfaces show no exit code and no captured log for it.
  final bool isAdopted;

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

  /// How often the model probed this job with a read-only `bash_job`
  /// status/output call (gh-1459 ask #4). A generation COUNTER, not a
  /// timestamp — the headless drain's liveness leg compares generations
  /// so the probe clock stays valid under a fake [DateTime] test clock:
  /// a quiet-threshold steer is skipped when the generation advanced
  /// since the last consumed threshold (the model looked itself, so the
  /// notice would be noise).
  int _probeGeneration = 0;

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

  /// The exec timeout the job was started with (gh-1444 AC5): the honest
  /// "timed out after Ns" text reports THIS cap when the job's own
  /// `stopReason` is 'timeout', instead of "unknown seconds" — the model's
  /// `timeout` argument is absent on exactly the runs where a shell default
  /// fired. Null when the job was started without a cap.
  final Duration? timeout;

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

  /// The current probe generation (gh-1459 ask #4) — see [_probeGeneration].
  int get probeGeneration => _probeGeneration;

  /// The model's read-only `bash_job` status/output call on THIS job
  /// (gh-1459 ask #4): bumps the probe generation so a drain liveness
  /// steer for a threshold the model already inspected itself is skipped.
  void markProbed() => _probeGeneration++;
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
  ///
  /// The settle continuation is bound to the zone this registry was
  /// CONSTRUCTED in (host boot), never to the zone of the `bash` call that
  /// happened to start the job (gh-1947): a job started by a subagent used
  /// to carry its `onSettled` into the child's subagent zone, so a job
  /// settling after the child's run ended fired the host's settle path —
  /// including the idle settle-wake that starts a fresh MAIN run — with
  /// `activeSubagentId()` still naming the long-finished child. Every
  /// identity consumer of that run (schedule_message's self-mailbox
  /// resolution among them) then attributed MAIN's work to the child.
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
    this.adoptedLivenessNoticeMinutes = 0,
    this.onAdopt,
    this.onAdoptedLiveness,
    @visibleForTesting this.livenessTableOverride,
    @visibleForTesting this.stopAdoptedOverride,
    DateTime? bootTime,
  }) : _bootTime = bootTime ?? DateTime.now(),
       _bootZone = Zone.current;

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

  /// The zone the host constructed this registry in (host boot). Settle
  /// continuations run there — see the constructor doc (gh-1947).
  final Zone _bootZone;

  /// Minutes between model-facing liveness reminders for still-running
  /// ADOPTED jobs (`jobs.adopted.livenessNoticeMinutes`, issue #2201
  /// AC4); `0` — the default — fires none (completion-only notify).
  final int adoptedLivenessNoticeMinutes;

  /// Fires ONCE per adoption batch (issue #2201): the host turns it into
  /// the model-facing adoption notice. Adoptions a tool reports inline
  /// (the bash result text) pass `notify: false` and skip this.
  final void Function(List<ShellJobEntry> adopted, {required String source})?
  onAdopt;

  /// Cadence reminder for a still-running adopted job (issue #2201 AC4);
  /// default cadence 0 = never fires.
  final void Function(ShellJobEntry job, Duration elapsed)? onAdoptedLiveness;

  /// Test seam: the adoption poll's process table. Null restores the
  /// real `ps` probe.
  @visibleForTesting
  final Future<ShellLivenessTable?> Function()? livenessTableOverride;

  /// Test seam: the adopted-job kill round. Null restores the real
  /// TERM/KILL pair.
  @visibleForTesting
  final Future<bool> Function(int pid)? stopAdoptedOverride;

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
    final redactor =
        options?.jobLogRedactor ??
        (sessionRedactor == null ? null : JobLogRedactor(sessionRedactor));
    final mergedOptions = ShellExecOptions(
      cwd: options?.cwd,
      env: options?.env,
      timeout: options?.timeout,
      // gh-1455: caller cancel tokens NEVER reach job space. A job outlives
      // the call that started it (`background: true` returns immediately;
      // a foreground-as-job bash hands the process to the registry on a
      // yield), so forwarding the run's token let an aborted run tear down
      // every live job — and a `bash_job stop` issued from inside the dying
      // batch then cancelled the whole run on top. Jobs are stopped through
      // [ShellJobEntry.stop] only.
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
    final entry = ShellJobEntry._(
      started.valueOrNull!,
      cwd: options?.cwd,
      timeout: options?.timeout,
    );
    _jobs.add(entry);
    // Registered inside [_bootZone], so the settle callback — and the
    // host's [onSettled] bookkeeping and settle-wake with it — runs in the
    // boot zone regardless of which agent's `bash` call started the job
    // (gh-1947: a child-started job used to drag its settle, and the
    // MAIN reaction run it could start, into the finished child's
    // subagent zone).
    _listenSettle(entry);
    onStart?.call(entry);
    return entry;
  }

  /// The settle continuation shared by started and adopted jobs: stamp
  /// the settle, GC, fire the host callback, then adopt any survivors
  /// the environment observed at this job's normal exit (issue #2201).
  void _listenSettle(ShellJobEntry entry) {
    unawaited(
      _bootZone.run(
        () => entry.settled.then((_) async {
          // An inline consumer (foreground bash that awaited this same
          // settle) resumes on the same microtask train AFTER this listener
          // was registered — give it one event-loop turn to clear the model
          // notice. The bookkeeping callback fires regardless: gating it on
          // the flag left settled jobs counted as running forever on the
          // board (issue #562).
          await Future<void>.delayed(Duration.zero);
          entry._settledAt ??= DateTime.now();
          _gcExitedJobs();
          onSettled?.call(entry);
          // Issue #2201: a local job's NORMAL exit may leave live children
          // (`nohup x &` inside a background:true script settles the job,
          // not the work). The env buffered them at exit
          // ([SurvivorReporting]); stopped/timed-out jobs report none —
          // gh-1053 reaped those trees. Adoption is best-effort
          // observation and must never break the settle path.
          if (entry.job case SurvivorReporting reporting) {
            final survivors = reporting.takeSurvivors();
            if (survivors.isNotEmpty) {
              try {
                await adoptSurvivors(entry.command, survivors);
              } on Object {
                // Observation only — the job's own settle stands.
              }
            }
          }
        }),
      ),
    );
  }

  /// Adopts [survivors] — live processes a completed foreground call left
  /// behind (issue #2201) — as liveness-only registry entries. Returns the
  /// new entries; [notify] false skips [onAdopt] (the detecting tool
  /// reports the adoption inline in its result instead).
  Future<List<ShellJobEntry>> adoptSurvivors(
    String sourceCommand,
    List<ShellSurvivor> survivors, {
    bool notify = true,
  }) async {
    final adopted = <ShellJobEntry>[];
    for (final survivor in survivors) {
      // Never double-track: a pid one of this session's running jobs
      // already holds is accounted for.
      if (_jobs.any((e) => e.isRunning && e.pid == survivor.pid)) continue;
      adopted.add(
        _adopt(
          id: newShellJobId(_nextId++),
          command: survivor.command ?? '<unknown cmd>',
          pid: survivor.pid,
          pidStart: survivor.startTag,
        ),
      );
    }
    if (adopted.isNotEmpty && notify) {
      onAdopt?.call(adopted, source: sourceCommand);
    }
    return adopted;
  }

  /// Boot re-adoption (issue #2201 AC5): a manifest entry whose pid is
  /// alive at boot becomes a real registry job instead of an invisible
  /// ghost. The manifest id is KEPT — board resume matching and
  /// `bash_job` id resolution keep working.
  ShellJobEntry adoptRunningEntry({
    required String id,
    required String command,
    required int pid,
    String? pidStart,
    int? startedAtMs,
  }) => _adopt(
    id: id,
    command: command,
    pid: pid,
    pidStart: pidStart,
    startedAt: startedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(startedAtMs),
  );

  ShellJobEntry _adopt({
    required String id,
    required String command,
    required int pid,
    String? pidStart,
    DateTime? startedAt,
  }) {
    final entry = ShellJobEntry._(
      _AdoptedShellJob(
        id: id,
        command: command,
        pid: pid,
        startTag: pidStart ?? '',
        stopProcess: stopAdoptedOverride ?? stopDetachedProcess,
      ),
      adopted: true,
      startedAt: startedAt,
    );
    _jobs.add(entry);
    _listenSettle(entry);
    onStart?.call(entry);
    _ensureAdoptedPoll();
    return entry;
  }

  /// Cadence between adoption liveness samples: cheap (one `ps` per tick
  /// only while an adopted job runs) and fast enough that a completion
  /// notice lands well inside any human-relevant window.
  static const adoptedLivenessPollInterval = Duration(seconds: 5);

  Timer? _adoptedPoll;
  final _adoptedLastNotice = <String, DateTime>{};

  bool get _hasRunningAdopted => _jobs.any((e) => e.isAdopted && e.isRunning);

  void _ensureAdoptedPoll() {
    if (_adoptedPoll != null || !_hasRunningAdopted) return;
    _scheduleAdoptedPoll();
  }

  void _scheduleAdoptedPoll() {
    _adoptedPoll?.cancel();
    _adoptedPoll = Timer(adoptedLivenessPollInterval, () {
      _adoptedPoll = null;
      unawaited(_pollAdopted());
    });
  }

  /// One adoption liveness round (issue #2201 AC3/AC4): refresh every
  /// running adopted job against the process table (a death completes its
  /// [ShellJob.settled] → the normal settle path notifies the model),
  /// fire cadence reminders when configured, and re-arm only while an
  /// adopted job still runs. The whole round is best-effort observation.
  Future<void> _pollAdopted() async {
    try {
      final now = DateTime.now();
      final table =
          await (livenessTableOverride?.call() ?? _probeLivenessTable());
      for (final entry in [
        for (final e in _jobs)
          if (e.isAdopted && e.isRunning) e,
      ]) {
        (entry.job as _AdoptedShellJob).refresh(table);
      }
      if (adoptedLivenessNoticeMinutes > 0 && onAdoptedLiveness != null) {
        for (final entry in [
          for (final e in _jobs)
            if (e.isAdopted && e.isRunning) e,
        ]) {
          final last = _adoptedLastNotice[entry.id];
          if (!adoptedLivenessDue(
            now: now,
            startedAt: entry.startedAt,
            lastNoticeAt: last,
            noticeMinutes: adoptedLivenessNoticeMinutes,
          )) {
            continue;
          }
          _adoptedLastNotice[entry.id] = now;
          onAdoptedLiveness!(entry, now.difference(entry.startedAt));
        }
      }
    } on Object {
      // The poll is observation, never a crash source.
    }
    if (_hasRunningAdopted) {
      _scheduleAdoptedPoll();
    } else {
      _adoptedLastNotice.clear();
    }
  }

  /// The poll's process table from the real `ps` probe; null when the
  /// platform cannot report one (adopted jobs then simply stay running —
  /// unverifiable evidence never destroys an entry, the #478 rule).
  Future<ShellLivenessTable?> _probeLivenessTable() async {
    final rows = await processDetailTableSnapshot();
    if (rows == null) return null;
    return (
      pids: {for (final r in rows) r.pid},
      starts: {for (final r in rows) r.pid: r.lstart},
    );
  }

  /// Test seam: fires one adoption liveness round now (the analog of
  /// [adoptedLivenessDue]-driven ticks) instead of waiting out the
  /// [adoptedLivenessPollInterval] timer.
  @visibleForTesting
  Future<void> adoptedPollTickForTest() => _pollAdopted();

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
      if (pruneIds.contains(entry.id)) {
        _prunedLogPaths[entry.id] = entry.logPath;
      }
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
  final (:livePids, :groupOf) = _parseProcessGroupTable(listed);
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

/// Parses a `pid pgid` process-table snapshot (whitespace-separated
/// columns, one process per line; malformed lines are skipped) into the
/// live pid set and each live pid's process group.
({Set<int> livePids, Map<int, int> groupOf}) _parseProcessGroupTable(
  String listed,
) {
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
  return (livePids: livePids, groupOf: groupOf);
}

/// One adoption-poll liveness sample (issue #2201): the live pid set plus
/// each pid's OS start string — the pid-reuse guard (#478) for foreign
/// processes we hold no handle on.
typedef ShellLivenessTable = ({Set<int> pids, Map<int, String> starts});

/// Whether an adopted job's cadence reminder is due (issue #2201 AC4):
/// [noticeMinutes] must be armed and [startedAt] — or the last fired
/// notice — this many minutes in the past. Pure — unit-tested directly.
bool adoptedLivenessDue({
  required DateTime now,
  required DateTime startedAt,
  DateTime? lastNoticeAt,
  required int noticeMinutes,
}) {
  if (noticeMinutes <= 0) return false;
  final base = lastNoticeAt ?? startedAt;
  return !now.isBefore(base.add(Duration(minutes: noticeMinutes)));
}

/// A liveness-only registry job over a process the harness did NOT spawn
/// (issue #2201 adoption): no pipe, no waitpid — no exit code, no output
/// capture. Death is observed by the registry's poll (pid presence plus
/// the #478 start-tag match) and completes [settled] exactly like a
/// natural job exit, so the whole downstream notify machinery applies
/// unchanged.
final class _AdoptedShellJob implements ShellJob {
  _AdoptedShellJob({
    required this.id,
    required this.command,
    required this.pid,
    required this._startTag,
    required this._stopProcess,
  });

  @override
  final String id;

  @override
  final String command;

  @override
  final int pid;

  /// The #478 start string at adoption time; '' when the platform could
  /// not report one (presence-only liveness, same degrade as reconcile).
  final String _startTag;
  final Future<bool> Function(int pid) _stopProcess;

  bool _running = true;
  String? _stopReason;
  final _settled = Completer<void>();
  final _output = StreamController<String>.broadcast();

  @override
  String get logPath => '';

  @override
  bool get isRunning => _running;

  @override
  int? get exitCode => null;

  @override
  String? get stopReason => _stopReason;

  @override
  Future<void> get settled => _settled.future;

  @override
  Stream<String> get output => _output.stream;

  @override
  bool writeStdin(String data) => false;

  /// One liveness sample. A null [table] (probe unavailable) changes
  /// nothing — unverifiable evidence never destroys an entry (#478 rule).
  /// A pid MISSING from a delivered table is dead; a pid present with a
  /// DIFFERENT start string was recycled onto another process — equally
  /// gone. Liveness-only, so there is no exit code to record.
  void refresh(ShellLivenessTable? table) {
    if (!_running || table == null) return;
    if (!table.pids.contains(pid)) return _markGone();
    final actual = table.starts[pid];
    if (actual == null) return; // presence-only platform: stays running
    if (actual == _startTag || _startTag.isEmpty) return; // same process
    _markGone();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _stopReason ??= 'stopped';
    try {
      await _stopProcess(pid);
    } on Object {
      // Best-effort — the settle below reflects the stop intent either way.
    }
    if (_running) _markGone();
  }

  void _markGone() {
    _running = false;
    _output.close();
    _settled.complete();
  }
}

/// The tag-free adoption notice body (issue #2201): ONE per detecting
/// call (the many-survivors border case), naming every survivor with its
/// pid and the honest liveness-only caveat. The bash tool appends it to
/// the inline result; the host wraps it in a system-notice for the
/// job-path steer.
String adoptedSurvivorsNoticeText(
  List<ShellJobEntry> adopted, {
  required String source,
}) {
  final lines = StringBuffer(
    'Detected ${adopted.length} surviving background process'
    '${adopted.length == 1 ? '' : 'es'} left by '
    '`${shellJobCommandLabel(source)}` — adopted as tracked jobs; their '
    'completion will be reported:\n',
  );
  for (final job in adopted) {
    lines.write(
      '- ${job.id} (pid ${job.pid}, '
      '`${shellJobCommandLabel(job.command)}`)\n',
    );
  }
  lines.write(
    'Liveness-only: no captured output and no exit code (not our child); '
    'their output stays in their own redirects (e.g. nohup.out). Stop one '
    'with bash_job (action: stop) if unwanted.',
  );
  return lines.toString();
}

/// The model-facing settle notice for an ADOPTED job (issue #2201 AC3):
/// liveness-only honesty — no exit code, no harness log — plus the
/// pointer at the launcher's own redirect.
String adoptedJobSettleNoticeText(ShellJobEntry job) =>
    '<system-notice>\n'
    'Adopted background process ${job.id} (pid ${job.pid}, '
    '`${shellJobCommandLabel(job.command)}`) is no longer running '
    '(liveness poll; no exit code — it was not our child).\n'
    'Its output went to whatever redirect its launcher used (e.g. '
    'nohup.out), not a harness log. If you still need its result, check '
    'that redirect, or re-run the work with background: true to capture '
    'it.\n'
    '</system-notice>';

/// The AC4 cadence reminder for a still-running adopted job (default
/// cadence 0 = never). Tag-free — the host wraps it as a system-notice.
String adoptedLivenessNoticeText(ShellJobEntry job, Duration elapsed) =>
    'Adopted background process ${job.id} (pid ${job.pid}, '
    '`${shellJobCommandLabel(job.command)}`) still running after '
    '${elapsed.inMinutes} min. No action needed — you will be notified '
    'when it exits.';

/// The `bash_job output` answer for an adopted job (issue #2201 AC3):
/// the adopted-explanation, never an empty-log reading.
String adoptedJobOutputText(ShellJobEntry entry) =>
    '${entry.id} is an ADOPTED background process — the harness did not '
    'spawn it, so there is no captured output or log. Its output goes to '
    'whatever redirect its launcher used (e.g. nohup.out). '
    '${entry.isRunning ? 'Still running (pid ${entry.pid}).' : 'No longer running — no exit code is available (not our child).'}';
