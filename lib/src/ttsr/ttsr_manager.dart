/// The TTSR rule registry and stream matcher (omp's `TtsrManager`).
///
/// Ported from oh-my-pi `packages/coding-agent/src/export/ttsr.ts`, reduced
/// to regex conditions (no ast-grep, no path globs). The manager watches one
/// turn's stream: deltas are appended to per-stream buffers and every
/// registered rule's conditions are tested against the buffer.
///
/// Matching strategy (omp's approach): each delta is appended to a
/// cumulative buffer keyed by stream (`text`, `thinking`, or the tool-call
/// id) and the whole buffer is re-tested on every delta. A cumulative
/// buffer, not a per-delta or sliding-window match, so a pattern split
/// across chunk boundaries still matches once its tail arrives — arbitrary
/// regexes have no bounded lookback window, and a window would reintroduce
/// false-negative splits. The theoretical O(buffer × deltas) rescan is
/// bounded in practice: buffers reset on every turn start, and a match
/// aborts the stream, cutting pathological growth short.
library;

// Initializing formals would make the settings parameter name private.
// ignore_for_file: prefer_initializing_formals

import 'ttsr_rule.dart';

/// What happens to the violating partial assistant output before the retry
/// (omp's `ttsr.contextMode`).
enum TtsrContextMode {
  /// The partial/aborted assistant message is dropped before the retry
  /// (omp default).
  discard,

  /// The partial output stays in the conversation; the reminder is appended
  /// after it.
  keep,
}

/// How often a rule may re-trigger (omp's `ttsr.repeatMode`).
enum TtsrRepeatMode {
  /// A rule triggers at most once per session (omp default).
  once,

  /// A rule re-triggers after [TtsrSettings.repeatGap] completed turns.
  afterGap,
}

/// TTSR settings (omp's `TtsrSettings`, reduced).
final class TtsrSettings {
  /// Creates settings; every field has omp's default.
  const TtsrSettings({
    this.enabled = true,
    this.contextMode = TtsrContextMode.discard,
    this.repeatMode = TtsrRepeatMode.once,
    this.repeatGap = 10,
    this.maxInjectionsPerTurn = 3,
    this.retryDelay = const Duration(milliseconds: 50),
  });

  /// omp's defaults: enabled, discard partials, fire once per session.
  static const defaultSettings = TtsrSettings();

  /// Gates the whole manager: when false, registration is refused and
  /// matching always returns empty (omp semantics).
  final bool enabled;

  /// Partial-output handling before the retry.
  final TtsrContextMode contextMode;

  /// Repeat policy for already-injected rules.
  final TtsrRepeatMode repeatMode;

  /// Completed turns before a rule may re-trigger under
  /// [TtsrRepeatMode.afterGap] (omp default 10).
  final int repeatGap;

  /// Retry-storm guard: at most this many abort/inject/retry cycles per
  /// prompt turn (the chain of retries stemming from one user prompt).
  /// Further matches are ignored until a run completes cleanly.
  ///
  /// NOT an omp mechanism — omp relies on the repeat policy alone (with
  /// [TtsrRepeatMode.once] the registered rule count bounds injections);
  /// this cap additionally bounds [TtsrRepeatMode.afterGap] and multi-rule
  /// chains. Default 3.
  final int maxInjectionsPerTurn;

  /// Delay between the mid-stream abort and the retry (omp schedules the
  /// retry 50ms out so the aborted run settles first).
  final Duration retryDelay;

  /// Parses a mode label (`discard`/`keep`, `once`/`after-gap`); returns
  /// null on unknown labels.
  static TtsrContextMode? contextModeFromLabel(String label) {
    return switch (label.trim().toLowerCase()) {
      'discard' => TtsrContextMode.discard,
      'keep' => TtsrContextMode.keep,
      _ => null,
    };
  }

  /// Parses a repeat-mode label (`once`/`after-gap`).
  static TtsrRepeatMode? repeatModeFromLabel(String label) {
    return switch (label.trim().toLowerCase()) {
      'once' => TtsrRepeatMode.once,
      'after-gap' || 'aftergap' => TtsrRepeatMode.afterGap,
      _ => null,
    };
  }
}

/// A registered rule with its compiled conditions.
final class _TtsrEntry {
  _TtsrEntry(this.rule, this.conditions);

  final TtsrRule rule;
  final List<RegExp> conditions;
}

/// Registry + matcher for time-traveling stream rules.
///
/// Port of omp's `TtsrManager`: rules register with compiled regex
/// conditions and a stream scope; [checkDelta] appends a delta to its
/// scoped buffer and returns every rule that passes the repeat, scope, and
/// condition gates. Injection bookkeeping ([markInjectedByNames],
/// [restoreInjected]) implements the repeat policy and session restore.
final class TtsrManager {
  /// Creates a manager with [settings] (omp's defaults when omitted).
  TtsrManager({TtsrSettings settings = TtsrSettings.defaultSettings})
    : _settings = settings;

  final TtsrSettings _settings;
  final _rules = <String, _TtsrEntry>{};
  final _injectionRecords = <String, int>{};
  final _buffers = <String, StringBuffer>{};
  var _messageCount = 0;
  var _canMatchText = false;
  var _canMatchThinking = false;

  /// Non-fatal registration problems (invalid regex, unreachable scope),
  /// collected instead of logged (omp logs warnings; pure Dart collects).
  final warnings = <String>[];

  /// The active settings.
  TtsrSettings get settings => _settings;

  /// Registers [rule] for monitoring (omp's `addRule`).
  ///
  /// Returns false when TTSR is disabled, the rule is disabled, a rule with
  /// the same name is already registered, no condition compiles, or the
  /// scope excludes all monitored streams.
  bool addRule(TtsrRule rule) {
    if (!_settings.enabled || !rule.enabled) return false;
    if (_rules.containsKey(rule.name)) return false;

    final conditions = <RegExp>[];
    for (final pattern in rule.patterns) {
      try {
        conditions.add(RegExp(pattern));
      } on Object catch (error) {
        warnings.add(
          'TTSR rule "${rule.name}": invalid regex "$pattern" ($error), '
          'skipped',
        );
      }
    }
    if (conditions.isEmpty) {
      warnings.add(
        'TTSR rule "${rule.name}": no compilable condition, rule skipped',
      );
      return false;
    }
    if (!rule.scope.isReachable) {
      warnings.add(
        'TTSR rule "${rule.name}": scope excludes all streams, rule skipped',
      );
      return false;
    }
    _rules[rule.name] = _TtsrEntry(rule, conditions);
    if (rule.scope.allowText) _canMatchText = true;
    if (rule.scope.allowThinking) _canMatchThinking = true;
    return true;
  }

  /// Whether [ruleName] may trigger under the repeat policy
  /// (omp's `canTrigger`).
  bool _canTrigger(String ruleName) {
    final lastInjectedAt = _injectionRecords[ruleName];
    if (lastInjectedAt == null) return true;
    if (_settings.repeatMode == TtsrRepeatMode.once) return false;
    return _messageCount - lastInjectedAt >= _settings.repeatGap;
  }

  String _bufferKey(TtsrMatchContext context) {
    final streamKey = context.streamKey;
    if (streamKey != null && streamKey.trim().isNotEmpty) return streamKey;
    if (context.source != TtsrMatchSource.tool) return context.source.name;
    final toolName = context.toolName?.trim().toLowerCase();
    return toolName != null && toolName.isNotEmpty ? 'tool:$toolName' : 'tool';
  }

  /// Appends [delta] to its scoped buffer and returns every matching rule
  /// (omp's `checkDelta`).
  ///
  /// Buffers are isolated by source/tool-call key so matches don't bleed
  /// across assistant prose, thinking, and unrelated tool argument streams.
  List<TtsrRule> checkDelta(String delta, TtsrMatchContext context) {
    if (context.source == TtsrMatchSource.text && !_canMatchText) {
      return const [];
    }
    if (context.source == TtsrMatchSource.thinking && !_canMatchThinking) {
      return const [];
    }
    final key = _bufferKey(context);
    final buffer = _buffers.putIfAbsent(key, StringBuffer.new)..write(delta);
    return _matchBuffer(buffer.toString(), context);
  }

  List<TtsrRule> _matchBuffer(String buffer, TtsrMatchContext context) {
    if (!_settings.enabled) return const [];
    final matches = <TtsrRule>[];
    for (final MapEntry(:key, :value) in _rules.entries) {
      if (!_canTrigger(key)) continue;
      if (!value.rule.scope.matches(context)) continue;
      if (!value.conditions.any((condition) => condition.hasMatch(buffer))) {
        continue;
      }
      matches.add(value.rule);
    }
    return matches;
  }

  /// Marks rules as injected so they don't trigger again until the repeat
  /// policy allows (omp's `markInjectedByNames`).
  void markInjectedByNames(List<String> ruleNames) {
    for (final rawName in ruleNames) {
      final ruleName = rawName.trim();
      if (ruleName.isEmpty) continue;
      _injectionRecords[ruleName] = _messageCount;
    }
  }

  /// Names of all injected rules (omp's persistence payload).
  List<String> get injectedRuleNames =>
      List.unmodifiable(_injectionRecords.keys);

  /// Restores injected state from persisted rule names (omp's
  /// `restoreInjected`).
  void restoreInjected(List<String> ruleNames) {
    for (final name in ruleNames) {
      _injectionRecords[name] = 0;
    }
  }

  /// Clears injected state (e.g. when the host starts a new session — omp
  /// builds a fresh manager per session).
  void clearInjected() => _injectionRecords.clear();

  /// Resets the stream buffers (omp: called on every turn start).
  void resetBuffer() => _buffers.clear();

  /// Whether any rules are registered (omp's `hasRules`).
  bool hasRules() => _settings.enabled && _rules.isNotEmpty;

  /// All registered rules, in registration order (omp's `getRules`).
  List<TtsrRule> get rules =>
      List.unmodifiable(_rules.values.map((entry) => entry.rule));

  /// Increments the completed-turn counter (omp: called on `turn_end`;
  /// drives [TtsrRepeatMode.afterGap]).
  void incrementMessageCount() => _messageCount++;

  /// The completed-turn counter (omp's `getMessageCount`).
  int get messageCount => _messageCount;
}
