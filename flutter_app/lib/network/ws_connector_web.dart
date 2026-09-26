// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The browser connector: the WebSocket API cannot set arbitrary headers,
/// so the bearer token CANNOT ride the handshake on web — a deployment
/// that wants browser clients must accept `?token=` (not in the fa_network
/// contract yet) or front the WS with a cookie session. Until then the
/// web build connects unauthenticated and the server 401s with a clear
/// error surfaced through [WsError].
library;

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fa_network_ws.dart';

/// Web implementation of [WsConnector] (no header support by platform).
class PlatformWsConnector implements WsConnector {
  const PlatformWsConnector();

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    final channel = WebSocketChannel.connect(wsUri);
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
