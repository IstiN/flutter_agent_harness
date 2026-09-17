/// The compaction engine selector (issue #148 D8/AC1, default flip #287).
///
/// Two engines coexist: `classic` (the lossy prefix summary — the legacy
/// 1.0 engine, kept as the in-settings rollback) and `structured`
/// (hide → checkpoint + expand, issue #148) — the DEFAULT everywhere
/// since #287. The setting resolves through the config chain —
/// `compaction.engine` in `~/.fah/config.yaml` (global) < `.fah/config.yaml`
/// (project) < a session override (runtime flag / settings surface) — with
/// the deepest scope winning. The engines never mix WITHIN one compaction
/// run, but a session may carry records of both kinds: projection renders
/// legacy classic summaries as opaque `[legacy-ckpt·classic·not-expandable]`
/// segments under the structured engine (scenario S7, AC9).
library;

import '../exceptions.dart';

/// Which compaction engine a compaction run uses.
enum CompactionEngine {
  /// The classic lossy prefix summary — the legacy 1.0 engine, kept as
  /// the supported in-settings rollback (issue #287).
  classic('classic'),

  /// The structured engine: judge-hide pass, checkpoint pass, expand API.
  /// The DEFAULT everywhere since issue #287.
  structured('structured');

  const CompactionEngine(this.value);

  /// The `compaction.engine` config value.
  final String value;

  /// Parses a `compaction.engine` value; `null` when [value] is absent.
  ///
  /// Anything else is a strict [ConfigException] — a typo must surface at
  /// boot, not silently fall back to classic.
  static CompactionEngine? tryParse(Object? value, {required String label}) {
    if (value == null) return null;
    if (value is! String) {
      throw ConfigException(
        '$label: compaction.engine must be a string, got: $value',
      );
    }
    if (value == 'classic') return CompactionEngine.classic;
    if (value == 'structured') return CompactionEngine.structured;
    throw ConfigException(
      '$label: compaction.engine must be classic or structured, '
      "got: '$value'",
    );
  }

  /// Parses a raw `compaction:` section node (`{engine: structured}`).
  static CompactionEngine? fromSection(Object? node, {required String label}) {
    if (node == null) return null;
    if (node is! Map) {
      throw ConfigException(
        '$label: compaction must be a map with an engine key, got: $node',
      );
    }
    return tryParse(node['engine'], label: label);
  }
}

/// Parses `compaction.judgeBudgetSeconds` (issue #541): the per-call
/// judge budget knob. `null` when absent; anything else non-numeric or
/// non-positive is a strict [ConfigException] — a typo must surface at
/// boot, not silently restore the 90s default.
int? parseJudgeBudgetSeconds(Object? value, {required String label}) {
  if (value == null) return null;
  if (value is! int) {
    throw ConfigException(
      '$label: compaction.judgeBudgetSeconds must be a positive int, '
      "got: $value",
    );
  }
  if (value <= 0) {
    throw ConfigException(
      '$label: compaction.judgeBudgetSeconds must be positive, got: $value',
    );
  }
  return value;
}

/// Resolves the effective engine: global < project < session, deepest
/// non-null wins, default [CompactionEngine.structured] (issue #287 —
/// classic stays selectable as the supported rollback).
CompactionEngine resolveCompactionEngine({
  CompactionEngine? global,
  CompactionEngine? project,
  CompactionEngine? session,
}) => session ?? project ?? global ?? CompactionEngine.structured;
