/// Stuck-call supervision config (gh-1054): liveness heartbeats and the
/// cancel/retry/convert follow-up for long-stuck tool calls.
///
/// A headless/unattended run used to go completely silent when a tool call
/// hung: no heartbeat, no mid-run progress, no self-recovery — the only net
/// was the EXTERNAL factory watchdog killing the whole leg after 10 minutes
/// of `fa-trace` staleness. This module gives fa the mid-run layer:
///
/// - a call whose running time exceeds its **stuck threshold** is flagged
///   stuck — the threshold is `max(declaredTimeoutFactor × declared, floor)`
///   so a legitimately long `flutter test` (declared 15 min) is not pestered
///   at minute 2, while anything running far past its own declared bound is;
/// - while a call is outstanding past **half the threshold**, fa emits cheap
///   append-only heartbeat records (tool, args, elapsed, captured-output
///   size) into the session ledger — external watchers can distinguish
///   alive-busy from dead, and the records keep the session file fresh;
/// - in autonomous mode (the default) the threshold itself follows up:
///   cancel the stuck call, retry it once, and if the retry also exceeds
///   the threshold convert it to a background job (the bash tool's own
///   soft-yield path) so the turn continues with the job id + log path;
/// - when recovery cannot succeed, a session-visible escalation names the
///   call, its duration, and the partial output. Never die silently.
///
/// The config is pure data (no IO); yaml parsing follows the repo's strict
/// `WaitingConfig`/`JobsConfig` pattern — a bad schema throws
/// [ConfigException] at boot.
library;

import '../cancel_token.dart';
import '../exceptions.dart';

/// Default absolute floor for the stuck threshold (`agent.stuckTool.
/// floorSeconds`): 5 minutes — inside the factory watchdog's 10-minute
/// trace-staleness limit, so the heartbeats + follow-up land before the
/// external net amputates the run.
const defaultStuckFloorSeconds = 300;

/// Default multiplier for a call's declared timeout
/// (`agent.stuckTool.declaredTimeoutFactor`).
const defaultStuckDeclaredTimeoutFactor = 2;

/// Default heartbeat cadence (`agent.stuckTool.heartbeatSeconds`).
const defaultStuckHeartbeatSeconds = 60;

/// Default bounded wait for a cancelled call to observe its cancellation
/// (`agent.stuckTool.cancelGraceSeconds`).
const defaultStuckCancelGraceSeconds = 10;

/// How the threshold follow-up behaves: [autonomous] cancels/retries/
/// converts (headless parity — the mode-independent default), [advisory]
/// only emits the advisory stuck event (interactive comfort; kill switch
/// for the autonomy).
enum StuckFollowUpMode { autonomous, advisory }

/// The cancel reason the stuck supervisor puts on a call/yield token — a
/// marker, not an error: the tokens' other listeners only check
/// [CancelToken.isCancelled]. Lives here (pure data) so the tool layer can
/// recognize a supervisor-driven yield without importing the loop.
class StuckCallFollowUp {
  const StuckCallFollowUp(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// The text marker a soft-yield hand-back result carries when the command
/// moved to a background job (both the steering and the supervisor-driven
/// flavors): the supervisor reads it to tell a real background conversion
/// apart from a retry that completed its own work (gh-1054 review — no
/// false "converted" marks).
const stuckBackgroundHandbackMarker = 'moved to background job';

/// The deterministic opening sentence of a soft-yield hand-back result —
/// `stuckBackgroundHandbackMarker` alone appears in ordinary tool output
/// too often (an echo, a log tail, a grep over this repo), so the
/// supervisor anchors recognition on this full sentence prefix
/// (gh-1054 review round 2). [builtin_tools.dart] composes its hand-back
/// text to start with exactly this string.
const stuckBackgroundHandbackSentence =
    'The command is still running and was $stuckBackgroundHandbackMarker ';

/// Session record type for a liveness heartbeat (`CustomRecord.customType`):
/// cheap append-only proof that a long tool call is alive-busy.
const toolHeartbeatRecordType = 'tool_heartbeat';

/// Session record type for a stuck-call follow-up transition
/// (`CustomRecord.customType`): advise / cancel+retry / background
/// convert / escalate. Session-visible, so a hung call never dies silently.
const toolStuckRecordType = 'tool_stuck';

/// The `agent.stuckTool:` yaml section (gh-1054). Strict: a bad schema
/// throws at boot; negative values are rejected; `enabled: false` is the
/// kill switch (byte-identical legacy behavior).
final class StuckToolConfig {
  const StuckToolConfig({
    this.enabled = true,
    this.followUp = StuckFollowUpMode.autonomous,
    this.floor = const Duration(seconds: defaultStuckFloorSeconds),
    this.declaredTimeoutFactor = defaultStuckDeclaredTimeoutFactor,
    this.heartbeatInterval = const Duration(
      seconds: defaultStuckHeartbeatSeconds,
    ),
    this.cancelGrace = const Duration(seconds: defaultStuckCancelGraceSeconds),
    this.excludeTools = defaultStuckExcludedTools,
  });

  /// Tools never supervised: `ask`/`request_secret` block on a human by
  /// design (a threshold cancel would re-ask), `task` runs whole subagents
  /// whose own background/settle machinery owns long runs. Configurable so
  /// an owner can supervise any of them explicitly.
  static const defaultStuckExcludedTools = <String>[
    'ask',
    'request_secret',
    'task',
  ];

  /// Kill switch. `false` = no supervision, byte-identical legacy loop.
  final bool enabled;

  /// Threshold follow-up behavior.
  final StuckFollowUpMode followUp;

  /// Absolute floor for the stuck threshold.
  final Duration floor;

  /// Multiplier for the call's declared timeout (`bash`'s `timeout` arg).
  final num declaredTimeoutFactor;

  /// Cadence of the liveness heartbeat records.
  final Duration heartbeatInterval;

  /// Bounded wait for a cancelled call to observe its cancellation before
  /// the supervisor abandons it and moves to the next stage. A wedged
  /// executor that ignores its cancel token cannot block the follow-up
  /// longer than this.
  final Duration cancelGrace;

  /// Tool names never supervised (see [defaultStuckExcludedTools]).
  final List<String> excludeTools;

  /// Whether [name] is excluded from supervision.
  bool excludes(String name) => excludeTools.contains(name);

  /// The stuck threshold for a call that declared [declaredTimeout]:
  /// the greater of (factor × declared) and the absolute floor. A `null`
  /// declared timeout (most tools) uses the floor alone.
  Duration stuckThreshold(Duration? declaredTimeout) {
    final doubled = declaredTimeout == null
        ? Duration.zero
        : declaredTimeout * declaredTimeoutFactor;
    return doubled > floor ? doubled : floor;
  }

  /// When heartbeats start: half the stuck threshold — comfortably before
  /// the follow-up deadline, and for a declared-timeout call exactly at its
  /// own declared bound ("running past its own declared bound" is when the
  /// call becomes interesting to watch).
  Duration heartbeatStart(Duration? declaredTimeout) =>
      stuckThreshold(declaredTimeout) ~/ 2;

  factory StuckToolConfig.fromYaml(Object? node) {
    if (node == null) return const StuckToolConfig();
    if (node is! Map) {
      throw ConfigException('agent.stuckTool must be a map, got: $node');
    }
    int seconds(String key, int fallback, {bool positive = false}) {
      final value = node[key];
      if (value == null) return fallback;
      if (value is! int) {
        throw ConfigException('"agent.stuckTool.$key" must be an integer');
      }
      // A heartbeat cadence of zero would spin the event loop
      // (Timer.periodic(Duration.zero)); a grace/floor of zero is a legal
      // "immediately" knob (gh-1054 review).
      if (positive ? value <= 0 : value < 0) {
        throw ConfigException(
          '"agent.stuckTool.$key" must be '
          '${positive ? '> 0' : '>= 0'}',
        );
      }
      return value;
    }

    var enabled = true;
    var followUp = StuckFollowUpMode.autonomous;
    var floorSeconds = defaultStuckFloorSeconds;
    num factor = defaultStuckDeclaredTimeoutFactor;
    var heartbeatSeconds = defaultStuckHeartbeatSeconds;
    var cancelGraceSeconds = defaultStuckCancelGraceSeconds;
    var excludeTools = defaultStuckExcludedTools;
    for (final key in node.keys) {
      switch (key) {
        case 'enabled':
          final value = node[key];
          if (value is! bool) {
            throw ConfigException(
              '"agent.stuckTool.enabled" must be a boolean',
            );
          }
          enabled = value;
        case 'followUp':
          final value = node[key];
          if (value is! String) {
            throw ConfigException(
              '"agent.stuckTool.followUp" must be a string '
              '(autonomous | advisory)',
            );
          }
          followUp = switch (value) {
            'autonomous' => StuckFollowUpMode.autonomous,
            'advisory' => StuckFollowUpMode.advisory,
            _ => throw ConfigException(
              '"agent.stuckTool.followUp" must be "autonomous" or '
              '"advisory", got: $value',
            ),
          };
        case 'floorSeconds':
          floorSeconds = seconds('floorSeconds', defaultStuckFloorSeconds);
        case 'declaredTimeoutFactor':
          final value = node[key];
          if (value is! num || value <= 0) {
            throw ConfigException(
              '"agent.stuckTool.declaredTimeoutFactor" must be a positive '
              'number',
            );
          }
          factor = value;
        case 'heartbeatSeconds':
          heartbeatSeconds = seconds(
            'heartbeatSeconds',
            defaultStuckHeartbeatSeconds,
            positive: true,
          );
        case 'cancelGraceSeconds':
          cancelGraceSeconds = seconds(
            'cancelGraceSeconds',
            defaultStuckCancelGraceSeconds,
          );
        case 'excludeTools':
          final value = node[key];
          if (value is! List || value.any((entry) => entry is! String)) {
            throw ConfigException(
              '"agent.stuckTool.excludeTools" must be a list of tool names',
            );
          }
          excludeTools = List<String>.from(value);
        default:
          throw ConfigException('unknown "agent.stuckTool" key: $key');
      }
    }
    return StuckToolConfig(
      enabled: enabled,
      followUp: followUp,
      floor: Duration(seconds: floorSeconds),
      declaredTimeoutFactor: factor,
      heartbeatInterval: Duration(seconds: heartbeatSeconds),
      cancelGrace: Duration(seconds: cancelGraceSeconds),
      excludeTools: excludeTools,
    );
  }

  /// The yaml node shape for host persistence (the `agent:` section's
  /// `stuckTool:` sub-map); only non-default values are written so the
  /// config file stays minimal.
  Map<String, Object?> toYamlMap() {
    final map = <String, Object?>{};
    if (!enabled) map['enabled'] = false;
    if (followUp != StuckFollowUpMode.autonomous) {
      map['followUp'] = followUp.name;
    }
    if (floor.inSeconds != defaultStuckFloorSeconds) {
      map['floorSeconds'] = floor.inSeconds;
    }
    if (declaredTimeoutFactor != defaultStuckDeclaredTimeoutFactor) {
      map['declaredTimeoutFactor'] = declaredTimeoutFactor;
    }
    if (heartbeatInterval.inSeconds != defaultStuckHeartbeatSeconds) {
      map['heartbeatSeconds'] = heartbeatInterval.inSeconds;
    }
    if (cancelGrace.inSeconds != defaultStuckCancelGraceSeconds) {
      map['cancelGraceSeconds'] = cancelGrace.inSeconds;
    }
    if (!_listEquals(excludeTools, defaultStuckExcludedTools)) {
      map['excludeTools'] = List<String>.of(excludeTools);
    }
    return map;
  }

  /// Field-wise list equality for the default-exclusion check (Dart list
  /// `==` is identity, so [toYamlMap] needs a deep compare).
  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
