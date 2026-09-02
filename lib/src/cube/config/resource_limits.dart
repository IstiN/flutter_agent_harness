/// Resource limits for a cube (`spec.resources:`): cpu/memory/disk caps and
/// a wall-clock timeout.
///
/// ```yaml
/// spec:
///   resources:
///     limits: {cpu: "50%", memory: 512Mi, disk: 100Mi}
///     timeout: 3600s
/// ```
///
/// `cpu` is kept verbatim as a string (a fraction or percentage, interpreted
/// by the enforcing backend); `memory`/`disk` are parsed to bytes with
/// [parseSizeBytes]; `timeout` is parsed with [parseDurationSpec].
///
/// Size parsing ([parseSizeBytes]) accepts a plain integer (bytes) or an
/// integer plus a case-insensitive suffix: binary multiples `K`/`KiB`,
/// `M`/`Mi`/`MiB`, `G`/`GiB` (1024-based) and decimal `B`, `KB`, `MB`, `GB`
/// (1000-based).
///
/// Duration parsing ([parseDurationSpec]) accepts a single-unit spec:
/// `3600s`, `5m`, `24h` — compounds like `1h30m` are rejected.
///
/// The parse helpers throw [FormatException] on malformed input;
/// [CubeResourceLimits.fromYaml] catches it and rethrows [ConfigException]
/// naming the YAML field.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

final RegExp _sizePattern = RegExp(r'^(\d+)\s*([a-zA-Z]*)$');
final RegExp _durationPattern = RegExp(r'^(\d+)([smh])$');

/// The `spec.resources:` section: optional cpu string, byte limits and a
/// wall-clock timeout.
final class CubeResourceLimits {
  /// Creates limits; every field is optional (null = no limit).
  const CubeResourceLimits({
    this.cpu,
    this.memoryBytes,
    this.diskBytes,
    this.timeout,
  });

  /// CPU cap verbatim, e.g. `'50%'` (backend-interpreted).
  final String? cpu;

  /// Memory cap in bytes.
  final int? memoryBytes;

  /// Disk cap in bytes.
  final int? diskBytes;

  /// Wall-clock timeout for the whole run.
  final Duration? timeout;

  /// Parses the `spec.resources:` section. `null` (section absent) yields
  /// an empty limits object (no limits).
  factory CubeResourceLimits.fromYaml(Object? node) {
    if (node == null) return const CubeResourceLimits();
    if (node is! YamlMap) {
      throw ConfigException(
        'cube.spec.resources: must be a map with optional "limits"/'
        '"timeout", got ${node.runtimeType}',
      );
    }
    for (final key in node.keys) {
      if (key is! String || (key != 'limits' && key != 'timeout')) {
        throw ConfigException(
          'cube.spec.resources: unknown key "$key" — supported: limits, '
          'timeout',
        );
      }
    }
    final limits = node['limits'];
    if (limits != null) {
      if (limits is! YamlMap) {
        throw ConfigException(
          'cube.spec.resources.limits: must be a map with optional '
          '"cpu"/"memory"/"disk"',
        );
      }
      for (final key in limits.keys) {
        if (key is! String ||
            !const {'cpu', 'memory', 'disk'}.contains(key)) {
          throw ConfigException(
            'cube.spec.resources.limits: unknown key "$key" — supported: '
            'cpu, memory, disk',
          );
        }
      }
    }
    return CubeResourceLimits(
      cpu: _parseCpu(limits?['cpu']),
      memoryBytes: _parseBytes(limits?['memory'], 'memory'),
      diskBytes: _parseBytes(limits?['disk'], 'disk'),
      timeout: _parseTimeout(node['timeout']),
    );
  }

  static String? _parseCpu(Object? node) {
    if (node == null) return null;
    if (node is! String || node.trim().isEmpty) {
      throw const ConfigException(
        'cube.spec.resources.limits.cpu: must be a non-empty string '
        '(e.g. "50%")',
      );
    }
    return node.trim();
  }

  /// YAML bytes field: an int is already bytes; a string goes through
  /// [parseSizeBytes] (FormatException rethrown as [ConfigException]).
  static int? _parseBytes(Object? node, String field) {
    if (node == null) return null;
    if (node is int) return node;
    if (node is String) {
      try {
        return parseSizeBytes(node);
      } on FormatException catch (error) {
        throw ConfigException(
          'cube.spec.resources.limits.$field: ${error.message}',
        );
      }
    }
    throw ConfigException(
      'cube.spec.resources.limits.$field: must be an integer byte count or '
      'a size string (e.g. 512Mi), got $node',
    );
  }

  static Duration? _parseTimeout(Object? node) {
    if (node == null) return null;
    if (node is int) return Duration(seconds: node);
    if (node is String) {
      try {
        return parseDurationSpec(node);
      } on FormatException catch (error) {
        throw ConfigException('cube.spec.resources.timeout: ${error.message}');
      }
    }
    throw ConfigException(
      'cube.spec.resources.timeout: must be an integer seconds count or a '
      'duration string (e.g. 3600s), got $node',
    );
  }
}

/// Parses a size string to bytes: a plain integer (`'1024'`) is bytes;
/// binary suffixes `K`/`KiB`, `M`/`Mi`/`MiB`, `G`/`GiB` are 1024-based and
/// decimal `B`, `KB`, `MB`, `GB` are 1000-based (case-insensitive).
///
/// Throws [FormatException] on malformed input (non-integer magnitude,
/// unknown suffix, negative or empty string).
int parseSizeBytes(String raw) {
  final match = _sizePattern.firstMatch(raw.trim());
  if (match == null) {
    throw FormatException(
      'invalid size "$raw" — expected an integer byte count or a size like '
      '512Mi, 100MiB, 1GB',
    );
  }
  final magnitude = int.parse(match.group(1)!);
  final suffix = match.group(2)!.toUpperCase();
  const binary = 1024, decimal = 1000;
  final multiplier = switch (suffix) {
    '' || 'B' => 1,
    'K' || 'KIB' => binary,
    'KB' => decimal,
    'M' || 'MI' || 'MIB' => binary * binary,
    'MB' => decimal * decimal,
    'G' || 'GIB' => binary * binary * binary,
    'GB' => decimal * decimal * decimal,
    _ => throw FormatException(
      'unknown size suffix "$suffix" in "$raw" — supported: B, K/KiB, '
      'KB, M/Mi/MiB, MB, G/GiB, GB',
    ),
  };
  return magnitude * multiplier;
}

/// Parses a single-unit duration string — `'3600s'`, `'5m'`, `'24h'` — into
/// a [Duration]. Compounds (`'1h30m'`) and unknown units are rejected with
/// [FormatException].
Duration parseDurationSpec(String raw) {
  final match = _durationPattern.firstMatch(raw.trim());
  if (match == null) {
    throw FormatException(
      'invalid duration "$raw" — expected a single-unit spec like 3600s, '
      '5m or 24h',
    );
  }
  final amount = int.parse(match.group(1)!);
  return switch (match.group(2)!) {
    's' => Duration(seconds: amount),
    'm' => Duration(minutes: amount),
    _ => Duration(hours: amount),
  };
}
