/// The background-subagent heartbeat (issue #383): while a background
/// subagent runs, the parent receives ONE compact status digest per
/// `subagents.heartbeatMinutes` through the existing steering channel —
/// per running child: age, provider requests/tokens, last activity, and a
/// `healthy | stalled | no-progress-since-spawn` classification. A child
/// that never issued a provider request, or went quiet for
/// `subagents.stallMinutes`, gets a loud `[WARN] STALLED` line (escalating to
/// `[WARN][WARN]` at twice the threshold) carrying the suggested
/// `task_status → task_cancel → respawn` action. Zero running children →
/// no digest; `heartbeatMinutes: 0` disables the whole thing.
///
/// The host (CLI) wires [notify] into the same steer/wake path as
/// completion notices; the class itself is transport-free.
library;

import '../exceptions.dart';
import 'dart:async';

import 'subagent.dart';
import 'subagent_manager.dart';

/// Default digest cadence: one digest every 10 minutes
/// (`subagents.heartbeatMinutes`; `0` = kill switch).
const defaultSubagentHeartbeatMinutes = 10;

/// Default stall threshold: 20 minutes without provider activity
/// (`subagents.stallMinutes`; `0` = stall flagging off).
const defaultSubagentStallMinutes = 20;

/// The `subagents:` yaml section: heartbeat cadence and stall threshold.
/// Parsed strictly — a bad schema throws [ConfigException]-shaped errors
/// (the config layer surfaces them at boot). `0` disables the respective
/// mechanism; negative values are rejected.
final class SubagentsConfig {
  const SubagentsConfig({
    this.heartbeatMinutes = defaultSubagentHeartbeatMinutes,
    this.stallMinutes = defaultSubagentStallMinutes,
  });

  /// Digest cadence in minutes; `0` disables the heartbeat entirely.
  final int heartbeatMinutes;

  /// Minutes without provider activity before a running child is flagged
  /// `[WARN] STALLED`; `0` disables stall flagging.
  final int stallMinutes;

  factory SubagentsConfig.fromYaml(Object? node) {
    if (node == null) return const SubagentsConfig();
    if (node is! Map) {
      throw ConfigException('subagents must be a map, got: $node');
    }
    int parse(String key, int fallback) {
      final value = node[key];
      if (value == null) return fallback;
      if (value is! int) {
        throw ConfigException('"subagents.$key" must be an integer');
      }
      if (value < 0) {
        throw ConfigException('"subagents.$key" must be >= 0 (0 disables)');
      }
      return value;
    }

    for (final key in node.keys) {
      if (!{'heartbeatMinutes', 'stallMinutes'}.contains('$key')) {
        throw ConfigException('unknown "subagents" key: $key');
      }
    }
    return SubagentsConfig(
      heartbeatMinutes: parse(
        'heartbeatMinutes',
        defaultSubagentHeartbeatMinutes,
      ),
      stallMinutes: parse('stallMinutes', defaultSubagentStallMinutes),
    );
  }

  String toYaml() =>
      'subagents:\n'
      '  heartbeatMinutes: $heartbeatMinutes\n'
      '  stallMinutes: $stallMinutes\n';
}

/// Periodic status digests for running background subagents.
///
/// The constructor takes FUNCTION getters for both thresholds so a config
/// change applies at the next tick without a restart (E6), and an
/// injectable clock so tests drive ages deterministically (E5: every
/// window is computed from the child's timestamps, never a wall timer).
final class SubagentHeartbeat {
  SubagentHeartbeat({
    required this.manager,
    required this.notify,
    int Function()? heartbeatMinutes,
    int Function()? stallMinutes,
    DateTime Function()? now,
  }) : _heartbeatMinutes =
           heartbeatMinutes ?? (() => defaultSubagentHeartbeatMinutes),
       _stallMinutes = stallMinutes ?? (() => defaultSubagentStallMinutes),
       _now = now ?? (() => DateTime.now().toUtc());

  /// The retained-subagent registry the digests observe.
  final SubagentManager manager;

  /// The delivery sink: the host steers the digest into the parent
  /// (busy → step boundary, idle → wake) exactly like completion notices.
  final void Function(String digest) notify;

  final int Function() _heartbeatMinutes;
  final int Function() _stallMinutes;
  final DateTime Function() _now;

  Timer? _timer;

  /// Arms the cadence. The kill switch (`heartbeatMinutes <= 0`) arms
  /// nothing — no timer, no digests.
  void start() {
    if (_timer != null) return;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final minutes = _heartbeatMinutes();
    if (minutes <= 0) {
      _timer = null;
      return;
    }
    _timer = Timer(Duration(minutes: minutes), () {
      _timer = null;
      tick();
      _schedule();
    });
  }

  /// Disarms the cadence.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fires one digest and returns it — the timer's body and the tests'
  /// manual trigger. The threshold getters are consulted EVERY call
  /// (E6); the kill switch suppresses the digest entirely. Returns null
  /// when nothing is to report.
  String? tick() {
    if (_heartbeatMinutes() <= 0) return null;
    final digest = buildDigest();
    if (digest == null) return null;
    notify(digest);
    return digest;
  }

  /// The merged digest for every RUNNING child, or null when none is
  /// running. A child that settled before the tick never appears (E1/E3:
  /// the completion notice is the only word — no zombie-ghost line).
  String? buildDigest() {
    final now = _now();
    final stall = _stallMinutes();
    final lines = <String>[];
    for (final handle in manager.handles) {
      if (handle.status != SubagentStatus.running) continue;
      lines.add(_lineOf(handle, now, stall));
    }
    if (lines.isEmpty) return null;
    return '<system-notice>\n'
        'Subagent heartbeat — ${lines.length} running:\n'
        '${lines.join('\n')}\n'
        '</system-notice>';
  }

  /// One child's digest line. Stalled means "no provider request ever"
  /// (the dead-on-arrival shape — zero requests is flagged from the first
  /// digest) or "no provider activity for [stall] minutes"; twice the
  /// threshold escalates to `[WARN][WARN]`. `stall <= 0` disables flagging.
  String _lineOf(SubagentHandle handle, DateTime now, int stall) {
    final label = '${handle.id} (${handle.agentType})';
    final requests = handle.requests + handle.liveRequests;
    final tokens = handle.tokens + handle.liveTokens;
    final facts =
        'age ${_minutes(now.difference(_parse(handle.createdAt)))} · '
        '$requests requests · $tokens tokens · '
        'last activity ${_minutes(now.difference(_parse(handle.lastActivity)))} '
        'ago';
    if (stall <= 0) return '$label — $facts · healthy';
    final created = _parse(handle.createdAt);
    final lastActivity = _parse(handle.lastActivity);
    final quietFor = now.difference(lastActivity);
    final noRequestYet = requests == 0;
    if (!noRequestYet && quietFor < Duration(minutes: stall)) {
      return '$label — $facts · healthy';
    }
    final escalated = noRequestYet
        ? now.difference(created) >= Duration(minutes: stall * 2)
        : quietFor >= Duration(minutes: stall * 2);
    final classification = noRequestYet ? 'no-progress-since-spawn' : 'stalled';
    final marker = escalated ? '[WARN][WARN] STALLED' : '[WARN] STALLED';
    return '$marker $label — $facts · $classification · '
        'suggest: task_status → task_cancel → respawn';
  }

  static DateTime _parse(String iso) =>
      DateTime.tryParse(iso)?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0);

  static String _minutes(Duration duration) {
    final minutes = duration.inMinutes;
    return minutes < 0 ? '0m' : '${minutes}m';
  }
}
