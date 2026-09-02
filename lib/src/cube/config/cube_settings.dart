/// The `cube:` section of `~/.fah/config.yaml`: the default cube applied at
/// startup when neither `--cube` nor `--cube-config` is passed.
///
/// ```yaml
/// cube:
///   enabled: true                 # default true — the section opts in
///   config: .fah/cubes/dev.yaml   # manifest path, or a bare cube name
/// ```
///
/// Parsing is strict like the other config sections: an unknown key or a
/// wrong-typed value throws [ConfigException].
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

/// The `cube:` config section: opt-in switch plus the default manifest.
final class CubeSettings {
  /// Creates settings.
  const CubeSettings({this.enabled = true, this.configPath});

  /// Parses the `cube:` section. Strict: unknown keys throw
  /// [ConfigException].
  factory CubeSettings.fromYaml(Object? node) {
    if (node is! YamlMap) {
      throw ConfigException(
        '"cube" must be a map of cube settings, got ${node.runtimeType}',
      );
    }
    var enabled = true;
    String? configPath;
    for (final key in node.keys) {
      switch (key) {
        case 'enabled':
          final value = node[key];
          if (value is! bool) {
            throw ConfigException(
              '"cube.enabled" must be a boolean, got $value',
            );
          }
          enabled = value;
        case 'config':
          final value = node[key];
          if (value is! String || value.isEmpty) {
            throw ConfigException(
              '"cube.config" must be a non-empty path, got $value',
            );
          }
          configPath = value;
        default:
          throw ConfigException('unknown "cube" key: $key');
      }
    }
    return CubeSettings(enabled: enabled, configPath: configPath);
  }

  /// Whether the saved cube applies at startup (explicit flags always win).
  final bool enabled;

  /// The default cube manifest — a path (anything containing `/`) or a bare
  /// name resolved under `<cwd>/.fah/cubes/<name>.yaml`. `null` = no
  /// default cube.
  final String? configPath;

  /// Serializes to the `cube:` yaml section (round-trips with
  /// [CubeSettings.fromYaml]); defaults are omitted.
  String toYamlFragment() {
    final buffer = StringBuffer('cube:\n');
    if (!enabled) buffer.write('  enabled: false\n');
    final path = configPath;
    if (path != null) buffer.write('  config: $path\n');
    return buffer.toString();
  }
}
