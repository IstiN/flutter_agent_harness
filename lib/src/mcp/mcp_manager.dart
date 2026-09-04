/// Server lifecycle management for MCP: one connection per configured
/// server, established lazily in the background at agent start (boot never
/// blocks), with reconnect-on-failure using capped exponential backoff (the
/// `LspClientManager` crash-respawn policy).
///
/// Per-server status (`connecting`/`connected`/`failed`) feeds the system
/// prompt section and the tool wrapper's not-connected note. When a
/// server's tool list changes (connect, reconnect, drop), [onChanged]
/// fires so the host re-registers [tools] into its `ToolRegistry` and
/// refreshes the agent's tool list.
///
/// Stdio servers need a process-capable host: without a
/// [McpTransportFactory] (web) they land in `failed` with a clean
/// "not supported" note, while remote (HTTP) servers still connect — both
/// HTTP transports are pure Dart.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../agent/agent_tool.dart';
import 'mcp_client.dart';
import 'mcp_config.dart';
import 'mcp_http_transport.dart';
import 'mcp_tool.dart';
import 'mcp_transport.dart';

/// Per-server lifecycle status.
enum McpServerStatus {
  /// A connect attempt is in flight.
  connecting,

  /// Handshake done, tools registered, calls may be sent.
  connected,

  /// The last connect attempt failed (or the connection dropped); a
  /// reconnect is scheduled.
  failed,
}

/// The live state of one configured server.
final class McpServerState {
  /// Creates a state snapshot.
  const McpServerState({
    required this.status,
    this.error,
    this.tools = const [],
  });

  /// Lifecycle status.
  final McpServerStatus status;

  /// Why the last attempt failed (status [McpServerStatus.failed]).
  final String? error;

  /// The tools advertised by the server (status
  /// [McpServerStatus.connected]).
  final List<McpToolInfo> tools;
}

/// Bundle enabling MCP for an agent session: the parsed config plus the
/// host capabilities. Mirrors `LspToolConfig`.
final class McpToolConfig {
  /// Creates an [McpToolConfig].
  const McpToolConfig({
    required this.config,
    this.transportFactory,
    this.httpClient,
  });

  /// The parsed `mcp:` config section.
  final McpConfig config;

  /// Spawns stdio servers (the io-side factory lives in `lib/io.dart`).
  /// Null on hosts without process support (web): stdio servers then report
  /// a clean "not supported" status while remote servers still connect.
  final McpTransportFactory? transportFactory;

  /// HTTP client for remote servers (tests inject `MockClient`s). Null
  /// creates a default `package:http` client per connection.
  final http.Client? httpClient;
}

/// Owns the [McpClient] pool and the dynamic MCP tool surface.
final class McpManager {
  /// Creates an [McpManager]. [cwd] is the working directory stdio servers
  /// are spawned in (the agent's `ExecutionEnv.cwd`).
  McpManager({
    required this.config,
    required this.cwd,
    this.transportFactory,
    this.httpClient,
    this.onChanged,
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 30),
  });

  /// The resolved MCP configuration.
  final McpConfig config;

  /// Working directory for stdio servers.
  final String cwd;

  /// Spawns stdio server processes; null on process-less hosts.
  final McpTransportFactory? transportFactory;

  /// HTTP client for remote servers.
  final http.Client? httpClient;

  /// Fires whenever [tools] or [states] change (connect, failure,
  /// reconnect) so the host can re-register tools and rebuild the prompt.
  void Function()? onChanged;

  /// First reconnect delay (doubles per consecutive failure).
  final Duration reconnectBaseDelay;

  /// Cap on the reconnect backoff.
  final Duration reconnectMaxDelay;

  final _states = <String, McpServerState>{};
  final _clients = <String, McpClient>{};
  final _tools = <String, List<AgentTool>>{};
  bool _disposed = false;
  bool _started = false;

  /// Server name → live state, in config order.
  Map<String, McpServerState> get states => Map.unmodifiable(_states);

  /// The currently registered MCP tools (connected servers only).
  /// Duplicate sanitized names are dropped first-wins — registration into a
  /// `ToolRegistry` must never throw on a collision.
  List<AgentTool> get tools {
    final seen = <String>{};
    return [
      for (final serverTools in _tools.values)
        for (final tool in serverTools)
          if (seen.add(tool.name)) tool,
    ];
  }

  /// The per-server tool lists (connected servers only), server name →
  /// tools in registration order. Unmodifiable deep view: the availability
  /// wiring re-registers or unregisters a whole server from here without
  /// touching the manager's own state.
  Map<String, List<AgentTool>> get toolsByServer {
    final copy = <String, List<AgentTool>>{
      for (final entry in _tools.entries)
        entry.key: List<AgentTool>.unmodifiable(entry.value),
    };
    return Map.unmodifiable(copy);
  }

  /// Starts background connect loops for every configured server. Returns
  /// immediately; progress surfaces through [states] and [onChanged].
  void start() {
    if (_started || _disposed) return;
    _started = true;
    for (final server in config.servers.values) {
      unawaited(_runServer(server));
    }
  }

  Future<void> _runServer(McpServerConfig server) async {
    var failures = 0;
    while (!_disposed) {
      _setState(
        server.name,
        const McpServerState(status: McpServerStatus.connecting),
      );
      final stopwatch = Stopwatch()..start();
      try {
        final transport = await _openTransport(server);
        final client = McpClient(
          serverName: server.name,
          transport: transport,
          requestTimeout: config.toolCallTimeout,
        );
        await client.initialize();
        final tools = await client.listTools();
        if (_disposed) {
          await client.close();
          return;
        }
        _clients[server.name] = client;
        _tools[server.name] = [
          for (final tool in tools)
            mcpAgentTool(server: server.name, tool: tool, caller: callTool),
        ];
        _setState(
          server.name,
          McpServerState(status: McpServerStatus.connected, tools: tools),
        );
        failures = 0;
        await client.closed; // returns when the connection drops
        if (_disposed) return;
        _dropServer(server.name, 'connection lost');
      } on Object catch (error) {
        if (_disposed) return;
        _dropServer(server.name, '$error');
      }
      failures += 1;
      final delay = _backoff(failures);
      // A failure faster than the backoff delay keeps the clock honest:
      // servers that die instantly don't spin the event loop.
      final elapsed = stopwatch.elapsed;
      final wait = delay > elapsed ? delay - elapsed : Duration.zero;
      await Future<void>.delayed(wait);
    }
  }

  Future<McpTransport> _openTransport(McpServerConfig server) {
    return switch (server) {
      McpStdioServerConfig() =>
        transportFactory?.call(server, cwd) ??
            Future.error(
              const McpServerUnavailableException(
                'stdio MCP servers are not supported on this host',
              ),
            ),
      McpHttpServerConfig() => httpMcpTransport(server, client: httpClient),
    };
  }

  void _dropServer(String name, String error) {
    unawaited(_clients.remove(name)?.close());
    _tools.remove(name);
    _setState(
      name,
      McpServerState(status: McpServerStatus.failed, error: error),
    );
  }

  Duration _backoff(int failures) {
    var ms =
        reconnectBaseDelay.inMilliseconds * (1 << (failures - 1).clamp(0, 20));
    if (ms > reconnectMaxDelay.inMilliseconds) {
      ms = reconnectMaxDelay.inMilliseconds;
    }
    return Duration(milliseconds: ms);
  }

  void _setState(String name, McpServerState state) {
    if (_disposed) return;
    _states[name] = state;
    onChanged?.call();
  }

  /// Routes one `tools/call` to the server. Throws [StateError] with an
  /// actionable message when the server is not connected; server-side and
  /// timeout failures surface as [McpRequestException].
  Future<Map<String, dynamic>> callTool(
    String server,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final client = _clients[server];
    if (client == null || client.status != McpClientStatus.ready) {
      final state = _states[server];
      final detail = state?.error ?? 'still connecting';
      throw StateError(
        'MCP server "$server" is not connected ($detail). It reconnects '
        'automatically — try again shortly.',
      );
    }
    try {
      return await client.callTool(tool, arguments);
    } on McpRequestException catch (error) {
      throw StateError(error.message);
    }
  }

  /// The system-prompt section listing every configured server and its
  /// status (empty when no servers are configured, and servers rejected by
  /// [includeServer] are omitted — the availability gate's per-server
  /// decision). Kept tiny: one line per server.
  String promptSection({bool Function(String server)? includeServer}) {
    if (config.servers.isEmpty) return '';
    final lines = <String>['## MCP servers', ''];
    for (final name in config.servers.keys) {
      if (includeServer != null && !includeServer(name)) continue;
      final state = _states[name];
      lines.add(switch (state?.status) {
        McpServerStatus.connected =>
          '- `$name` (connected): ${state!.tools.length} tool(s), '
              'registered as `mcp__${name}__*`',
        McpServerStatus.failed =>
          '- `$name` (failed: ${state!.error ?? 'unknown'}) — '
              'reconnect is automatic; its tools are unavailable meanwhile',
        McpServerStatus.connecting || null => '- `$name` (connecting…)',
      });
    }
    return lines.length <= 2 ? '' : lines.join('\n');
  }

  /// Closes every client and stops reconnecting. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final client in _clients.values) {
      await client.close();
    }
    _clients.clear();
    _tools.clear();
  }
}
