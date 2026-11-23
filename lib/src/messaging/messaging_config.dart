/// The `messaging:` config section (issue #2226): the wake-gating knobs —
/// the legacy inbox-wake chatter cap (OFF by default now), the autonomous
/// agent↔agent chain token budget, and the smart loop-detection thresholds.
///
/// File-tuned operational knobs (see the parity registry's
/// `fileOnlyConfigKeys` entry): hosts READ the section at boot, pause
/// digests surface on both hosts' UIs, and no settings UI writes it.
/// Parsed strictly: a bad schema throws [ConfigException] instead of
/// silently keeping defaults.
library;

import '../exceptions.dart';

/// The `messaging:` section.
final class MessagingConfig {
  const MessagingConfig({
    this.wakeChatterCap = defaultWakeChatterCap,
    this.chainBudgetTokens = defaultChainBudgetTokens,
    this.loopDetection = const ChainLoopDetectionConfig(),
  });

  /// The chatter cap is OFF by default (issue #2226): the raw
  /// consecutive-wake counter is legacy — productive long collaborations
  /// and identical ping-pong look identical to it. A positive value
  /// re-enables the exact pre-#2226 behavior (10 was the old default).
  static const int defaultWakeChatterCap = 0;

  /// The autonomous-chain budget default: a generous bound (~200 turns of
  /// spend) — the honest ceiling for true storms, replacing "10 mails".
  static const int defaultChainBudgetTokens = 400000;

  /// Consecutive agent-kind wakes allowed without user input when
  /// explicitly re-enabled; `0` (default) disables the cap entirely.
  final int wakeChatterCap;

  /// The token budget an autonomous agent↔agent chain may spend between
  /// user inputs. Exhaustion pauses the chain with a budget digest —
  /// never a silent refusal. `0` disables the budget.
  final int chainBudgetTokens;

  /// The smart loop detector (on by default — the #2226 replacement for
  /// the cap).
  final ChainLoopDetectionConfig loopDetection;

  /// Parses the `messaging:` section:
  ///
  /// ```yaml
  /// messaging:
  ///   wakeChatterCap: 0            # legacy streak cap, OFF by default
  ///   chainBudgetTokens: 400000    # autonomous agent↔agent spend bound
  ///   loopDetection:
  ///     enabled: true
  ///     similarityThreshold: 0.92  # normalized-text pairwise similarity
  ///     stuckRounds: 4             # no-progress rounds before a verdict
  /// ```
  static MessagingConfig fromYaml(Object? node) {
    if (node == null) return const MessagingConfig();
    if (node is! Map) {
      throw ConfigException('messaging must be a map, got: $node');
    }
    for (final key in node.keys) {
      if (!const {
        'wakeChatterCap',
        'chainBudgetTokens',
        'loopDetection',
      }.contains(key)) {
        throw ConfigException('unknown "messaging" key: $key');
      }
    }
    return MessagingConfig(
      wakeChatterCap: _nonNegativeInt(
        node,
        'wakeChatterCap',
        defaultWakeChatterCap,
        'messaging.wakeChatterCap',
      ),
      chainBudgetTokens: _nonNegativeInt(
        node,
        'chainBudgetTokens',
        defaultChainBudgetTokens,
        'messaging.chainBudgetTokens',
      ),
      loopDetection: ChainLoopDetectionConfig.fromYaml(node['loopDetection']),
    );
  }

  static int _nonNegativeInt(Map node, String key, int fallback, String label) {
    final value = node[key];
    if (value == null) return fallback;
    if (value is! int || value < 0) {
      throw ConfigException('"$label" must be a non-negative integer');
    }
    return value;
  }
}

/// The `messaging.loopDetection:` subsection (issue #2226).
final class ChainLoopDetectionConfig {
  const ChainLoopDetectionConfig({
    this.enabled = true,
    this.similarityThreshold = 0.92,
    this.stuckRounds = 4,
  });

  /// The smart path is on by default; `false` restores bare
  /// cap/budget gating (loop verdicts never fire).
  final bool enabled;

  /// Masked-text pairwise similarity above which a no-progress exchange
  /// counts as a stuck round.
  final double similarityThreshold;

  /// Consecutive no-progress rounds before a loop verdict.
  final int stuckRounds;

  static ChainLoopDetectionConfig fromYaml(Object? node) {
    if (node == null) return const ChainLoopDetectionConfig();
    if (node is! Map) {
      throw ConfigException(
        'messaging.loopDetection must be a map, got: $node',
      );
    }
    _checkLoopKeys(node);
    return ChainLoopDetectionConfig(
      enabled: _parseLoopEnabled(node['enabled']),
      similarityThreshold: _parseLoopThreshold(node['similarityThreshold']),
      stuckRounds: _parseLoopRounds(node['stuckRounds']),
    );
  }

  /// Strict key vocabulary for the `messaging.loopDetection` map
  /// (unchanged: an unknown key is a hard config error).
  static void _checkLoopKeys(Map node) {
    for (final key in node.keys) {
      if (!const {
        'enabled',
        'similarityThreshold',
        'stuckRounds',
      }.contains(key)) {
        throw ConfigException('unknown "messaging.loopDetection" key: $key');
      }
    }
  }

  /// Parses `similarityThreshold` (null = the default 0.92; a number
  /// outside 0..1 is a hard config error).
  static double _parseLoopThreshold(Object? threshold) {
    if (threshold != null &&
        (threshold is! num || threshold < 0 || threshold > 1)) {
      throw ConfigException(
        '"messaging.loopDetection.similarityThreshold" must be a number '
        'between 0 and 1',
      );
    }
    return threshold == null ? 0.92 : (threshold as num).toDouble();
  }

  /// Parses `stuckRounds` (null = the default 4; a non-int or < 1 is a
  /// hard config error).
  static int _parseLoopRounds(Object? rounds) {
    if (rounds != null && (rounds is! int || rounds < 1)) {
      throw ConfigException(
        '"messaging.loopDetection.stuckRounds" must be a positive integer',
      );
    }
    return rounds == null ? 4 : rounds as int;
  }

  /// Parses `enabled` (null = the default true; a non-bool is a hard
  /// config error).
  static bool _parseLoopEnabled(Object? enabled) {
    if (enabled != null && enabled is! bool) {
      throw ConfigException(
        '"messaging.loopDetection.enabled" must be a boolean',
      );
    }
    return enabled == null ? true : enabled as bool;
  }
}
