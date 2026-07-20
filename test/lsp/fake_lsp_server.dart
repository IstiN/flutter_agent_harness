/// A fake LSP server for tests: an in-memory [LspTransport] pair plus a
/// scriptable JSON-RPC peer that speaks real `Content-Length` framing.
///
/// The fake answers `initialize`/`shutdown` automatically, logs every
/// client request and notification for assertions, auto-publishes scripted
/// diagnostics after `didOpen`/`didChange`, and can simulate a crash or
/// send server-initiated requests.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The client-facing end of a [FakeLspServer].
final class FakeLspTransport implements LspTransport {
  // Synchronous controllers: a client write reaches the fake's listener
  // before the writing call returns, so tests assert deterministically.
  final _incoming = StreamController<List<int>>(sync: true);
  final _outgoing = StreamController<List<int>>(sync: true);
  final _exit = Completer<int>();

  /// Whether [kill] was called.
  bool killed = false;

  @override
  Stream<List<int>> get messages => _incoming.stream;

  @override
  void write(List<int> data) {
    if (!_outgoing.isClosed) _outgoing.add(data);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
  }

  Future<void> _close() async {
    await _incoming.close();
    await _outgoing.close();
  }
}

/// Return from [FakeLspServer.requestHandler] to answer a request with a
/// JSON-RPC error envelope instead of a result.
final class FakeLspError {
  /// Creates a [FakeLspError].
  const FakeLspError(this.message, {this.code = -32603});

  /// The error message.
  final String message;

  /// The JSON-RPC error code.
  final int code;
}

/// A scriptable fake LSP server speaking framed JSON-RPC over a
/// [FakeLspTransport].
final class FakeLspServer {
  /// Creates a [FakeLspServer] advertising [capabilities].
  FakeLspServer({Map<String, dynamic>? capabilities})
    : capabilities =
          capabilities ??
          const {
            'definitionProvider': true,
            'referencesProvider': true,
            'renameProvider': true,
          } {
    transport = FakeLspTransport();
    _subscription = transport._outgoing.stream.listen(_onData);
  }

  /// The transport the client connects to.
  late final FakeLspTransport transport;

  /// Capabilities answered to `initialize`.
  final Map<String, dynamic> capabilities;

  final _framer = LspMessageFramer();
  final _serverPending = <int, Completer<Map<String, dynamic>>>{};
  var _nextServerId = 10000;
  StreamSubscription<List<int>>? _subscription;

  /// Client requests received (method + params), in order.
  final requests = <({String method, Object? params})>[];

  /// Client notifications received (method + params), in order.
  final notifications = <({String method, Object? params})>[];

  /// Scripted request handler. When null, every non-handshake request gets
  /// a `null` result.
  Object? Function(String method, Object? params)? requestHandler;

  /// When false, client requests are logged but never answered (timeout
  /// and crash tests).
  bool autoRespond = true;

  /// Called for each client notification after logging.
  void Function(String method, Object? params)? notificationHandler;

  /// Diagnostics to auto-publish after `didOpen`/`didChange`, keyed by URI.
  final diagnosticsToPublish = <String, List<Map<String, dynamic>>>{};

  /// When false, didOpen/didChange do not trigger auto-publishing.
  bool autoPublishDiagnostics = true;

  /// Params of the last `didOpen`/`didChange` per URI (for assertions).
  final openedDocuments = <String, Map<String, dynamic>>{};

  /// Content versions of the last `didOpen`/`didChange` per URI.
  final documentVersions = <String, int>{};

  void _onData(List<int> chunk) {
    _framer.push(chunk);
    for (final text in _framer.drain()) {
      final message = jsonDecode(text);
      if (message is! Map<String, dynamic>) continue;
      _dispatch(message);
    }
  }

  void _dispatch(Map<String, dynamic> message) {
    final method = message['method'];
    final id = message['id'];
    if (method is String && id != null) {
      _handleClientRequest(id, method, message['params']);
    } else if (method is String) {
      _handleClientNotification(method, message['params']);
    } else if (id != null) {
      // Response to one of OUR server-initiated requests.
      _serverPending.remove(id)?.complete(message);
    }
  }

  void _handleClientRequest(Object id, String method, Object? params) {
    requests.add((method: method, params: params));
    if (!autoRespond) return;
    final Object? result;
    if (requestHandler != null) {
      result = requestHandler!(method, params);
    } else if (method == 'initialize') {
      result = {'capabilities': capabilities};
    } else {
      result = null;
    }
    if (result is FakeLspError) {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': result.code, 'message': result.message},
      });
    } else {
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});
    }
  }

  void _handleClientNotification(String method, Object? params) {
    notifications.add((method: method, params: params));
    if (method == 'textDocument/didOpen' && params is Map<String, dynamic>) {
      final doc = params['textDocument'];
      if (doc is Map<String, dynamic> && doc['uri'] is String) {
        final uri = doc['uri'] as String;
        openedDocuments[uri] = doc;
        documentVersions[uri] = (doc['version'] as num?)?.toInt() ?? 0;
        if (autoPublishDiagnostics) {
          publishDiagnostics(uri, diagnosticsToPublish[uri] ?? const []);
        }
      }
    } else if (method == 'textDocument/didChange' &&
        params is Map<String, dynamic>) {
      final doc = params['textDocument'];
      if (doc is Map<String, dynamic> && doc['uri'] is String) {
        final uri = doc['uri'] as String;
        documentVersions[uri] = (doc['version'] as num?)?.toInt() ?? 0;
        if (autoPublishDiagnostics) {
          publishDiagnostics(uri, diagnosticsToPublish[uri] ?? const []);
        }
      }
    } else if (method == 'exit') {
      // Graceful exit: report a clean process end.
      if (!transport._exit.isCompleted) transport._exit.complete(0);
    }
    notificationHandler?.call(method, params);
  }

  void _send(Map<String, dynamic> message) {
    transport._incoming.add(LspMessageFramer.encode(jsonEncode(message)));
  }

  /// Sends a raw server-initiated message (response envelope included).
  void sendMessage(Map<String, dynamic> message) {
    _send(message);
  }

  /// Publishes diagnostics for [uri] (a server-initiated notification).
  void publishDiagnostics(String uri, List<Map<String, dynamic>> diags) {
    _send({
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': {'uri': uri, 'diagnostics': diags},
    });
  }

  /// Sends a server-initiated request and awaits the client's response
  /// message (the full JSON-RPC envelope).
  Future<Map<String, dynamic>> sendServerRequest(
    String method,
    Object? params,
  ) {
    final id = _nextServerId++;
    final completer = Completer<Map<String, dynamic>>();
    _serverPending[id] = completer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  /// Sends a server-initiated notification.
  void sendServerNotification(String method, Object? params) {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  /// Simulates a server crash: the output stream closes and the process
  /// exits with [code].
  Future<void> simulateCrash({int code = 1}) async {
    if (!transport._exit.isCompleted) transport._exit.complete(code);
    await transport._close();
  }

  /// Tears the fake down without simulating a crash.
  Future<void> dispose() async {
    if (!transport._exit.isCompleted) transport._exit.complete(0);
    await transport._close();
    await _subscription?.cancel();
  }
}

/// A [LspTransportFactory] that spawns [FakeLspServer]s, recording each one
/// in [spawned]. [onSpawn] customizes a server before the client connects.
final class FakeLspServerFactory {
  /// The servers spawned so far, in order.
  final spawned = <FakeLspServer>[];

  /// Customizes each spawned server (scripting) before it is returned.
  void Function(FakeLspServer server)? onSpawn;

  /// The factory callback.
  Future<LspTransport> call(LspServerConfig config, String cwd) async {
    final server = FakeLspServer();
    onSpawn?.call(server);
    spawned.add(server);
    return server.transport;
  }
}
