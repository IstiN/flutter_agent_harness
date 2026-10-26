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

/// Optional authentication capability for a [HubTransport].
///
/// Native transports send the enrollment secret in the WebSocket
/// authorization header. Browser transports use [hubUrlWithBrowserBearer],
/// the hub's equivalent `?token=` upgrade credential. Transports without
/// this capability can still serve open/token-paired hubs through
/// [HubTransport.connect].
abstract interface class HubBearerTransport {
  /// Dials [url] with the enrollment secret as bearer-equivalent auth.
  Future<HubSocket> connectWithBearer(Uri url, String secret);
}

/// The browser bearer equivalent: `?token=<url-encoded secret>`.
///
/// Browser WebSocket cannot set an Authorization header. Keep the protocol's
/// query-parameter name isolated here so every browser host uses the same
/// authentication path. The returned URI contains a credential: never log it
/// or include it in an exception.
Uri hubUrlWithBrowserBearer(Uri url, String secret) =>
    url.replace(queryParameters: {...url.queryParameters, 'token': secret});
