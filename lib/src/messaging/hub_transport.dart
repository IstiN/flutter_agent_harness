/// The injectable WebSocket seam for the hub-backed messaging fabric
/// (issue #402, phase 27.1): the pure-Dart [HubMessagingRepository] dials
/// the hub through this interface — the same seam as the LSP/MCP clients.
///
/// `lib/io.dart` supplies the real `dart:io` WebSocket binding
/// (`IoHubTransport`); tests inject an in-memory fake. Nothing in
/// `lib/src/messaging/` touches sockets directly.
library;

/// One live hub connection.
abstract interface class HubSocket {
  /// Inbound text frames. The stream completing (done or error) means the
  /// connection is gone — the repository reconnects through its transport.
  Stream<String> get messages;

  /// Whether the connection can still accept outbound frames.
  bool get isOpen;

  /// Writes one text frame.
  Future<void> send(String text);

  /// Closes the connection; idempotent.
  Future<void> close();
}

/// Dials a hub URL (`ws://host:port/ws`) — the only network operation the
/// hub fabric performs. Implementations throw when the hub is unreachable
/// or rejects the upgrade (wrong pairing token); the repository treats any
/// throw as "not connected" and retries with backoff.
abstract interface class HubTransport {
  Future<HubSocket> connect(Uri url);
}
