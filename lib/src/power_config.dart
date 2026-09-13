/// Power assertions (issue #325, after oh-my-pi's `power.sleepPrevention`
/// — DELIBERATELY not a lifecycle-for-lifecycle port, see #326): long-
/// running fa runs die with the machine — a sleep during a 3h
/// PR-monitoring run kills the whole schedule. The `power.sleepPrevention`
/// config key picks a cumulative sleep-prevention level; `power.hold`
/// picks WHEN the assertion is held: `per-run` (the default) acquires at
/// run start and releases at settle, so an idle agent never pins the
/// machine awake; `session` (explicit opt-in) holds from session open to
/// close — oh-my-pi's behaviour, kept for always-on deployments.
///
/// Pure Dart (no `dart:io`): the level/lifecycle model, the strict
/// yaml-section parser, and the platform argument builders. The
/// process-spawning runners live in `lib/io.dart`'s barrel
/// (`src/power/io_power_runner.dart`) and hosts inject them through the
/// seam, so this file compiles on every platform and unit tests never
/// spawn a real `caffeinate`.
library;

import 'exceptions.dart';

/// Default text shown in platform power diagnostics ("why is this
/// machine awake?"). `caffeinate(8)` has no reason flag — the CLI banner
/// cannot carry it — but `systemd-inhibit --why` and any future native
/// IOKit assertion do.
const defaultPowerAssertionReason = 'fa agent run';

/// The `power.sleepPrevention` levels. Cumulative: each level adds the
/// capabilities of all lower levels (`display` also prevents idle sleep,
/// `system` also prevents display sleep).
enum PowerAssertionLevel {
  /// No assertion at all.
  off('off'),

  /// Keep the system from idle-sleeping (macOS `caffeinate -i`). The
  /// default — matches oh-my-pi and the historical behaviour.
  idle('idle'),

  /// Also keep the display from idle-sleeping (`caffeinate -i -d`).
  display('display'),

  /// Also block all system sleep on AC and declare the user active
  /// (`caffeinate -i -d -s -u`).
  system('system');

  const PowerAssertionLevel(this.value);

  /// The yaml/config label.
  final String value;

  /// The level for a config label, or null when [value] is not one.
  static PowerAssertionLevel? fromValue(String? value) => switch (value) {
    'off' => PowerAssertionLevel.off,
    'idle' => PowerAssertionLevel.idle,
    'display' => PowerAssertionLevel.display,
    'system' => PowerAssertionLevel.system,
    _ => null,
  };

  @override
  String toString() => value;
}

/// Parses the `power:` yaml section (`sleepPrevention` level + `hold`
/// lifecycle). A null [node] means the section is absent — the CALLER
/// applies the defaults (level `idle`, hold `per-run`; "not configured"
/// and "explicitly off" stay distinct). Any present-but-invalid shape,
/// value or key throws [ConfigException], consistent with the other
/// strict config sections.
PowerSection parsePowerSection(Object? node) {
  if (node == null) return const PowerSection();
  if (node is! Map) {
    throw ConfigException('power must be a map, got: $node');
  }
  PowerAssertionLevel? level;
  PowerAssertionHold? hold;
  for (final key in node.keys) {
    switch ('$key') {
      case 'sleepPrevention':
        final value = '${node[key]}'.trim();
        level = PowerAssertionLevel.fromValue(value);
        if (level == null) {
          throw ConfigException(
            '"power.sleepPrevention" must be off, idle, display or system, '
            'got: $value',
          );
        }
      case 'hold':
        final value = '${node[key]}'.trim();
        hold = PowerAssertionHold.fromValue(value);
        if (hold == null) {
          throw ConfigException(
            '"power.hold" must be per-run or session, got: $value',
          );
        }
      default:
        throw ConfigException('unknown "power" key: $key');
    }
  }
  return PowerSection(sleepPrevention: level, hold: hold);
}

/// The parsed `power:` section: which sleep-prevention capabilities to
/// request and when to hold the assertion for them. Absent members keep
/// their defaults ([PowerAssertionLevel.idle] is applied by the host,
/// [PowerAssertionHold.perRun] is this file's own default).
final class PowerSection {
  const PowerSection({this.sleepPrevention, this.hold});

  /// The `sleepPrevention` level; null when absent (the host applies
  /// `idle` so "unset" and "explicitly off" stay distinct).
  final PowerAssertionLevel? sleepPrevention;

  /// The `hold` lifecycle; null when absent (default `per-run`).
  final PowerAssertionHold? hold;

  @override
  bool operator ==(Object other) =>
      other is PowerSection &&
      other.sleepPrevention == sleepPrevention &&
      other.hold == hold;

  @override
  int get hashCode => Object.hash(sleepPrevention, hold);
}

/// When the sleep-prevention assertion is held (`power.hold`, #326):
/// per-run by default — an agent idling between turns must not pin the
/// machine awake for hours (battery/thermal); holding the whole session
/// is an explicit opt-in.
enum PowerAssertionHold {
  /// Acquire when a run goes in flight, release when it settles
  /// (including post-run compaction). The default.
  perRun('per-run'),

  /// Hold from session open to session close — oh-my-pi's lifecycle,
  /// kept as an explicit opt-in for always-on deployments.
  session('session');

  const PowerAssertionHold(this.value);

  /// The yaml/config label.
  final String value;

  /// The lifecycle for a config label, or null when [value] is not one.
  static PowerAssertionHold? fromValue(String? value) => switch (value) {
    'per-run' => PowerAssertionHold.perRun,
    'session' => PowerAssertionHold.session,
    _ => null,
  };

  @override
  String toString() => value;
}

/// The capabilities one power assertion requests — the Dart mirror of
/// oh-my-pi's native `PowerAssertionOptions`: one flag per capability,
/// all released together when the handle is stopped.
final class PowerAssertionOptions {
  const PowerAssertionOptions({
    required this.reason,
    this.idle = false,
    this.display = false,
    this.system = false,
    this.user = false,
  });

  /// Human-readable reason shown in platform power diagnostics.
  final String reason;

  /// `caffeinate -i`: prevent the system from idle-sleeping.
  final bool idle;

  /// `caffeinate -d`: prevent the display from idle-sleeping.
  final bool display;

  /// `caffeinate -s`: prevent system sleep (AC power only).
  final bool system;

  /// `caffeinate -u`: declare the user active.
  final bool user;
}

/// Translates a level into request options, or null when the level asks
/// for no assertion at all (`off`). Cumulative levels, exactly
/// oh-my-pi's `powerAssertionOptions()`.
PowerAssertionOptions? powerAssertionOptions(PowerAssertionLevel level) =>
    switch (level) {
      PowerAssertionLevel.off => null,
      PowerAssertionLevel.idle => const PowerAssertionOptions(
        reason: defaultPowerAssertionReason,
        idle: true,
      ),
      PowerAssertionLevel.display => const PowerAssertionOptions(
        reason: defaultPowerAssertionReason,
        idle: true,
        display: true,
      ),
      PowerAssertionLevel.system => const PowerAssertionOptions(
        reason: defaultPowerAssertionReason,
        idle: true,
        display: true,
        system: true,
        user: true,
      ),
    };

/// The `caffeinate(8)` argument vector for [options], ending in the
/// `-w <pid>` lifecycle bind: caffeinate watches the fa pid and
/// self-exits when it goes away, so a crashed fa can never leak the
/// assertion.
List<String> caffeinateArguments(
  PowerAssertionOptions options, {
  required int pid,
}) => [
  if (options.idle) '-i',
  if (options.display) '-d',
  if (options.system) '-s',
  if (options.user) '-u',
  '-w',
  '$pid',
];

/// The `systemd-inhibit(1)` argument vector for [options]: systemd-inhibit
/// holds its `--what` capabilities while the COMMAND it runs stays alive,
/// so the argument vector ends in a watchdog shell loop that exits when
/// the fa pid disappears — the Linux counterpart of `caffeinate -w`.
List<String> systemdInhibitArguments(
  PowerAssertionOptions options, {
  required int pid,
}) => [
  '--what=${options.system ? 'idle:sleep' : 'idle'}',
  '--who=fa',
  '--why=${options.reason}',
  'sh',
  '-c',
  'while kill -0 $pid 2>/dev/null; do sleep 10; done',
];
