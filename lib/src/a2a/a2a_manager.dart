/// Session-scoped manager for remote A2A agents (Phase 5a).
///
/// Mirrors [McpManager]'s lazy-connect pattern: configured servers connect
/// in the background on first use (Agent Card fetch), per-server status is
/// queryable, and a spawned remote task maps onto the same
/// [SubagentHandle] registry the local children use — `task_status`,
/// `task_observe`, and `task_send` work uniformly.
library;

import 'dart:async';

import 'a2a_client.dart';
import 'a2a_config.dart';

/// One managed remote A2A agent: its config, lazily-connected client, and
/// the last observed connection status.
final class A2aManagedServer {
  A2aManagedServer(this.config) : status = A2aServerConnectionStatus.connecting;

  /// The parsed config entry.
  final A2aServerConfig config;

  /// The lazily-created client (null until the first connect resolves).
  A2aClient? client;

  /// Agent Card once fetched.
  AgentCard? card;

  /// Current connection status.
  A2aServerConnectionStatus status;

  /// The error that failed the last connect, if any.
  String? error;
}

/// Connection states of a configured A2A agent.
enum A2aServerConnectionStatus { connecting, connected, failed }

/// Maps an A2A task state onto the subagent status lifecycle (the phase 5
/// design table).
SubagentLifecycle mapA2aTaskState(A2aTaskState state) {
  switch (state) {
    case A2aTaskState.submitted:
      return SubagentLifecycle.queued;
    case A2aTaskState.working:
      return SubagentLifecycle.running;
    case A2aTaskState.inputRequired:
      return SubagentLifecycle.idle;
    case A2aTaskState.completed:
      return SubagentLifecycle.completed;
    case A2aTaskState.failed:
      return SubagentLifecycle.failed;
    case A2aTaskState.canceled:
      return SubagentLifecycle.aborted;
  }
}

/// The lifecycle vocabulary shared with the retained-subagent registry
/// (mirrors `SubagentStatus`; kept separate so this module stays decoupled).
enum SubagentLifecycle { queued, running, idle, completed, failed, aborted }

/// Session-scoped A2A manager.
final class A2aManager {
  /// Creates a manager over the configured servers (null config = none).
  /// [clientFactory] is injectable for tests (mock http backends).
  A2aManager(this.config, {A2aClient Function(A2aServerConfig)? clientFactory})
    : _clientFactory =
          clientFactory ??
          ((config) => A2aClient(baseUrl: config.url, token: config.token)) {
    for (final server in config?.servers.values ?? const <A2aServerConfig>[]) {
      _servers[server.name] = A2aManagedServer(server);
    }
  }

  /// The parsed `a2a:` config (empty when the section is absent).
  final A2aConfig? config;

  final A2aClient Function(A2aServerConfig) _clientFactory;

  final _servers = <String, A2aManagedServer>{};

  /// All managed servers by name.
  Map<String, A2aManagedServer> get servers => Map.unmodifiable(_servers);

  /// True when at least one A2A agent is configured.
  bool get hasServers => _servers.isNotEmpty;

  /// Looks up a server by name.
  A2aManagedServer? operator [](String name) => _servers[name];

  /// Connects [name] in the background if not yet connected (idempotent).
  /// The returned future resolves to the client, or throws on failure.
  Future<A2aClient> connect(String name) async {
    final server = _servers[name];
    if (server == null) {
      throw StateError(
        'unknown a2a server "$name" — available: '
        '${_servers.keys.join(', ')}',
      );
    }
    if (server.client != null) return server.client!;
    if (_connecting.containsKey(name)) return _connecting[name]!;
    final pending = _doConnect(server);
    _connecting[name] = pending;
    return pending;
  }

  final _connecting = <String, Future<A2aClient>>{};

  Future<A2aClient> _doConnect(A2aManagedServer server) async {
    try {
      final client = _clientFactory(server.config);
      server.card = await client.card;
      server.client = client;
      server.status = A2aServerConnectionStatus.connected;
      server.error = null;
      return client;
    } on Object catch (error) {
      server.status = A2aServerConnectionStatus.failed;
      server.error = '$error';
      rethrow;
    } finally {
      _connecting.remove(server.config.name);
    }
  }

  /// Sends [text] to the agent [name] and returns the A2A task. Registers
  /// connection status transitions on failure.
  Future<A2aTask> send(String name, String text) async {
    final client = await connect(name);
    return client.sendMessage(text);
  }

  /// Polls the remote task until a terminal state or [timeout] (default
  /// 4 min), calling [onUpdate] for every intermediate state.
  Future<A2aTask> waitForTask(
    String name,
    String taskId, {
    Duration timeout = const Duration(minutes: 4),
    void Function(A2aTask task)? onUpdate,
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final client = await connect(name);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final task = await client.getTask(taskId);
      onUpdate?.call(task);
      if (_isSettledState(task.state)) return task;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('a2a task "$taskId" did not settle', timeout);
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// True when the A2A task state settles the wait loop: terminal states
  /// plus `input-required` (the parent answers it via task_send).
  static bool _isSettledState(A2aTaskState state) =>
      state == A2aTaskState.completed ||
      state == A2aTaskState.failed ||
      state == A2aTaskState.canceled ||
      state == A2aTaskState.inputRequired;

  /// Cancels a remote task (dispose semantics).
  Future<void> cancel(String name, String taskId) async {
    final client = await connect(name);
    await client.cancelTask(taskId);
  }

  /// Renders the artifacts of [task] into text under the shared 100k-char
  /// budget (same rule as the MCP content mapping). Text parts join
  /// directly; opaque data parts render as compact JSON.
  static String renderArtifacts(A2aTask task, {int budget = 100000}) {
    final parts = <String>[];
    for (final artifact in task.artifacts) {
      for (final part in artifact.parts) {
        if (part.text != null) {
          parts.add(part.text!);
        } else if (part.data != null) {
          parts.add('[data artifact: ${part.data}]');
        }
      }
    }
    var text = parts.join('\n');
    if (text.length > budget) {
      text = '${text.substring(0, budget)}…[truncated at $budget chars]';
    }
    return text;
  }

  /// Closes every connected client.
  void close() {
    for (final server in _servers.values) {
      server.client?.close();
    }
  }
}

/// Formats one `/a2a` status line block for [server] (pure, testable).
List<String> formatA2aServerStatus(A2aManagedServer server) {
  final status = switch (server.status) {
    A2aServerConnectionStatus.connecting => '… connecting',
    A2aServerConnectionStatus.connected => '✅ connected',
    A2aServerConnectionStatus.failed => '❌ failed',
  };
  final lines = <String>[
    '  ${server.config.name}: $status',
    '    url: ${server.config.url}',
  ];
  final card = server.card;
  if (card != null) {
    lines.add('    agent: ${card.name} v${card.version}');
  }
  if (server.error != null) {
    lines.add('    error: ${server.error}');
  }
  return lines;
}

/// Formats the whole `/a2a` status block for the manager (pure, testable):
/// the no-servers hint, one block per server, and the usage hint.
List<String> formatA2aStatusLines(A2aManager manager) {
  if (!manager.hasServers) {
    return const [
      'no a2a servers configured — add an `a2a:` section to '
          '~/.fah/config.yaml',
    ];
  }
  final lines = <String>['[A2A servers]'];
  for (final server in manager.servers.values) {
    lines.addAll(formatA2aServerStatus(server));
  }
  lines.add('  use via the task tool: agent "a2a:<name>"');
  return lines;
}
