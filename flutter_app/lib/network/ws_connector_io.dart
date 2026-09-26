// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The VM/desktop connector: `IOWebSocketChannel.connect` carries the
/// `Authorization` header (the browser API cannot — see
/// `ws_connector_web.dart`). `channel.ready` is awaited so a failed
/// handshake (401 & co) becomes a catchable exception instead of an
/// unhandled async error.
library;

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fa_network_ws.dart';

/// VM implementation of [WsConnector] with real header support.
class PlatformWsConnector implements WsConnector {
  const PlatformWsConnector();

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    final channel = IOWebSocketChannel.connect(wsUri, headers: headers);
    // Surfaces handshake failures (401, TLS, refused) as a catchable
    // error here instead of an unhandled Future error later.
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
