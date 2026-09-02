/// Locates and parses a cube manifest for a run: by explicit file path
/// (highest precedence) or by name from `<cwd>/.fah/cubes/<name>.yaml`.
///
/// Pure Dart: all file access goes through the [ExecutionEnv] portability
/// boundary, so resolution works identically against the real filesystem,
/// the Flutter sandbox and [MemoryExecutionEnv] in tests.
///
/// Failures are loud: a missing or unreadable file, invalid yaml or a
/// schema violation all throw [ConfigException]. Requesting nothing
/// (neither [CubeResolver.resolve] `path` nor `name`) yields `null` — no
/// cube requested, no cube applied.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';
import '../config/cube_spec.dart';
import '../../env/execution_env.dart';

/// Resolves [CubeSpec] manifests by path or name.
final class CubeResolver {
  /// Resolves a cube manifest.
  ///
  /// - [path] — explicit manifest file (highest precedence). A leading `~/`
  ///   is expanded with [homeDir] when known.
  /// - [name] — looks up `<env.cwd>/.fah/cubes/<name>.yaml`.
  /// - neither — returns `null`.
  ///
  /// A missing/unreadable file throws
  /// `ConfigException('cube: file not found: <path>')`; invalid yaml or a
  /// schema violation propagates as [ConfigException] from the parser.
  static Future<CubeSpec?> resolve({
    required ExecutionEnv env,
    String? path,
    String? name,
    String? homeDir,
  }) async {
    final String filePath;
    if (path != null) {
      final expanded = _expandHome(path, homeDir);
      if (expanded == null) {
        throw ConfigException(
          'cube: cannot expand "~" without a home directory: $path',
        );
      }
      filePath = expanded;
    } else if (name != null) {
      filePath = '${env.cwd}/.fah/cubes/$name.yaml';
    } else {
      return null;
    }
    final content = switch (await env.readTextFile(filePath)) {
      Ok(:final value) => value,
      Err() => throw ConfigException('cube: file not found: $filePath'),
    };
    final Object? document;
    try {
      document = loadYaml(content);
    } on YamlException catch (error) {
      throw ConfigException(
        'cube: invalid yaml in $filePath: ${error.message}',
      );
    }
    return CubeSpec.fromYaml(document, sourcePath: filePath);
  }

  /// Expands a leading `~`/`~/` prefix; `null` when [homeDir] is missing.
  static String? _expandHome(String path, String? homeDir) {
    if (!path.startsWith('~')) return path;
    final home = homeDir?.trim();
    if (home == null || home.isEmpty) return null;
    if (path == '~') return home;
    if (path.startsWith('~/')) return '$home/${path.substring(2)}';
    return path;
  }
}
