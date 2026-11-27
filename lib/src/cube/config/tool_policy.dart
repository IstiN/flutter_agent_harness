/// Tool-level policy for a cube (`spec.tools:`): which shell command words a
/// sandboxed run may execute.
///
/// ```yaml
/// spec:
///   tools:
///     allow: [git, curl, "git*"]   # entries may end with a '*' wildcard
///     deny: ["git push", ssh]
/// ```
///
/// Matching semantics (documented for [CubeToolPolicy.permits]):
///
/// - An entry matches [commandWords] when the entry equals it, OR the entry is
///   a prefix of it at a **word boundary** (the next character is a space, so
///   `git push` matches `git push -f` but not `git-push`), OR the entry ends
///   with `*` and the entry without the star is a **plain string prefix**
///   (so `git*` matches `git`, `git-status` and `gitk` alike — the wildcard
///   is intentionally character-level, not word-level).
/// - `deny` always wins over `allow`.
/// - An empty `allow` denies everything: a cube without an explicit allow
///   list runs no tools (safe default).
///
/// Parsing is strict like the other config sections: any schema problem
/// throws [ConfigException] naming the YAML path.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

/// The `spec.tools:` section of a cube: the allow/deny command-word sets.
final class CubeToolPolicy {
  /// Creates a policy; both sets are matched as whole command-word strings
  /// (e.g. `'git push'`), never shell-expressed.
  const CubeToolPolicy({this.allow = const {}, this.deny = const {}});

  /// Command words the run may execute. Empty set = deny everything.
  final Set<String> allow;

  /// Command words always refused, even when [allow] matches.
  final Set<String> deny;

  /// Parses the `spec.tools:` section. `null` (section absent) yields the
  /// safe default: no allow entries, so everything is denied.
  factory CubeToolPolicy.fromYaml(Object? node) {
    if (node == null) return const CubeToolPolicy();
    if (node is! YamlMap) {
      throw ConfigException(
        'cube.spec.tools: must be a map with optional "allow"/"deny", '
        'got ${node.runtimeType}',
      );
    }
    for (final key in node.keys) {
      if (key is! String || (key != 'allow' && key != 'deny')) {
        throw ConfigException(
          'cube.spec.tools: unknown key "$key" — supported: allow, deny',
        );
      }
    }
    return CubeToolPolicy(
      allow: _parseEntries(node['allow'], 'cube.spec.tools.allow'),
      deny: _parseEntries(node['deny'], 'cube.spec.tools.deny'),
    );
  }

  /// Whether the space-joined command portion [commandWords] (e.g.
  /// `'git push'`) may run: not denied, and allowed by at least one entry.
  ///
  /// An empty [allow] always returns `false` regardless of [deny].
  bool permits(String commandWords) {
    final words = commandWords.trim();
    if (allow.isEmpty) return false;
    if (deny.any((entry) => _entryMatches(entry, words))) return false;
    return allow.any((entry) => _entryMatches(entry, words));
  }

  /// Entry matching per the class documentation: exact, word-boundary
  /// prefix, or trailing-`*` plain string prefix.
  static bool _entryMatches(String entry, String commandWords) {
    if (entry.endsWith('*')) {
      return commandWords.startsWith(entry.substring(0, entry.length - 1));
    }
    if (commandWords == entry) return true;
    return commandWords.startsWith(entry) &&
        commandWords.length > entry.length &&
        commandWords.codeUnitAt(entry.length) == 0x20; // space boundary
  }

  static Set<String> _parseEntries(Object? node, String where) {
    if (node == null) return const {};
    if (node is! YamlList) {
      throw ConfigException('$where: must be a list of strings');
    }
    return {
      for (final entry in node)
        entry is String && entry.trim().isNotEmpty
            ? entry.trim()
            : throw ConfigException(
                '$where: entries must be non-empty strings, got $entry',
              ),
    };
  }
}
