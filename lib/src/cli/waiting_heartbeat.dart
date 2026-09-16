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

/// Default waiting-heartbeat cadence in minutes (`waiting:
/// waitHeartbeatMinutes`; `0` = kill switch).
const defaultWaitHeartbeatMinutes = 20;

/// Default hard ceiling for `--wait-for-jobs` headless runs in minutes
/// (`waiting: waitCeilingMinutes`).
const defaultWaitForJobsCeilingMinutes = 30;

/// The `waiting:` yaml section: waiting-heartbeat cadence and the
/// `--wait-for-jobs` ceiling. Parsed strictly like `subagents:` — a bad
/// schema throws at boot; negative values are rejected.
final class WaitingConfig {
  const WaitingConfig({
    this.waitHeartbeatMinutes = defaultWaitHeartbeatMinutes,
    this.waitCeilingMinutes = defaultWaitForJobsCeilingMinutes,
  });

  /// Waiting-heartbeat cadence in minutes; `0` disables the heartbeat.
  final int waitHeartbeatMinutes;

  /// How long a `--wait-for-jobs` headless run may stay alive for its
  /// waiters before exiting with the summary line.
  final int waitCeilingMinutes;

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
      if (!{'waitHeartbeatMinutes', 'waitCeilingMinutes'}.contains('$key')) {
        throw ConfigException('unknown "waiting" key: $key');
      }
    }
    return WaitingConfig(
      waitHeartbeatMinutes: parse(
        'waitHeartbeatMinutes',
        defaultWaitHeartbeatMinutes,
      ),
      waitCeilingMinutes: parse(
        'waitCeilingMinutes',
        defaultWaitForJobsCeilingMinutes,
      ),
    );
  }

  String toYaml() =>
      'waiting:\n'
      '  waitHeartbeatMinutes: $waitHeartbeatMinutes\n'
      '  waitCeilingMinutes: $waitCeilingMinutes\n';
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
