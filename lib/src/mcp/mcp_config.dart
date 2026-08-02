/// Configuration for MCP (Model Context Protocol) servers: the `mcp:`
/// section of `~/.fah/config.yaml`.
///
/// Two server shapes are supported, mirroring the kimi-cli reference:
///
/// ```yaml
/// mcp:
///   toolCallTimeoutMs: 60000   # optional, default 60000
///   servers:
///     filesystem:              # stdio server
///       command: npx
///       args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
///       env: {FOO: bar}        # optional extra environment
///     remote:                  # HTTP server
///       url: https://example.com/mcp
///       transport: streamable-http   # or sse (default: streamable-http)
///       headers: {Authorization: Bearer x}
/// ```
///
/// Parsing is strict like the other config sections (see
/// `lib/src/model_roles/roles_config.dart`): any schema problem throws
/// [ConfigException] so a broken MCP section surfaces instead of silently
/// disabling servers.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// The remote transport spoken by an [McpHttpServerConfig].
enum McpHttpTransportKind {
  /// The current streamable-HTTP transport: one endpoint, POST per message,
  /// `text/event-stream` responses accepted.
  streamableHttp('streamable-http'),

  /// The legacy HTTP+SSE transport (GET stream + `endpoint` event + POSTs).
  sse('sse');

  const McpHttpTransportKind(this.label);

  /// The config-file label.
  final String label;

  /// Parses [label], throwing [ConfigException] on an unknown transport.
  static McpHttpTransportKind parse(String label, {required String server}) {
    for (final kind in values) {
      if (kind.label == label) return kind;
    }
    throw ConfigException(
      'mcp.servers.$server: unknown transport "$label" — supported: '
      '${values.map((kind) => kind.label).join(', ')}',
    );
  }
}

/// One configured MCP server. Sealed: either a stdio process
/// ([McpStdioServerConfig]) or a remote HTTP endpoint
/// ([McpHttpServerConfig]).
sealed class McpServerConfig {
  const McpServerConfig({required this.name});

  /// The server name (the `mcp.servers` key).
  final String name;

  /// Parses one `mcp.servers.<name>` entry: a map with either `command`
  /// (stdio) or `url` (remote). Having both or neither is a schema error.
  factory McpServerConfig.fromYaml(String name, Object? node) {
    if (name.trim().isEmpty) {
      throw const ConfigException(
        'mcp.servers: server names must be non-empty',
      );
    }
    if (node is! YamlMap) {
      throw ConfigException(
        'mcp.servers.$name must be a map with "command" (stdio) or "url" '
        '(remote), got ${node.runtimeType}',
      );
    }
    final command = node['command'];
    final url = node['url'];
    if (command != null && url != null) {
      throw ConfigException(
        'mcp.servers.$name must not mix "command" (stdio) and "url" (remote)',
      );
    }
    if (command != null) {
      if (command is! String || command.trim().isEmpty) {
        throw ConfigException(
          'mcp.servers.$name.command must be a non-empty string',
        );
      }
      return McpStdioServerConfig(
        name: name,
        command: command.trim(),
        args: _stringList(node['args'], 'mcp.servers.$name.args'),
        env: _stringMap(node['env'], 'mcp.servers.$name.env'),
      );
    }
    if (url is! String || url.trim().isEmpty) {
      throw ConfigException(
        'mcp.servers.$name requires a non-empty "command" (stdio) or "url" '
        '(remote) string',
      );
    }
    final transportLabel = node['transport'];
    if (transportLabel != null && transportLabel is! String) {
      throw ConfigException('mcp.servers.$name.transport must be a string');
    }
    return McpHttpServerConfig(
      name: name,
      url: url.trim(),
      transport: transportLabel == null
          ? McpHttpTransportKind.streamableHttp
          : McpHttpTransportKind.parse(transportLabel, server: name),
      headers: _stringMap(node['headers'], 'mcp.servers.$name.headers'),
    );
  }

  static List<String> _stringList(Object? node, String where) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw ConfigException('$where must be a list of strings');
    }
    return [
      for (final entry in node)
        entry is String
            ? entry
            : throw ConfigException('$where entries must be strings'),
    ];
  }

  static Map<String, String> _stringMap(Object? node, String where) {
    if (node == null) return const {};
    if (node is! YamlMap) {
      throw ConfigException('$where must be a map of string to string');
    }
    final out = <String, String>{};
    for (final entry in node.entries) {
      if (entry.key is! String) {
        throw ConfigException('$where keys must be strings');
      }
      out[entry.key as String] = '${entry.value}';
    }
    return out;
  }

  /// Serializes this server's yaml body (without the name key).
  String _bodyToYaml();
}

/// A stdio MCP server: a spawned process speaking newline-delimited
/// JSON-RPC over stdin/stdout.
final class McpStdioServerConfig extends McpServerConfig {
  /// Creates a stdio server config.
  const McpStdioServerConfig({
    required super.name,
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  /// The executable to spawn.
  final String command;

  /// Arguments for [command].
  final List<String> args;

  /// Extra environment variables (merged over the inherited environment).
  final Map<String, String> env;

  @override
  String _bodyToYaml() {
    final buffer = StringBuffer()
      ..write('command: ${jsonEncode(command)}\n')
      ..write('args: ${jsonEncode(args)}\n');
    if (env.isNotEmpty) buffer.write('env: ${jsonEncode(env)}\n');
    return buffer.toString();
  }
}

/// A remote MCP server reached over HTTP.
final class McpHttpServerConfig extends McpServerConfig {
  /// Creates a remote server config.
  const McpHttpServerConfig({
    required super.name,
    required this.url,
    this.transport = McpHttpTransportKind.streamableHttp,
    this.headers = const {},
  });

  /// The MCP endpoint URL.
  final String url;

  /// The wire transport (streamable HTTP or legacy SSE).
  final McpHttpTransportKind transport;

  /// Extra HTTP headers (e.g. `Authorization`).
  final Map<String, String> headers;

  @override
  String _bodyToYaml() {
    final buffer = StringBuffer()
      ..write('url: ${jsonEncode(url)}\n')
      ..write('transport: ${transport.label}\n');
    if (headers.isNotEmpty) buffer.write('headers: ${jsonEncode(headers)}\n');
    return buffer.toString();
  }
}

/// The `mcp:` config section: the server map plus the tool-call timeout.
final class McpConfig {
  /// Creates an [McpConfig]; [servers] maps server name to its config.
  McpConfig({
    required Map<String, McpServerConfig> servers,
    this.toolCallTimeout = const Duration(seconds: 60),
  }) : servers = Map.unmodifiable(servers);

  /// Parses the `mcp:` section. Strict: schema errors throw
  /// [ConfigException].
  factory McpConfig.fromYaml(Object? node) {
    if (node is! YamlMap) {
      throw ConfigException(
        '"mcp" must be a map of MCP settings, got ${node.runtimeType}',
      );
    }
    final timeoutNode = node['toolCallTimeoutMs'];
    if (timeoutNode != null && (timeoutNode is! int || timeoutNode <= 0)) {
      throw const ConfigException(
        '"mcp.toolCallTimeoutMs" must be a positive integer',
      );
    }
    final serversNode = node['servers'];
    if (serversNode == null) {
      throw const ConfigException('no "servers" in the "mcp" section');
    }
    if (serversNode is! YamlMap) {
      throw const ConfigException('"mcp.servers" must be a map');
    }
    final servers = <String, McpServerConfig>{};
    for (final entry in serversNode.entries) {
      if (entry.key is! String) {
        throw const ConfigException('mcp.servers keys must be strings');
      }
      servers[entry.key as String] = McpServerConfig.fromYaml(
        entry.key as String,
        entry.value,
      );
    }
    return McpConfig(
      toolCallTimeout: timeoutNode == null
          ? const Duration(seconds: 60)
          : Duration(milliseconds: timeoutNode),
      servers: servers,
    );
  }

  /// Server name → server config.
  final Map<String, McpServerConfig> servers;

  /// Default timeout for one `tools/call` request.
  final Duration toolCallTimeout;

  /// Whether no servers are configured.
  bool get isEmpty => servers.isEmpty;

  /// Serializes to the `mcp:` yaml section (round-trips with
  /// [McpConfig.fromYaml]).
  String toYaml() {
    final buffer = StringBuffer()
      ..write('mcp:\n')
      ..write('  toolCallTimeoutMs: ${toolCallTimeout.inMilliseconds}\n')
      ..write('  servers:\n');
    for (final server in servers.values) {
      buffer.write('    ${server.name}:\n');
      for (final line in server._bodyToYaml().trimRight().split('\n')) {
        buffer.write('      $line\n');
      }
    }
    return buffer.toString();
  }
}
