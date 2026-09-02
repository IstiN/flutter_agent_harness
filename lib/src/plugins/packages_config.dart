/// The `.fah/packages.yaml` loader: plugin name -> config section, shared
/// by the executable's plugin resolution and the settings-hub DAP / Hub
/// flow's snapshot seam.
///
/// Reads through the [ExecutionEnv] (lib/ stays dart:io-free). The parsed
/// yaml tree is converted to plain Dart values (YamlMap → Map, YamlScalar
/// → value): package:yaml 3.x reifies its map entries as dynamic-keyed, so
/// a naive String-keyed `whereType` filter dropped EVERY entry (the file
/// was inert), and nested YamlMap/YamlScalar wrappers fail the
/// `is Map<String, dynamic>` / `is String` checks the plugin configs rely
/// on.
///
/// A missing file counts as absent (`{}`); an unreadable or unparseable
/// file throws [ConfigException] — the executable fails hard on it.
library;

import 'package:yaml/yaml.dart' as yaml;

import '../env/execution_env.dart';
import '../exceptions.dart';

/// Loads plugin configuration from the environment cwd's
/// `.fah/packages.yaml`. Returns a map of plugin name -> config.
Future<Map<String, dynamic>> loadPackagesConfig(ExecutionEnv env) async {
  final String source;
  switch (await env.readTextFile('${env.cwd}/.fah/packages.yaml')) {
    case Ok(:final value):
      source = value;
    case Err(:final error) when error.code == FileErrorCode.notFound:
      return const {};
    case Err(:final error):
      throw ConfigException('failed to parse .fah/packages.yaml: $error');
  }
  try {
    final doc = yaml.loadYaml(source);
    if (doc is! Map) return const {};
    return Map<String, dynamic>.from(
      doc,
    ).map((name, value) => MapEntry(name, _plainYaml(value)));
  } on Object catch (error) {
    throw ConfigException('failed to parse .fah/packages.yaml: $error');
  }
}

/// Converts a parsed yaml node into plain Dart values, recursively.
Object? _plainYaml(Object? node) => switch (node) {
  yaml.YamlMap() => {
    for (final entry in node.entries)
      entry.key.toString(): _plainYaml(entry.value),
  },
  yaml.YamlList() => [for (final item in node) _plainYaml(item)],
  yaml.YamlScalar() => node.value,
  _ => node,
};
