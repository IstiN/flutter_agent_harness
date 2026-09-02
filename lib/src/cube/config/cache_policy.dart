/// Cache policy for a cube (`spec.cache:`): reusable cache directories for
/// sandboxed runs.
///
/// ```yaml
/// spec:
///   cache:
///     enabled: true              # default true when the section is present
///     paths: [/workspace/.cache] # cube-relative cache paths
///     restore: true              # default true
///     ttl: 24h                   # optional Duration (single-unit spec)
/// ```
///
/// When the `cache:` section is absent entirely, caching is disabled
/// ([CubeCachePolicy.enabled] `false`). When it is present, `enabled` and
/// `restore` default to `true`.
///
/// Parsing is strict: any schema problem throws [ConfigException] naming the
/// YAML path.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

import 'resource_limits.dart';

/// The `spec.cache:` section of a cube.
final class CubeCachePolicy {
  /// Creates a policy.
  const CubeCachePolicy({
    this.enabled = false,
    this.paths = const [],
    this.restore = true,
    this.ttl,
  });

  /// Whether caching applies to runs of this cube.
  final bool enabled;

  /// Cube-relative cache directory paths.
  final List<String> paths;

  /// Whether caches are restored into a fresh sandbox before the run.
  final bool restore;

  /// Cache entry lifetime; `null` = no expiry.
  final Duration? ttl;

  /// Parses the `spec.cache:` section. `null` (section absent) yields the
  /// disabled default.
  factory CubeCachePolicy.fromYaml(Object? node) {
    if (node == null) {
      return const CubeCachePolicy();
    }
    if (node is! YamlMap) {
      throw ConfigException(
        'cube.spec.cache: must be a map with optional "enabled"/"paths"/'
        '"restore"/"ttl", got ${node.runtimeType}',
      );
    }
    for (final key in node.keys) {
      if (key is! String ||
          !const {'enabled', 'paths', 'restore', 'ttl'}.contains(key)) {
        throw ConfigException(
          'cube.spec.cache: unknown key "$key" — supported: enabled, paths, '
          'restore, ttl',
        );
      }
    }
    final enabled = node['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const ConfigException('cube.spec.cache.enabled: must be a boolean');
    }
    final restore = node['restore'];
    if (restore != null && restore is! bool) {
      throw const ConfigException('cube.spec.cache.restore: must be a boolean');
    }
    final ttlNode = node['ttl'];
    Duration? ttl;
    if (ttlNode != null) {
      if (ttlNode is! String) {
        throw const ConfigException(
          'cube.spec.cache.ttl: must be a duration string like 24h',
        );
      }
      try {
        ttl = parseDurationSpec(ttlNode);
      } on FormatException catch (error) {
        throw ConfigException('cube.spec.cache.ttl: ${error.message}');
      }
    }
    return CubeCachePolicy(
      enabled: enabled ?? true, // section present => caching defaults on
      paths: _parsePaths(node['paths']),
      restore: restore ?? true,
      ttl: ttl,
    );
  }

  static List<String> _parsePaths(Object? node) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw const ConfigException(
        'cube.spec.cache.paths: must be a list of path strings',
      );
    }
    return [
      for (final path in node)
        path is String && path.trim().isNotEmpty
            ? path.trim()
            : throw const ConfigException(
                'cube.spec.cache.paths: entries must be non-empty strings',
              ),
    ];
  }
}
