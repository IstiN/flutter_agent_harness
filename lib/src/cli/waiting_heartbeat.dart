/// The visible-waiting layer's config and heartbeat (issue #450).
///
/// An observer looking at the terminal must distinguish working /
/// waiting-for-X / idle-done at a glance. While waiters exist (background
/// shell jobs, armed self-wake timers), a ~20-minute heartbeat (`waiting:
/// waitHeartbeatMinutes`, `0` disables) re-pings a status round through the
/// existing steering/self-wake channel; `waitCeilingMinutes` caps how long
/// `--wait-for-jobs` headless runs may stay alive for their waiters.
///
/// The class itself is transport-free; the host (CLI) wires [WaitingHeartbeat.onBeat]
/// into its steer/wake path.
library;

import 'dart:async';

import '../exceptions.dart';
import '../env/job_log_ceiling.dart';
import 'tool_liveness.dart';

/// Default waiting-heartbeat cadence in minutes (`waiting:
/// waitHeartbeatMinutes`; `0` = kill switch).
const defaultWaitHeartbeatMinutes = 20;

/// Default hard ceiling for `--wait-for-jobs` headless runs in minutes
/// (`waiting: waitCeilingMinutes`).
const defaultWaitForJobsCeilingMinutes = 30;

/// The `waiting:` yaml section: waiting-heartbeat cadence, the
/// `--wait-for-jobs` ceiling, and the per-call foreground liveness knobs
/// (gh-1055). Parsed strictly like `subagents:` — a bad schema throws at
/// boot; negative values are rejected.
final class WaitingConfig {
  const WaitingConfig({
    this.waitHeartbeatMinutes = defaultWaitHeartbeatMinutes,
    this.waitCeilingMinutes = defaultWaitForJobsCeilingMinutes,
    this.toolLivenessSeconds = defaultToolLivenessSeconds,
    this.toolLivenessTickSeconds = defaultToolLivenessTickSeconds,
    this.toolEscalateSeconds = defaultToolEscalateSeconds,
  });

  /// Waiting-heartbeat cadence in minutes; `0` disables the heartbeat.
  final int waitHeartbeatMinutes;

  /// How long a `--wait-for-jobs` headless run may stay alive for its
  /// waiters before exiting with the summary line.
  final int waitCeilingMinutes;

  /// Per-call foreground liveness (gh-1055): reminders start once a tool
  /// call runs this many seconds; `0` disables them.
  final int toolLivenessSeconds;

  /// Liveness reminder cadence in seconds; `0` disables the timer chain.
  final int toolLivenessTickSeconds;

  /// The one-time background escape-hatch hint fires once a stuck call
  /// runs this many seconds; `0` disables the hint.
  final int toolEscalateSeconds;

  factory WaitingConfig.fromYaml(Object? node) {
    if (node == null) return const WaitingConfig();
    if (node is! Map) {
      throw ConfigException('waiting must be a map, got: $node');
    }
    int parse(String key, int fallback) {
      final value = node[key];
      if (value == null) return fallback;
      if (value is! int) {
        throw ConfigException('"waiting.$key" must be an integer');
      }
      if (value < 0) {
        throw ConfigException('"waiting.$key" must be >= 0 (0 disables)');
      }
      return value;
    }

    for (final key in node.keys) {
      if (!{
        'waitHeartbeatMinutes',
        'waitCeilingMinutes',
        'toolLivenessSeconds',
        'toolLivenessTickSeconds',
        'toolEscalateSeconds',
      }.contains('$key')) {
        throw ConfigException('unknown "waiting" key: $key');
      }
    }
    final parsed = WaitingConfig(
      waitHeartbeatMinutes: parse(
        'waitHeartbeatMinutes',
        defaultWaitHeartbeatMinutes,
      ),
      waitCeilingMinutes: parse(
        'waitCeilingMinutes',
        defaultWaitForJobsCeilingMinutes,
      ),
      toolLivenessSeconds: parse(
        'toolLivenessSeconds',
        defaultToolLivenessSeconds,
      ),
      toolLivenessTickSeconds: parse(
        'toolLivenessTickSeconds',
        defaultToolLivenessTickSeconds,
      ),
      toolEscalateSeconds: parse(
        'toolEscalateSeconds',
        defaultToolEscalateSeconds,
      ),
    );
    // Ordering (gh-1055 review): the hint fires at a LONGER threshold than
    // the reminders — AC1 starts the reminders at the configured threshold,
    // AC3 escalates past it. A smaller escalation would print the hint as
    // the very first line; rejected at boot like every other bad `waiting:`
    // schema. `0` disables either side and is exempt from the ordering.
    if (parsed.toolLivenessSeconds > 0 &&
        parsed.toolEscalateSeconds > 0 &&
        parsed.toolEscalateSeconds < parsed.toolLivenessSeconds) {
      throw ConfigException(
        '"waiting.toolEscalateSeconds" must be 0 or >= '
        '"waiting.toolLivenessSeconds" (${parsed.toolLivenessSeconds}) — '
        'the background hint fires at a longer threshold than the '
        'liveness reminders',
      );
    }
    return parsed;
  }

  String toYaml() =>
      'waiting:\n'
      '  waitHeartbeatMinutes: $waitHeartbeatMinutes\n'
      '  waitCeilingMinutes: $waitCeilingMinutes\n'
      '  toolLivenessSeconds: $toolLivenessSeconds\n'
      '  toolLivenessTickSeconds: $toolLivenessTickSeconds\n'
      '  toolEscalateSeconds: $toolEscalateSeconds\n';
}

/// Default age belt for cross-run job manifest entries (`jobs:
/// staleHours`): entries older than this are dropped at boot; `0`
/// disables the belt.
const defaultJobsStaleHours = 24;

/// Default retention for `.fah/bash_jobs/*.log` (`jobs:
/// logRetentionDays`): older logs are deleted at boot; `0` keeps every
/// log forever.
const defaultJobsLogRetentionDays = 3;

/// Per-log size ceiling for background jobs (`jobs: maxLogBytes`,
/// issue #919, default 50 MB). Re-exports the policy constant — one source
/// of truth for the config default and the writer default.
const defaultJobsMaxLogBytes = defaultJobLogMaxBytes;

/// The `jobs:` yaml section (issue #478): boot-maintenance knobs for the
/// cross-run shell-job state under `.fah/bash_jobs/`. Parsed strictly
/// like `waiting:` — a bad schema throws at boot; negative values are
/// rejected and `0` always means "disabled".
final class JobsConfig {
  const JobsConfig({
    this.staleHours = defaultJobsStaleHours,
    this.logRetentionDays = defaultJobsLogRetentionDays,
    this.maxLogBytes = defaultJobsMaxLogBytes,
  });

  /// Manifest entries older than this many hours are dropped at boot
  /// (the age belt under the pid-liveness reconcile); `0` disables it.
  final int staleHours;

  /// Job logs older than this many days are deleted at boot; `0` keeps
  /// every log (the 24k-files leak lives here when raised).
  final int logRetentionDays;

  /// Per-log size ceiling in bytes (issue #919): when a background job's
  /// log crosses it, capture switches to head + truncation marker + rolling
  /// tail while the job keeps running. Unlike the other `jobs:` knobs, `0`
  /// is invalid — an unbounded log is exactly the bug being fixed.
  final int maxLogBytes;

  factory JobsConfig.fromYaml(Object? node) {
    if (node == null) return const JobsConfig();
    if (node is! Map) {
      throw ConfigException('jobs must be a map, got: $node');
    }
    int parse(String key, int fallback) {
      final value = node[key];
      if (value == null) return fallback;
      if (value is! int) {
        throw ConfigException('"jobs.$key" must be an integer');
      }
      if (value < 0) {
        throw ConfigException('"jobs.$key" must be >= 0 (0 disables)');
      }
      return value;
    }

    final maxLogBytesValue = node['maxLogBytes'];
    if (maxLogBytesValue != null) {
      if (maxLogBytesValue is! int) {
        throw ConfigException('"jobs.maxLogBytes" must be an integer');
      }
      if (maxLogBytesValue <= 0) {
        throw ConfigException(
          '"jobs.maxLogBytes" must be > 0 (a log '
          'ceiling cannot be disabled — that is the disk-exhaustion bug)',
        );
      }
    }
    for (final key in node.keys) {
      if (!{'staleHours', 'logRetentionDays', 'maxLogBytes'}.contains('$key')) {
        throw ConfigException('unknown "jobs" key: $key');
      }
    }
    return JobsConfig(
      staleHours: parse('staleHours', defaultJobsStaleHours),
      logRetentionDays: parse('logRetentionDays', defaultJobsLogRetentionDays),
      maxLogBytes: maxLogBytesValue as int? ?? defaultJobsMaxLogBytes,
    );
  }

  String toYaml() =>
      'jobs:\n'
      '  staleHours: $staleHours\n'
      '  logRetentionDays: $logRetentionDays\n'
      '  maxLogBytes: $maxLogBytes\n';
}

/// Periodic waiting-heartbeat pings while waiters exist (issue #450).
///
/// One-shot timer chain, not [Timer.periodic]: the cadence getter is read
/// every leg so a config change applies at the next beat, and [reset]
/// (E2: a waiter resolved, another remains) restarts the full period.
/// Transport-free — the host supplies [onBeat].
final class WaitingHeartbeat {
  WaitingHeartbeat({required void Function() onBeat, int Function()? minutes})
    : _onBeat = onBeat,
      _minutes = minutes ?? (() => defaultWaitHeartbeatMinutes);

  final void Function() _onBeat;
  final int Function() _minutes;

  Timer? _timer;
  bool _running = false;

  /// Arms the chain when waiters exist. No-op while already running or
  /// when the cadence is disabled (`0`).
  void start() {
    if (_running || _minutes() <= 0) return;
    _running = true;
    _arm();
  }

  /// E2: a waiter resolved but others remain — restart the full period so
  /// a long-lived wait pings on a stable cadence, not mid-period.
  void reset() {
    if (!_running) return;
    _timer?.cancel();
    _arm();
  }

  /// The last waiter resolved — stop pinging.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Arms when idle, restarts the full period when already running (E2:
  /// a waiter resolved but others remain — the next ping lands a full
  /// cadence from now, not mid-period).
  void pulse() => _running ? reset() : start();

  void _arm() {
    _timer = Timer(Duration(minutes: _minutes()), _beat);
  }

  void _beat() {
    _timer = null;
    if (!_running) return;
    _onBeat();
    // The callback may have stopped us (a resolved wait fires no further
    // ping) — re-arm only when still running.
    if (_running) _arm();
  }

  /// Test seam: fire one beat now (the CLI mirrors this as
  /// `waitingHeartbeatTickForTest`, like `heartbeatTickForTest` for #383).
  void tick() {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _beat();
  }
}
