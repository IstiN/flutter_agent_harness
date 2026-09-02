/// The cube manifest itself (`CubeSpec`): a declarative sandbox profile
/// parsed from a strict yaml document.
///
/// ```yaml
/// apiVersion: fa/v1          # required, exactly 'fa/v1'
/// kind: Cube                 # required, exactly 'Cube'
/// metadata:
///   name: web-scraper        # required, ^[a-z][a-z0-9-]*$
///   description: "..."       # optional
/// spec:
///   tools: ...
///   backend: policy           # optional, 'policy' (default) | 'kernel'
///   network: ...
///   filesystem: ...
///   env: ...
///   resources: ...
///   cache: ...
/// ```
///
/// Parsing is strict: any schema problem (wrong apiVersion/kind, bad name,
/// unknown keys at any level) throws [ConfigException] naming the YAML path.
/// A missing `spec:` section yields the safe defaults: deny-all tools,
/// deny-all network, workspace `/workspace`, empty env, no resource limits,
/// disabled cache.
///
/// [CubeSpec.toCanonicalMap] renders the whole spec as a stable
/// JSON-encodable map (sorted keys, sorted lists, durations as seconds) for
/// the content-addressed cache key.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

import 'cache_policy.dart';
import 'env_policy.dart';
import 'fs_policy.dart';
import 'network_policy.dart';
import 'resource_limits.dart';
import 'tool_policy.dart';

final RegExp _namePattern = RegExp(r'^[a-z][a-z0-9-]*$');

/// How a cube's commands are confined: `policy` (the Dart policy layers
/// only) or `kernel` (wrapped in the OS sandbox primitive of the host
/// platform — sandbox-exec on macOS, unshare on Linux).
enum CubeBackendMode {
  /// Dart policy layers only — the Phase 1 default.
  policy,

  /// OS kernel confinement for the host platform, on top of the Dart
  /// layers. Degrades to [policy] on a platform without an enforcing
  /// backend (e.g. Windows or web) rather than failing the run.
  kernel;

  /// Parses the `spec.backend:` label, throwing [ConfigException] on an
  /// unknown value.
  static CubeBackendMode parse(Object? node, String where) => switch (node) {
    null => policy,
    'policy' => policy,
    'kernel' => kernel,
    _ => throw ConfigException(
      '$where.backend: must be "policy" or "kernel", got $node',
    ),
  };
}

/// A parsed cube manifest: identity plus the five policy sections.
final class CubeSpec {
  /// Creates a spec; policies default to their safe values.
  const CubeSpec({
    required this.name,
    this.description,
    this.backend = CubeBackendMode.policy,
    this.tools = const CubeToolPolicy(),
    this.network = const CubeNetworkPolicy(),
    this.filesystem = const CubeFsPolicy(),
    this.env = const CubeEnvPolicy(),
    this.resources = const CubeResourceLimits(),
    this.cache = const CubeCachePolicy(),
  });

  /// Cube name, `^[a-z][a-z0-9-]*$` (enforced at parse).
  final String name;

  /// Optional human-readable description.
  final String? description;

  /// How commands are confined — Dart policy layers only, or wrapped in
  /// the host platform's kernel sandbox.
  final CubeBackendMode backend;

  /// Which command words may run.
  final CubeToolPolicy tools;

  /// Which hosts/ports may be reached.
  final CubeNetworkPolicy network;

  /// Which paths may be read or written.
  final CubeFsPolicy filesystem;

  /// Which environment variables the run sees.
  final CubeEnvPolicy env;

  /// Resource caps and timeout.
  final CubeResourceLimits resources;

  /// Cache behavior.
  final CubeCachePolicy cache;

  /// Parses a whole cube yaml document. [sourcePath] names the document in
  /// error messages (default `'cube'`).
  factory CubeSpec.fromYaml(Object? node, {String sourcePath = 'cube'}) {
    if (node is! YamlMap) {
      throw ConfigException(
        '$sourcePath: must be a yaml map, got ${node.runtimeType}',
      );
    }
    _checkKeys(node, const {
      'apiVersion',
      'kind',
      'metadata',
      'spec',
    }, sourcePath);
    final apiVersion = node['apiVersion'];
    if (apiVersion != 'fa/v1') {
      throw ConfigException(
        '$sourcePath.apiVersion: must be exactly "fa/v1", got $apiVersion',
      );
    }
    final kind = node['kind'];
    if (kind != 'Cube') {
      throw ConfigException(
        '$sourcePath.kind: must be exactly "Cube", got $kind',
      );
    }
    final metadata = node['metadata'];
    if (metadata is! YamlMap) {
      throw ConfigException(
        '$sourcePath.metadata: must be a map with a "name", '
        'got ${metadata.runtimeType}',
      );
    }
    _checkKeys(metadata, const {'name', 'description'}, '$sourcePath.metadata');
    final name = metadata['name'];
    if (name is! String || !_namePattern.hasMatch(name)) {
      throw ConfigException(
        '$sourcePath.metadata.name: must match ^[a-z][a-z0-9-]*\$, '
        'got $name',
      );
    }
    final description = metadata['description'];
    if (description != null && description is! String) {
      throw const ConfigException(
        'cube.metadata.description: must be a string',
      );
    }
    final spec = node['spec'];
    if (spec != null && spec is! YamlMap) {
      throw ConfigException(
        '$sourcePath.spec: must be a map, got ${spec.runtimeType}',
      );
    }
    _checkKeys(spec, const {
      'backend',
      'tools',
      'network',
      'filesystem',
      'env',
      'resources',
      'cache',
    }, '$sourcePath.spec');
    return CubeSpec(
      name: name,
      description: description,
      backend: CubeBackendMode.parse(spec?['backend'], '$sourcePath.spec'),
      tools: CubeToolPolicy.fromYaml(spec?['tools']),
      network: CubeNetworkPolicy.fromYaml(spec?['network']),
      filesystem: CubeFsPolicy.fromYaml(spec?['filesystem']),
      env: CubeEnvPolicy.fromYaml(spec?['env']),
      resources: CubeResourceLimits.fromYaml(spec?['resources']),
      cache: CubeCachePolicy.fromYaml(spec?['cache']),
    );
  }

  /// A stable, JSON-encodable canonical form of the whole spec: keys sorted
  /// at every level, lists sorted (semantically orderless), durations as
  /// seconds, `null` fields omitted. Two specs that parse to the same
  /// policy always produce an equal map — this is the content-addressed
  /// cache key input.
  Map<String, Object?> toCanonicalMap() {
    return {
      'apiVersion': 'fa/v1',
      'kind': 'Cube',
      'metadata': {
        if (description != null) 'description': description,
        'name': name,
      },
      'spec': {
        'backend': backend.name,
        'cache': {
          'enabled': cache.enabled,
          if (cache.paths.isNotEmpty) 'paths': [...cache.paths]..sort(),
          'restore': cache.restore,
          if (cache.ttl != null) 'ttl': cache.ttl!.inSeconds,
        },
        'env': [
          for (final variable in [...env.vars]..sort(_byName))
            switch (variable) {
              CubeEnvValue(:final name, :final value) => {
                'name': name,
                'value': value,
              },
              CubeEnvValueFrom(:final name, :final source) => {
                'name': name,
                'valueFrom': source,
              },
              CubeEnvHidden(:final name) => {'hidden': true, 'name': name},
            },
        ],
        'filesystem': {
          'mounts': [
            for (final mount in [...filesystem.mounts]..sort(_byPath))
              {'access': mount.access.label, 'path': mount.path},
          ],
          'workspace': filesystem.workspace,
        },
        'network': {
          'allow': [
            for (final rule in [...network.allow]..sort(_byHost))
              _canonicalRule(rule),
          ],
          'deny': [
            for (final rule in [...network.deny]..sort(_byHost))
              _canonicalRule(rule),
          ],
        },
        'resources': {
          if (resources.cpu != null) 'cpu': resources.cpu,
          if (resources.diskBytes != null) 'diskBytes': resources.diskBytes,
          if (resources.memoryBytes != null)
            'memoryBytes': resources.memoryBytes,
          if (resources.timeout != null)
            'timeout': resources.timeout!.inSeconds,
        },
        'tools': {
          'allow': [...tools.allow]..sort(),
          'deny': [...tools.deny]..sort(),
        },
      },
    };
  }

  static Map<String, Object?> _canonicalRule(CubeNetworkRule rule) {
    final ports = rule.ports;
    return {
      'host': rule.host,
      if (ports != null && ports.isNotEmpty) 'ports': ports.toList()..sort(),
    };
  }

  static int _byName(CubeEnvVar a, CubeEnvVar b) => a.name.compareTo(b.name);

  static int _byPath(CubeMount a, CubeMount b) => a.path.compareTo(b.path);

  static int _byHost(CubeNetworkRule a, CubeNetworkRule b) =>
      a.host.compareTo(b.host);

  static void _checkKeys(YamlMap? node, Set<String> allowed, String where) {
    for (final key in node?.keys ?? const Iterable<Object?>.empty()) {
      if (key is! String || !allowed.contains(key)) {
        throw ConfigException(
          '$where: unknown key "$key" — supported: ${allowed.join(', ')}',
        );
      }
    }
  }
}
