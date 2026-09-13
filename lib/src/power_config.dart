/// Power assertions (issue #325, ported from oh-my-pi's
/// `power.sleepPrevention`): long-running fa sessions die with the
/// machine — a sleep during a 3h PR-monitoring session kills the whole
/// schedule. The `power.sleepPrevention` config key picks a cumulative
/// sleep-prevention level; the session start acquires one assertion and
/// the exit releases it.
///
/// Pure Dart (no `dart:io`): the level model, the strict yaml-section
/// parser, and the platform argument builders. The process-spawning
/// runners live in `lib/io.dart`'s barrel (`src/power/io_power_runner.dart`)
/// and hosts inject them through the seam, so this file compiles on every
/// platform and unit tests never spawn a real `caffeinate`.
library;

import 'exceptions.dart';

/// Default text shown in platform power diagnostics ("why is this
/// machine awake?"). `caffeinate(8)` has no reason flag — the CLI banner
/// cannot carry it — but `systemd-inhibit --why` and any future native
/// IOKit assertion do.
const defaultPowerAssertionReason = 'fa agent session';

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
  static PowerAssertionLevel? fromValue(String? value) =>
      switch (value) {
        'off' => PowerAssertionLevel.off,
        'idle' => PowerAssertionLevel.idle,
        'display' => PowerAssertionLevel.display,
        'system' => PowerAssertionLevel.system,
        _ => null,
      };

  @override
  String toString() => value;
}

/// Parses the `power:` yaml section (`sleepPrevention` member). A null
/// [node] means the section is absent — the CALLER applies the `idle`
/// default (so "not configured" and "explicitly off" stay distinct). Any
/// present-but-invalid shape, value or key throws [ConfigException],
/// consistent with the other strict config sections.
PowerAssertionLevel? parsePowerSection(Object? node) {
  if (node == null) return null;
  if (node is! Map) {
    throw ConfigException('power must be a map, got: $node');
  }
  PowerAssertionLevel? level;
  for (final key in node.keys) {
    if ('$key' != 'sleepPrevention') {
      throw ConfigException('unknown "power" key: $key');
    }
    final value = '${node[key]}'.trim();
    level = PowerAssertionLevel.fromValue(value);
    if (level == null) {
      throw ConfigException(
        '"power.sleepPrevention" must be off, idle, display or system, '
        'got: $value',
      );
    }
  }
  return level;
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
