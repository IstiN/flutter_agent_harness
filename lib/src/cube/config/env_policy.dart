/// Environment policy for a cube (`spec.env:`): which environment variables
/// a sandboxed run sees.
///
/// ```yaml
/// spec:
///   env:
///     - {name: FAH_MODE, value: sandboxed}
///     - {name: SCRAPER_KEY, valueFrom: "env:API_KEY"}   # host env at apply()
///     - {name: HOME, hidden: true}
/// ```
///
/// [CubeEnvPolicy.apply] builds the child environment:
///
/// - An empty policy passes the host environment through unchanged.
/// - A non-empty policy starts from a **clean environment**: only `PATH`,
///   `HOME` and `TMPDIR` survive from the host (the minimum trio needed to
///   run anything) — each dropped when explicitly hidden or overridden.
/// - Declared vars are then injected: a literal [CubeEnvValue], a
///   [CubeEnvValueFrom] resolved from the host env at `apply()` time
///   (a missing source variable is simply absent), or [CubeEnvHidden] which
///   never appears in the result.
///
/// Parsing is strict: any schema problem throws [ConfigException] naming the
/// YAML path.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

/// One declared environment variable. Sealed: a literal [CubeEnvValue], a
/// host-resolved [CubeEnvValueFrom], or a removed [CubeEnvHidden].
sealed class CubeEnvVar {
  const CubeEnvVar({required this.name});

  /// The variable name (e.g. `FAH_MODE`).
  final String name;
}

/// A variable with a literal value.
final class CubeEnvValue extends CubeEnvVar {
  /// Creates a literal variable.
  const CubeEnvValue({required super.name, required this.value});

  /// The literal value injected into the child environment.
  final String value;
}

/// A variable resolved from the host environment at [CubeEnvPolicy.apply]
/// time. [source] has the form `env:NAME`.
final class CubeEnvValueFrom extends CubeEnvVar {
  /// Creates a resolved variable; [source] must start with `env:`.
  const CubeEnvValueFrom({required super.name, required this.source});

  /// The host-env source reference, `env:NAME`.
  final String source;
}

/// A variable explicitly removed from the child environment (e.g. `HOME`).
final class CubeEnvHidden extends CubeEnvVar {
  /// Creates a hidden variable.
  const CubeEnvHidden({required super.name});
}

/// The `spec.env:` section: the ordered variable list.
final class CubeEnvPolicy {
  /// The host variables a non-empty policy keeps by default.
  static const _cleanTrio = {'PATH', 'HOME', 'TMPDIR'};

  /// Creates a policy from declared variables.
  const CubeEnvPolicy({this.vars = const []});

  /// Declared variables, in yaml order.
  final List<CubeEnvVar> vars;

  /// Parses the `spec.env:` section. `null` (section absent) yields the
  /// empty policy: host environment passed through unchanged.
  factory CubeEnvPolicy.fromYaml(Object? node) {
    if (node == null) return const CubeEnvPolicy();
    if (node is! YamlList) {
      throw ConfigException(
        'cube.spec.env: must be a list of variable maps, '
        'got ${node.runtimeType}',
      );
    }
    final vars = <CubeEnvVar>[];
    final names = <String>{};
    for (final (index, entry) in node.indexed) {
      final variable = _parseVar(entry, 'cube.spec.env[$index]');
      if (!names.add(variable.name)) {
        throw ConfigException(
          'cube.spec.env: duplicate variable "${variable.name}"',
        );
      }
      vars.add(variable);
    }
    return CubeEnvPolicy(vars: List.unmodifiable(vars));
  }

  /// Whether no variables are declared (host env passes through).
  bool get isEmpty => vars.isEmpty;

  /// Builds the child environment from [hostEnv] per the class
  /// documentation. Returns [hostEnv] itself for an empty policy.
  Map<String, String> apply(Map<String, String> hostEnv) {
    if (vars.isEmpty) return hostEnv;
    final hidden = {
      for (final variable in vars)
        if (variable is CubeEnvHidden) variable.name,
    };
    final result = <String, String>{
      for (final entry in hostEnv.entries)
        if (_cleanTrio.contains(entry.key) && !hidden.contains(entry.key))
          entry.key: entry.value,
    };
    for (final variable in vars) {
      switch (variable) {
        case CubeEnvValue(:final name, :final value):
          result[name] = value;
        case CubeEnvValueFrom(:final name, :final source):
          final resolved = hostEnv[source.substring('env:'.length)];
          if (resolved != null) result[name] = resolved;
        case CubeEnvHidden(:final name):
          result.remove(name); // no-op: hidden vars never enter the trio
      }
    }
    return result;
  }

  static CubeEnvVar _parseVar(Object? node, String where) {
    if (node is! YamlMap) {
      throw ConfigException(
        '$where: must be a map with "name" and one of '
        '"value"/"valueFrom"/"hidden"',
      );
    }
    _checkVarKeys(node, where);
    final name = _parseVarName(node, where);
    final shapes = _declaredVarShapes(node);
    if (shapes.length != 1) {
      throw ConfigException(
        '$where: exactly one of "value"/"valueFrom"/"hidden" is required '
        '(got ${shapes.isEmpty ? 'none' : shapes.join(', ')})',
      );
    }
    return switch (shapes.single) {
      'value' => _parseVarValue(node, name, where),
      'valueFrom' => _parseVarValueFrom(node, name, where),
      _ => _parseVarHidden(node, name, where),
    };
  }

  /// Rejects keys outside the `{name, value, valueFrom, hidden}` schema.
  static void _checkVarKeys(YamlMap node, String where) {
    const supported = {'name', 'value', 'valueFrom', 'hidden'};
    for (final key in node.keys) {
      if (key is! String || !supported.contains(key)) {
        throw ConfigException(
          '$where: unknown key "$key" — supported: name, value, valueFrom, '
          'hidden',
        );
      }
    }
  }

  /// The trimmed variable name; must be a non-empty string.
  static String _parseVarName(YamlMap node, String where) {
    final name = node['name'];
    if (name is! String || name.trim().isEmpty) {
      throw ConfigException('$where.name: must be a non-empty string');
    }
    return name.trim();
  }

  /// The value/valueFrom/hidden keys the var declares, in schema order.
  static List<String> _declaredVarShapes(YamlMap node) => [
    if (node['value'] != null) 'value',
    if (node['valueFrom'] != null) 'valueFrom',
    if (node['hidden'] != null) 'hidden',
  ];

  /// Parses the `value:` shape: a literal string.
  static CubeEnvVar _parseVarValue(YamlMap node, String name, String where) {
    final value = node['value'];
    if (value is! String) {
      throw ConfigException('$where.value: must be a string');
    }
    return CubeEnvValue(name: name, value: value);
  }

  /// Parses the `valueFrom:` shape: a non-empty `env:NAME` reference.
  static CubeEnvVar _parseVarValueFrom(
    YamlMap node,
    String name,
    String where,
  ) {
    final valueFrom = node['valueFrom'];
    if (valueFrom is! String || !valueFrom.startsWith('env:')) {
      throw ConfigException(
        '$where.valueFrom: must be a string of the form "env:NAME", '
        'got $valueFrom',
      );
    }
    if (valueFrom.length <= 'env:'.length) {
      throw ConfigException('$where.valueFrom: source name is empty');
    }
    return CubeEnvValueFrom(name: name, source: valueFrom);
  }

  /// Parses the `hidden:` shape: a boolean.
  static CubeEnvVar _parseVarHidden(YamlMap node, String name, String where) {
    final hidden = node['hidden'];
    if (hidden is! bool) {
      throw ConfigException('$where.hidden: must be a boolean');
    }
    return CubeEnvHidden(name: name);
  }
}
