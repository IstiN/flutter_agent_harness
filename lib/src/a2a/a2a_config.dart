/// Configuration for A2A (Agent2Agent) remote agents: the `a2a:` section of
/// `~/.fah/config.yaml`.
///
/// ```yaml
/// a2a:
///   servers:
///     translator:
///       url: https://agents.example.com/translator
///       token: ${A2A_TRANSLATOR_KEY}   # env-resolved, never a literal
/// ```
///
/// Parsing is strict like the other config sections: any schema problem
/// throws [ConfigException] so a broken section surfaces instead of silently
/// disabling the agents.
library;

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// One remote A2A agent endpoint.
final class A2aServerConfig {
  /// Creates a config entry.
  const A2aServerConfig({required this.name, required this.url, this.token});

  /// Parses one `a2a.servers.<name>` entry. [envVarValue] resolves
  /// `${NAME}` token references against the environment.
  factory A2aServerConfig.fromYaml(
    String name,
    Object? node,
    String? Function(String name) envVarValue,
  ) {
    if (node is! YamlMap) {
      throw ConfigException(
        'a2a.servers.$name must be a map, got ${node.runtimeType}',
      );
    }
    final url = node['url'];
    if (url is! String || url.isEmpty) {
      throw const ConfigException('a2a server entries need a string "url"');
    }
    var token = node['token'] as String?;
    if (token != null) {
      final match = RegExp(
        r'^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$',
      ).firstMatch(token);
      if (match != null) {
        token = envVarValue(match.group(1)!);
        if (token == null || token.isEmpty) {
          throw ConfigException(
            'a2a.servers.$name.token references unset env '
            '"${match.group(1)}"',
          );
        }
      }
    }
    return A2aServerConfig(name: name, url: url, token: token);
  }

  /// The config key (server name).
  final String name;

  /// The agent's base URL (JSON-RPC endpoint; the card lives at
  /// `<url>/.well-known/agent.json`).
  final String url;

  /// Bearer token (env-resolved at parse time), or null for tokenless
  /// agents.
  final String? token;
}

/// The `a2a:` config section.
final class A2aConfig {
  /// Creates an [A2aConfig]; [servers] maps agent name to its endpoint.
  A2aConfig({required Map<String, A2aServerConfig> servers})
    : servers = Map.unmodifiable(servers);

  /// Parses the `a2a:` section. Strict: schema errors throw
  /// [ConfigException].
  factory A2aConfig.fromYaml(
    Object? node,
    String? Function(String name) envVarValue,
  ) {
    if (node is! YamlMap) {
      throw ConfigException(
        '"a2a" must be a map of A2A settings, got ${node.runtimeType}',
      );
    }
    final serversNode = node['servers'];
    if (serversNode == null) {
      throw const ConfigException('no "servers" in the "a2a" section');
    }
    if (serversNode is! YamlMap) {
      throw const ConfigException('"a2a.servers" must be a map');
    }
    final servers = <String, A2aServerConfig>{};
    for (final entry in serversNode.entries) {
      if (entry.key is! String) {
        throw const ConfigException('a2a.servers keys must be strings');
      }
      servers[entry.key as String] = A2aServerConfig.fromYaml(
        entry.key as String,
        entry.value,
        envVarValue,
      );
    }
    return A2aConfig(servers: servers);
  }

  /// Agent name → endpoint config.
  final Map<String, A2aServerConfig> servers;
}
