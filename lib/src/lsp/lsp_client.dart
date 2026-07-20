/// The LSP JSON-RPC client: a pure-Dart protocol layer over an
/// [LspTransport] (a reduced port of oh-my-pi
/// `packages/coding-agent/src/lsp/client.ts`).
///
/// Covers the `initialize`/`initialized` handshake, `didOpen`/`didChange`/
/// `didClose` with content-version tracking, a `publishDiagnostics` cache,
/// request/response routing with per-request timeouts, and graceful
/// `shutdown`/`exit`. Server-initiated requests are answered per spec
/// (`workspace/configuration`, `workspace/workspaceFolders`, dynamic
/// registration, progress-token creation); unknown ones get a
/// `-32601` method-not-found reply.
///
/// Reductions from omp: no write queue with flush-abort (transport writes
/// are fire-and-forget; a wedged server surfaces through [exitCode] and the
/// request timeout), no `$/progress` project-load tracking (the Dart
/// analysis server serializes requests itself), no lspmux wrapping, no
/// rust-analyzer-specific readiness polling.
library;

import 'dart:async';
import 'dart:convert';

import 'lsp_config.dart';
import 'lsp_framing.dart';
import 'lsp_transport.dart';
import 'lsp_types.dart';

/// Client lifecycle state (omp's `status`).
enum LspClientStatus {
  /// `initialize` handshake in flight.
  connecting,

  /// Handshake complete; requests may be sent.
  ready,

  /// The connection is dead (process exit, reader failure, or [shutdown]).
  closed,
}

/// Thrown when an LSP request fails: server error response, timeout, or a
/// dead connection.
final class LspRequestException implements Exception {
  /// Creates an [LspRequestException].
  const LspRequestException(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => message;
}

/// Default per-request timeout (omp's `DEFAULT_REQUEST_TIMEOUT_MS`).
const defaultLspRequestTimeout = Duration(seconds: 30);

/// Max wait for a graceful `shutdown` + process exit (omp's
/// `SHUTDOWN_TIMEOUT_MS` / `EXIT_TIMEOUT_MS`).
const _shutdownTimeout = Duration(seconds: 5);
const _exitTimeout = Duration(seconds: 1);

/// Client capabilities advertised in `initialize` (omp's
/// `CLIENT_CAPABILITIES`, reduced to the four ops this client performs).
const _clientCapabilities = <String, dynamic>{
  'textDocument': <String, dynamic>{
    'synchronization': <String, dynamic>{
      'didSave': true,
      'dynamicRegistration': false,
    },
    'definition': <String, dynamic>{
      'dynamicRegistration': false,
      'linkSupport': true,
    },
    'references': <String, dynamic>{'dynamicRegistration': false},
    'rename': <String, dynamic>{
      'dynamicRegistration': false,
      'prepareSupport': false,
    },
    'publishDiagnostics': <String, dynamic>{
      'relatedInformation': true,
      'versionSupport': true,
    },
  },
  'window': <String, dynamic>{'workDoneProgress': true},
  'workspace': <String, dynamic>{
    // Server-initiated edits are not applied by this port; rename results
    // come back in the request response.
    'applyEdit': false,
    'workspaceEdit': <String, dynamic>{'documentChanges': true},
    'configuration': true,
    'workspaceFolders': true,
  },
};

/// A live connection to one language server process.
final class LspClient {
  /// Creates an [LspClient] over [transport]. The read loop starts
  /// immediately; call [initialize] before issuing document requests.
  LspClient({
    required this.config,
    required this.rootPath,
    required this.transport,
    this.processId,
    this.requestTimeout = defaultLspRequestTimeout,
    this.onExit,
  }) {
    _subscription = transport.messages.listen(
      _onData,
      onError: _onStreamError,
      onDone: _onStreamDone,
    );
    unawaited(
      transport.exitCode.then(
        (code) => _onProcessExit(code),
        onError: (_) {
          _onProcessExit(null);
        },
      ),
    );
  }

  /// The server definition this client was spawned for.
  final LspServerConfig config;

  /// Workspace root the server was started in.
  final String rootPath;

  /// The byte channel to the server process.
  final LspTransport transport;

  /// The host process id advertised in `initialize` (the server exits when
  /// the parent dies). Null when the host cannot provide one (e.g. tests).
  final int? processId;

  /// Default timeout for requests without an explicit one.
  final Duration requestTimeout;

  /// Called exactly once when the connection dies (crash, stream close, or
  /// [shutdown]).
  final void Function()? onExit;

  final _framer = LspMessageFramer();
  final _pending = <Object, Completer<Object?>>{};

  /// Latest published diagnostics per document URI (omp's
  /// `client.diagnostics`).
  final diagnostics = <String, List<LspDiagnostic>>{};

  /// Bumped on every `publishDiagnostics` notification (omp's
  /// `diagnosticsVersion`).
  int diagnosticsVersion = 0;

  /// Open documents: URI → current content version (omp's `openFiles`).
  final openFiles = <String, int>{};

  /// Server capabilities from the `initialize` result, when connected.
  Map<String, dynamic>? serverCapabilities;

  /// Lifecycle state.
  LspClientStatus status = LspClientStatus.connecting;

  /// Last activity timestamp for the manager's idle sweep (omp's
  /// `lastActivity`).
  DateTime lastActivity = DateTime.now();

  final _diagnosticsController = StreamController<String>.broadcast();

  /// Emits a document URI every time the server publishes diagnostics.
  Stream<String> get diagnosticsStream => _diagnosticsController.stream;

  int _nextId = 0;
  StreamSubscription<List<int>>? _subscription;
  bool _exitNotified = false;

  // -------------------------------------------------------------------------
  // Handshake
  // -------------------------------------------------------------------------

  /// Runs the `initialize`/`initialized` handshake and pushes the
  /// configured settings. Throws [LspRequestException] on failure.
  Future<void> initialize({Duration? timeout}) async {
    final result = await request('initialize', {
      if (processId != null) 'processId': processId,
      'rootUri': fileToUri(rootPath),
      'rootPath': rootPath,
      'capabilities': _clientCapabilities,
      'initializationOptions': config.initOptions,
      'workspaceFolders': [_workspaceFolder()],
    }, timeout: timeout ?? requestTimeout);
    if (result is! Map<String, dynamic>) {
      throw const LspRequestException('Failed to initialize LSP: no response');
    }
    final capabilities = result['capabilities'];
    if (capabilities is Map<String, dynamic>) {
      serverCapabilities = capabilities;
    }
    status = LspClientStatus.ready;
    notify('initialized', const <String, dynamic>{});
    if (config.settings.isNotEmpty) {
      notify('workspace/didChangeConfiguration', {'settings': config.settings});
    }
  }

  Map<String, dynamic> _workspaceFolder() {
    final name = rootPath.split('/').last;
    return {
      'uri': fileToUri(rootPath),
      'name': name.isEmpty ? 'workspace' : name,
    };
  }

  // -------------------------------------------------------------------------
  // Requests and notifications
  // -------------------------------------------------------------------------

  /// Sends a request and awaits its result. Throws [LspRequestException]
  /// on a server error response, on [timeout], or when the connection dies
  /// mid-flight.
  Future<Object?> request(String method, Object? params, {Duration? timeout}) {
    if (status == LspClientStatus.closed) {
      return Future.error(
        LspRequestException('LSP connection is closed ($method)'),
      );
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

    final effectiveTimeout = timeout ?? requestTimeout;
    Timer? timer;
    timer = Timer(effectiveTimeout, () {
      if (_pending.remove(id) != null) {
        completer.completeError(
          LspRequestException(
            'LSP request $method timed out after ${effectiveTimeout.inMilliseconds}ms',
          ),
        );
      }
    });
    return completer.future.whenComplete(() => timer?.cancel());
  }

  /// Sends a notification (no response expected).
  void notify(String method, Object? params) {
    if (status == LspClientStatus.closed) return;
    _write({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void _write(Map<String, dynamic> message) {
    lastActivity = DateTime.now();
    transport.write(LspMessageFramer.encode(jsonEncode(message)));
  }

  void _respond(Object id, {Object? result, Map<String, dynamic>? error}) {
    _write({
      'jsonrpc': '2.0',
      'id': id,
      if (error != null) 'error': error else 'result': result,
    });
  }

  // -------------------------------------------------------------------------
  // Document synchronization
  // -------------------------------------------------------------------------

  /// Opens [path] with [content] if not already tracked (omp's
  /// `ensureFileOpen`): sends `textDocument/didOpen` with version 1.
  void ensureOpen(String path, String content, String languageId) {
    final uri = fileToUri(path);
    if (openFiles.containsKey(uri)) return;
    notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': languageId,
        'version': 1,
        'text': content,
      },
    });
    openFiles[uri] = 1;
  }

  /// Syncs in-memory [content] for [path] (omp's `syncContent`): opens the
  /// document when untracked, otherwise sends a full-content
  /// `textDocument/didChange` with a bumped version.
  void syncContent(String path, String content, String languageId) {
    final uri = fileToUri(path);
    final version = openFiles[uri];
    if (version == null) {
      ensureOpen(path, content, languageId);
      return;
    }
    final next = version + 1;
    notify('textDocument/didChange', {
      'textDocument': {'uri': uri, 'version': next},
      'contentChanges': [
        {'text': content},
      ],
    });
    openFiles[uri] = next;
  }

  /// Sends `textDocument/didClose` for [path] when tracked.
  void closeFile(String path) {
    final uri = fileToUri(path);
    if (openFiles.remove(uri) == null) return;
    notify('textDocument/didClose', {
      'textDocument': {'uri': uri},
    });
  }

  // -------------------------------------------------------------------------
  // Incoming message dispatch
  // -------------------------------------------------------------------------

  void _onData(List<int> chunk) {
    lastActivity = DateTime.now();
    _framer.push(chunk);
    for (final text in _framer.drain()) {
      final Object? message;
      try {
        message = jsonDecode(text);
      } on Object {
        continue; // malformed JSON: skip, later messages are still framed
      }
      if (message is! Map<String, dynamic>) continue;
      try {
        _dispatch(message);
      } on Object {
        // A throwing handler must not kill the reader.
      }
    }
  }

  void _dispatch(Map<String, dynamic> message) {
    // A message carrying `method` is server-originated: a request when it
    // also has an `id`, a notification otherwise. Disambiguate on `method`
    // FIRST (omp #3001): server request ids live in their own id space and
    // collide with in-flight client request ids.
    final method = message['method'];
    if (method is String) {
      final id = message['id'];
      if (id != null) {
        _handleServerRequest(id, method, message['params']);
      } else {
        _handleServerNotification(method, message['params']);
      }
      return;
    }
    final id = message['id'];
    if (id != null) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      final error = message['error'];
      if (error is Map<String, dynamic>) {
        pending.completeError(
          LspRequestException('LSP error: ${error['message']}'),
        );
      } else {
        pending.complete(message['result']);
      }
    }
  }

  void _handleServerNotification(String method, Object? params) {
    if (method == 'textDocument/publishDiagnostics' &&
        params is Map<String, dynamic>) {
      final uri = params['uri'];
      if (uri is String) {
        final list = params['diagnostics'];
        diagnostics[uri] = [
          if (list is List)
            for (final item in list)
              if (item is Map<String, dynamic>) LspDiagnostic.fromJson(item),
        ];
        diagnosticsVersion += 1;
        if (!_diagnosticsController.isClosed) {
          _diagnosticsController.add(uri);
        }
      }
    }
    // Other notifications (window/logMessage, $/progress, ...) are ignored.
  }

  void _handleServerRequest(Object id, String method, Object? params) {
    switch (method) {
      case 'workspace/configuration':
        final items = params is Map<String, dynamic> ? params['items'] : null;
        final result = [
          if (items is List)
            for (final item in items)
              if (item is Map<String, dynamic> && item['section'] is String)
                config.settings[item['section']]
              else
                null,
        ];
        _respond(id, result: result);
      case 'workspace/workspaceFolders':
        _respond(id, result: [_workspaceFolder()]);
      case 'window/workDoneProgress/create' ||
          'client/registerCapability' ||
          'client/unregisterCapability' ||
          'window/showMessageRequest' ||
          'workspace/semanticTokens/refresh' ||
          'workspace/inlayHint/refresh' ||
          'workspace/codeLens/refresh' ||
          'workspace/codeAction/refresh' ||
          'workspace/inlineValue/refresh' ||
          'workspace/foldingRange/refresh' ||
          'workspace/diagnostic/refresh':
        _respond(id, result: null);
      case 'window/showDocument':
        // Headless: nothing to display (spec result shape).
        _respond(id, result: const {'success': false});
      case 'workspace/applyEdit':
        // Not applied by this port (applyEdit capability is false).
        _respond(
          id,
          result: const {'applied': false, 'failureReason': 'not supported'},
        );
      default:
        _respond(
          id,
          error: {'code': -32601, 'message': 'Method not found: $method'},
        );
    }
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  void _onStreamError(Object error) =>
      _teardown('LSP connection error: $error');

  void _onStreamDone() => _teardown('LSP connection closed');

  void _onProcessExit(int? code) =>
      _teardown('LSP server exited unexpectedly (code $code)');

  /// Rejects all pending requests, marks the client closed, and notifies
  /// the manager exactly once (even when [shutdown] already closed us).
  void _teardown(String reason) {
    final wasClosed = status == LspClientStatus.closed;
    status = LspClientStatus.closed;
    if (!wasClosed) {
      final error = LspRequestException(reason);
      for (final pending in _pending.values) {
        if (!pending.isCompleted) pending.completeError(error);
      }
      _pending.clear();
    }
    if (_exitNotified) return;
    _exitNotified = true;
    onExit?.call();
  }

  /// Graceful shutdown: `shutdown` request, `exit` notification, then wait
  /// briefly for the process to leave before killing it (omp's shutdown
  /// path). Always safe to call; errors during shutdown are swallowed.
  Future<void> shutdown() async {
    if (status == LspClientStatus.closed) {
      transport.kill();
      _teardown('shutdown');
      return;
    }
    try {
      await request('shutdown', null, timeout: _shutdownTimeout);
    } on Object {
      // A wedged server must not block teardown.
    }
    notify('exit', null);
    status = LspClientStatus.closed;
    try {
      await transport.exitCode.timeout(_exitTimeout);
    } on Object {
      transport.kill();
    }
    await _subscription?.cancel();
    await _diagnosticsController.close();
    _teardown('shutdown');
  }
}
