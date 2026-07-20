/// Server lifecycle management for the `lsp` tool (a reduced port of the
/// client-management half of oh-my-pi
/// `packages/coding-agent/src/lsp/client.ts`).
///
/// One [LspClient] runs per `server:workspaceRoot` pair, started lazily on
/// first use and shut down after an idle timeout. A crashed server is
/// dropped; the next request respawns it. Respawning is BOUNDED: a server
/// that dies within [crashWindow] of starting counts as a quick crash, and
/// [maxRestarts] consecutive quick crashes (or a failed initialize)
/// negative-cache the server for [initFailureBackoff] so a broken server
/// fails fast instead of re-spawning per call (omp's
/// `INIT_FAILURE_BACKOFF_MS` policy).
library;

import 'dart:async';

import '../env/execution_env.dart';
import 'lsp_client.dart';
import 'lsp_config.dart';
import 'lsp_transport.dart';

/// Thrown when no configured server handles a file's extension.
final class LspNoServerException implements Exception {
  /// Creates an [LspNoServerException].
  const LspNoServerException(this.path);

  /// The file no server matched.
  final String path;

  @override
  String toString() => 'No LSP server configured for $path';
}

/// Owns the [LspClient] pool for one `lsp` tool instance.
final class LspClientManager {
  /// Creates an [LspClientManager]. [idleTimeout] defaults to
  /// [LspConfig.idleTimeout]; [Duration.zero] disables the sweep.
  LspClientManager({
    required this.env,
    required this.config,
    required this.transportFactory,
    this.processId,
    this.requestTimeout = defaultLspRequestTimeout,
    this.initTimeout = defaultLspRequestTimeout,
    Duration? idleTimeout,
    this.idleCheckInterval = const Duration(minutes: 1),
    this.maxRestarts = 3,
    this.initFailureBackoff = const Duration(minutes: 3),
    this.crashWindow = const Duration(seconds: 10),
  }) : idleTimeout = idleTimeout ?? config.idleTimeout {
    if (this.idleTimeout > Duration.zero) {
      _idleTimer = Timer.periodic(idleCheckInterval, (_) => checkIdle());
    }
  }

  /// The workspace the servers operate on.
  final ExecutionEnv env;

  /// The resolved server configuration.
  final LspConfig config;

  /// Spawns server processes (the io-side factory on native hosts, a fake
  /// in tests).
  final LspTransportFactory transportFactory;

  /// Host process id forwarded to `initialize`; null when unknown.
  final int? processId;

  /// Default request timeout for spawned clients.
  final Duration requestTimeout;

  /// Timeout for the `initialize` handshake.
  final Duration initTimeout;

  /// Idle timeout after which unused servers are shut down.
  final Duration idleTimeout;

  /// How often the idle sweep runs.
  final Duration idleCheckInterval;

  /// Consecutive quick crashes tolerated before the backoff kicks in.
  final int maxRestarts;

  /// How long a server stays negative-cached after repeated crashes or an
  /// init failure (omp's `INIT_FAILURE_BACKOFF_MS`).
  final Duration initFailureBackoff;

  /// A server exiting within this window of its start counts as a crash.
  final Duration crashWindow;

  final _clients = <String, LspClient>{};
  final _starting = <String, Future<LspClient>>{};
  final _failures = <String, (DateTime, String)>{};
  final _quickCrashes = <String, int>{};
  final _spawnedAt = <LspClient, DateTime>{};
  Timer? _idleTimer;
  bool _disposed = false;

  /// The live clients, keyed `server:root` (omp's `getActiveClients`).
  Map<String, LspClient> get clients => Map.unmodifiable(_clients);

  /// Resolves the client for [path], starting the server lazily when
  /// needed. Throws [LspNoServerException] when no server matches,
  /// [LspServerUnavailableException] when the server cannot be spawned or
  /// is in backoff, and [LspRequestException] when the handshake fails.
  Future<LspClient> clientForFile(String path) async {
    if (_disposed) {
      throw const LspServerUnavailableException('LSP manager is disposed');
    }
    final server = config.serverForFile(path);
    if (server == null) throw LspNoServerException(path);
    final root = await config.workspaceRootFor(env, path, server);
    final key = '${server.name}:$root';

    final existing = _clients[key];
    if (existing != null && existing.status != LspClientStatus.closed) {
      existing.lastActivity = DateTime.now();
      return existing;
    }
    final starting = _starting[key];
    if (starting != null) return starting;

    // Fail fast on a recent deterministic failure instead of re-spawning a
    // broken server (and paying its full init wait) on every call.
    final failure = _failures[key];
    if (failure != null) {
      if (DateTime.now().difference(failure.$1) < initFailureBackoff) {
        throw LspServerUnavailableException(
          'LSP server ${server.command} failed to initialize recently: '
          '${failure.$2}',
        );
      }
      _failures.remove(key);
    }

    final future = _startClient(key, server, root);
    _starting[key] = future;
    try {
      return await future;
    } finally {
      _starting.remove(key);
    }
  }

  Future<LspClient> _startClient(
    String key,
    LspServerConfig server,
    String root,
  ) async {
    final spawnedAt = DateTime.now();
    late final LspClient client;
    final transport = await transportFactory(server, root);
    client = LspClient(
      config: server,
      rootPath: root,
      transport: transport,
      processId: processId,
      requestTimeout: requestTimeout,
      onExit: () => _handleExit(key, client, spawnedAt),
    );
    _spawnedAt[client] = spawnedAt;
    try {
      await client.initialize(timeout: initTimeout);
    } on Object catch (error) {
      _failures[key] = (DateTime.now(), '$error');
      _spawnedAt.remove(client);
      transport.kill();
      rethrow;
    }
    _clients[key] = client;
    _failures.remove(key);
    return client;
  }

  void _handleExit(String key, LspClient client, DateTime spawnedAt) {
    _spawnedAt.remove(client);
    if (_clients[key] == client) _clients.remove(key);
    if (_disposed) return;
    if (DateTime.now().difference(spawnedAt) < crashWindow) {
      final crashes = (_quickCrashes[key] ?? 0) + 1;
      _quickCrashes[key] = crashes;
      if (crashes >= maxRestarts) {
        _quickCrashes.remove(key);
        _failures[key] = (
          DateTime.now(),
          'server crashed $crashes times within '
              '${crashWindow.inSeconds}s of starting',
        );
      }
    } else {
      _quickCrashes.remove(key);
    }
  }

  /// Runs one idle sweep: shuts down clients idle longer than
  /// [idleTimeout]. The periodic timer calls this; tests may call it
  /// directly.
  Future<void> checkIdle() async {
    if (_disposed || idleTimeout <= Duration.zero) return;
    final now = DateTime.now();
    final stale = <String>[];
    for (final entry in _clients.entries) {
      if (now.difference(entry.value.lastActivity) > idleTimeout) {
        stale.add(entry.key);
      }
    }
    for (final key in stale) {
      final client = _clients.remove(key);
      await client?.shutdown();
    }
  }

  /// Shuts down every client and stops the idle sweep.
  Future<void> shutdownAll() async {
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    final clients = _clients.values.toList();
    _clients.clear();
    for (final client in clients) {
      await client.shutdown();
    }
  }
}
