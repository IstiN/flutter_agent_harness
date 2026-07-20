/// The process boundary for the LSP client: a byte-stream transport to a
/// running language server.
///
/// The core library is pure Dart, so spawning is abstracted behind
/// [LspTransport]; the `dart:io` implementation (`IoLspTransport`) lives in
/// `lib/src/lsp/io_lsp_transport.dart` and is exported only from
/// `lib/io.dart`. Tests substitute in-memory fakes.
library;

import 'lsp_config.dart';

/// Thrown by an [LspTransportFactory] when the server process cannot be
/// started (e.g. the command is not on `PATH`). The `lsp` tool converts this
/// into a clean error result — never a crash.
final class LspServerUnavailableException implements Exception {
  /// Creates an [LspServerUnavailableException].
  const LspServerUnavailableException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// The original error, when available.
  final Object? cause;

  @override
  String toString() => message;
}

/// A live byte channel to a language server process: framed JSON-RPC goes
/// out through [write], raw server output arrives on [messages].
abstract interface class LspTransport {
  /// Raw bytes from the server's stdout. The stream closing (normally or by
  /// error) means the connection is dead.
  Stream<List<int>> get messages;

  /// Writes raw (already framed) bytes to the server's stdin.
  void write(List<int> data);

  /// Completes with the server's exit code when the process ends, normally
  /// or not. Completes with an error when the exit cannot be determined.
  Future<int> get exitCode;

  /// Terminates the server process. Idempotent.
  void kill();
}

/// Spawns a language server for [config] rooted at [cwd].
///
/// Implementations must throw [LspServerUnavailableException] (not return
/// null) when the command cannot be started.
typedef LspTransportFactory =
    Future<LspTransport> Function(LspServerConfig config, String cwd);
