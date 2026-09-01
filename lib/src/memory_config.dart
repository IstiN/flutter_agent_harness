/// The `memory:` section of `~/.fah/config.yaml`: where the long-term
/// memory stores live. Defaults (no section) keep the historical layout —
/// `<projectRoot>/.fah/memory` and `$HOME/.fah/memory`. Setting
/// [projectPath] inside the repository (e.g. `./memory`) makes the
/// project memory committable: anyone cloning the repo gets its memory.
library;

import 'exceptions.dart';

/// Parsed `memory:` section. Both fields optional; null = default path.
final class MemoryConfig {
  const MemoryConfig({this.projectPath, this.userPath});

  /// Parses the section strictly: a non-map node, unknown keys, and
  /// non-string values throw [ConfigException] (a typo must surface, not
  /// silently write memory somewhere unexpected).
  factory MemoryConfig.fromYaml(Object? node) {
    if (node is! Map) {
      throw const ConfigException(
        'memory: section must be a map (projectPath/userPath)',
      );
    }
    String? projectPath;
    String? userPath;
    for (final entry in node.entries) {
      final key = '${entry.key}';
      final value = entry.value;
      if (value is! String) {
        throw ConfigException('memory.$key must be a string path');
      }
      switch (key) {
        case 'projectPath':
          projectPath = value;
        case 'userPath':
          userPath = value;
        default:
          throw ConfigException(
            'memory: unknown key "$key" (known: projectPath, userPath)',
          );
      }
    }
    return MemoryConfig(projectPath: projectPath, userPath: userPath);
  }

  /// Project-scope storage path. Absolute used as-is; relative resolves
  /// against the project root.
  final String? projectPath;

  /// User-scope storage path. A leading `~/` expands against the user
  /// home; absolute used as-is; relative resolves against the user root.
  final String? userPath;

  /// Resolves [projectPath] against [projectRoot] (null → the default
  /// `<projectRoot>/.fah/memory`).
  String resolveProjectPath(String projectRoot) {
    final path = projectPath;
    if (path == null || path.isEmpty) return '$projectRoot/.fah/memory';
    if (path.startsWith('/')) return path;
    final stripped = path.startsWith('./') ? path.substring(2) : path;
    return '$projectRoot/$stripped';
  }

  /// Resolves [userPath] against [userRoot] (null → the default
  /// `<userRoot>/.fah/memory`; `~/x` → `<userRoot>/x`).
  String resolveUserPath(String userRoot) {
    final path = userPath;
    if (path == null || path.isEmpty) return '$userRoot/.fah/memory';
    if (path.startsWith('~/')) return '$userRoot/${path.substring(2)}';
    if (path.startsWith('/')) return path;
    final stripped = path.startsWith('./') ? path.substring(2) : path;
    return '$userRoot/$stripped';
  }
}
