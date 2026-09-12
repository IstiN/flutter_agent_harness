/// The compaction engine selector (issue #148 D8/AC1).
///
/// Two engines coexist: `classic` (the lossy prefix summary, the default
/// during incubation) and `structured` (hide → checkpoint + expand, issue
/// #148). The setting resolves through the config chain —
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
  /// The classic lossy prefix summary.
  classic('classic'),

  /// The structured engine: judge-hide pass, checkpoint pass, expand API.
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

/// Resolves the effective engine: global < project < session, deepest
/// non-null wins, default [CompactionEngine.classic] (AC1).
CompactionEngine resolveCompactionEngine({
  CompactionEngine? global,
  CompactionEngine? project,
  CompactionEngine? session,
}) => session ?? project ?? global ?? CompactionEngine.classic;
