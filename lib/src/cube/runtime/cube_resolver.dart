/// Locates and parses a cube manifest for a run: by explicit file path
/// (highest precedence), by name from `<cwd>/.fah/cubes/<name>.yaml`, or —
/// when no project file exists — as a built-in security-level preset
/// (`l1-core` … `l3-full`, bare level = conservative core axis). A project
/// manifest with the same id wins over the preset body.
///
/// Pure Dart: all file access goes through the [ExecutionEnv] portability
/// boundary, so resolution works identically against the real filesystem,
/// the Flutter sandbox and [MemoryExecutionEnv] in tests.
///
/// Failures are loud: a missing or unreadable file, invalid yaml or a
/// schema violation all throw [ConfigException] (the not-found error lists
/// the built-in preset ids for discoverability). Requesting nothing
/// (neither [CubeResolver.resolve] `path` nor `name`) yields `null` — no
/// cube requested, no cube applied.
library;

import 'package:yaml/yaml.dart';

import '../../env/execution_env.dart';
import '../../exceptions.dart';
import '../config/cube_presets.dart';
import '../config/cube_spec.dart';

/// Resolves [CubeSpec] manifests by path, name or built-in preset.
final class CubeResolver {
  /// Resolves a cube manifest.
  ///
  /// - [path] — explicit manifest file (highest precedence). A leading `~/`
  ///   is expanded with [homeDir] when known.
  /// - [name] — looks up `<env.cwd>/.fah/cubes/<name>.yaml`, falling back to
  ///   the built-in preset with that id (project file wins over the preset).
  /// - neither — returns `null`.
  ///
  /// A missing/unreadable file throws
  /// `ConfigException('cube: file not found: <path> …')` with the preset
  /// ids appended; invalid yaml or a schema violation propagates as
  /// [ConfigException] from the parser.
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
    final read = await env.readTextFile(filePath);
    if (read is Err) {
      // A name lookup falls back to the built-in security-level presets;
      // explicit paths and non-preset names stay loud.
      if (name != null) {
        final preset = CubePresets.maybeSpec(name: name, cwd: env.cwd);
        if (preset != null) return preset;
      }
      throw _notFound(filePath, name);
    }
    final content = (read as Ok<String, FileError>).value;
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

  /// The not-found error for a name lookup: when [name] is a built-in
  /// preset id the resolver has already fallen back (see [resolve]); for
  /// other names the error lists the available ids.
  static ConfigException _notFound(String filePath, String? name) {
    if (name != null && CubePresets.byId(name) != null) {
      return ConfigException('cube: file not found: $filePath');
    }
    final ids = CubePresets.all.map((preset) => preset.id).join(', ');
    return ConfigException(
      'cube: file not found: $filePath '
      '(built-in security-level presets: $ids)',
    );
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
