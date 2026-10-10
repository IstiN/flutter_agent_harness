// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The browser connector: the WebSocket API cannot set arbitrary headers,
/// so the bearer token CANNOT ride the handshake as `Authorization`.
/// fa_network (and the DAP hub) accept the session token as a `?token=`
/// query parameter instead — [connect] lifts `Authorization: Bearer <t>`
/// into the URI via [liftBearerIntoQuery] before opening the socket.
library;

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fa_network_ws.dart';

/// Lifts `Authorization: Bearer <token>` from [headers] into [wsUri] as a
/// `token` query parameter (browser WebSockets cannot set headers).
///
/// Existing query parameters are preserved; a stale `token` param is
/// replaced by the header value. The bearer auth-scheme match is
/// case-insensitive per RFC 6750, so `Authorization: bearer <t>` (or any
/// casing) is accepted too. Returns [wsUri] unchanged when there is no
/// usable bearer header — the server then 401s with a clear error
/// surfaced through `WsError`, same as before.
///
/// SECURITY: the token lands in the URI query, so any fa_network access
/// log (or intermediate proxy/CDN log) for `/ws` will capture it. The
/// deployed server contract requires `token` to be redacted/masked in
/// access logs with bounded retention; that redaction is server-side and
/// cannot be enforced from the browser client.
Uri liftBearerIntoQuery(Uri wsUri, Map<String, String> headers) {
  final auth = headers['Authorization'] ?? '';
  // RFC 6750: the auth-scheme is case-insensitive. FaNetworkWs._open
  // builds the exact 'Authorization' / 'Bearer ' casing today, but the
  // scheme match below deliberately tolerates any casing.
  if (!auth.toLowerCase().startsWith('bearer ')) return wsUri;
  final token = auth.substring('bearer '.length).trim();
  if (token.isEmpty) return wsUri;
  return wsUri.replace(
    queryParameters: {...wsUri.queryParameters, 'token': token},
  );
}

/// Web implementation of [WsConnector] (no header support by platform).
class PlatformWsConnector implements WsConnector {
  const PlatformWsConnector();

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    final channel = WebSocketChannel.connect(
      liftBearerIntoQuery(wsUri, headers),
    );
    await channel.ready;
    return StreamChannel<String>(
      channel.stream.cast<String>(),
      PlatformStringSink(channel.sink),
    );
  }
}

/// Narrows a WebSocket sink to `StreamSink<String>`.
final class PlatformStringSink implements StreamSink<String> {
  PlatformStringSink(this._inner);

  final WebSocketSink _inner;

  @override
  void add(String event) => _inner.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<String> stream) => _inner.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _inner.close(closeCode, closeReason);

  @override
  Future<void> get done => _inner.done;
}
