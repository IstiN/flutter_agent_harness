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

  /// The resolved MCP configuration. Updated in place by [applyConfig]
  /// (the settings flow's live reload, issue #396) so the prompt section
  /// and the `/mcp reload` change check always reflect the servers
  /// actually connected.
  McpConfig config;

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

  /// Server names whose reconnect loop must exit at its next checkpoint —
  /// the live single-server reload ([applyConfig], issue #396). The loop
  /// consumes its own name and exits without touching state.
  final _stops = <String>{};

  /// Unblocks a server's backoff sleep when its loop is stopped mid-wait,
  /// so an edit applies now instead of after up to [reconnectMaxDelay].
  final _wakes = <String, Completer<void>>{};

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
      if (_takeStop(server.name)) return;
      _setState(
        server.name,
        const McpServerState(status: McpServerStatus.connecting),
      );
      final stopwatch = Stopwatch()..start();
      final error = await _connectAndServe(server);
      if (_disposed || _takeStop(server.name)) return;
      _dropServer(server.name, error?.toString() ?? 'connection lost');
      if (error == null) failures = 0;
      failures += 1;
      final delay = _backoff(failures);
      // A failure faster than the backoff delay keeps the clock honest:
      // servers that die instantly don't spin the event loop.
      final elapsed = stopwatch.elapsed;
      final wait = delay > elapsed ? delay - elapsed : Duration.zero;
      await _backoffWait(server.name, wait);
    }
  }

  /// One connect → serve cycle: resolves with the thrown failure when
  /// the connect, handshake, or tool listing fails, or null once the
  /// connection ends (crash or clean close — the caller drops either
  /// way). A stop ([_stops]) or disposal closes the client and resolves
  /// with null; the caller's stop checkpoint then exits without touching
  /// state, so the replacement loop's state stands.
  Future<Object?> _connectAndServe(McpServerConfig server) async {
    try {
      final transport = await _openTransport(server);
      final client = McpClient(
        serverName: server.name,
        transport: transport,
        requestTimeout: config.toolCallTimeout,
      );
      await client.initialize();
      final tools = await client.listTools();
      if (_disposed || _stops.contains(server.name)) {
        await client.close();
        return null;
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
      await client.closed; // returns when the connection drops
      return null;
    } on Object catch (error) {
      return error;
    }
  }

  /// Consumes a pending stop for [name] (true = the loop must exit now).
  bool _takeStop(String name) => _stops.remove(name);

  /// Sleeps [wait], cut short when [name] is stopped — a live reload must
  /// not wait out a backoff that can reach [reconnectMaxDelay].
  Future<void> _backoffWait(String name, Duration wait) {
    if (wait <= Duration.zero) return Future<void>.value();
    final wake = _wakes.putIfAbsent(name, Completer<void>.new);
    return Future.any([Future<void>.delayed(wait), wake.future]).then((_) {
      if (_wakes[name] == wake) _wakes.remove(name);
    });
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

  /// Live config reload (issue #396): diffs [next] against the current
  /// section and reconnects ONLY the touched servers — an entry that is
  /// value-equal keeps its live connection. Removed servers stop; added
  /// and changed ones start fresh loops; a tool-call-timeout change
  /// restarts every server (existing clients hold the timeout they were
  /// built with). The settings flow persists the section first and calls
  /// this right after; `/mcp reload` keeps its whole-wiring swap for
  /// boot-level changes (transport factory, section ↔ no-section).
  Future<void> applyConfig(McpConfig next) async {
    final previous = config;
    config = next;
    final restartAll = next.toolCallTimeout != previous.toolCallTimeout;
    for (final name in previous.servers.keys) {
      final fresh = next.servers[name];
      if (!restartAll && fresh == previous.servers[name]) continue;
      await _replaceServer(name, fresh);
    }
    for (final server in next.servers.values) {
      if (previous.servers.containsKey(server.name)) continue;
      unawaited(_runServer(server));
    }
  }

  /// Stops and immediately reconnects just [name] (the settings flow's
  /// reconnect action, issue #396) — a fresh connect attempt, no waiting
  /// out the reconnect backoff. Unknown names are a no-op.
  Future<void> restartServer(String name) =>
      _replaceServer(name, config.servers[name]);

  /// Stops [name]'s reconnect loop and drops its connection, tools and
  /// state; when [next] is non-null a fresh loop starts for the new
  /// entry. Untouched servers keep their connections.
  Future<void> _replaceServer(String name, McpServerConfig? next) async {
    _stops.add(name);
    _wakes.remove(name)?.complete();
    final client = _clients.remove(name);
    final tools = _tools.remove(name);
    final state = _states.remove(name);
    final hadSurface = client != null || tools != null || state != null;
    await client?.close();
    if (hadSurface) onChanged?.call();
    if (next != null) unawaited(_runServer(next));
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
