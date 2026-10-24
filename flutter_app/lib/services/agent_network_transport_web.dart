// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Browser bindings for the app agent's hub membership.
///
/// The socket uses `web_socket_channel` (no `dart:io`) and the identity uses
/// the app's persistent [ExecutionEnv] sandbox, which is IndexedDB-backed on
/// web. Enrollment authentication is the hub's browser bearer equivalent,
/// isolated in [hubUrlWithBrowserBearer].
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Browser hub connections and persistent identities are fully supported.
const bool agentNetworkSupported = true;

/// The platform transport. Tests may inject a [WebHubSocketConnector] into
/// [WebHubTransport] instead of opening a real browser socket.
HubTransport? get platformHubTransport => const WebHubTransport();

/// The identity lives in the app sandbox, scoped by the caller exactly as on
/// native platforms.
String? identityPathFor(String sandboxRoot) => '$sandboxRoot/hub_identity';

/// Loads a stable identity through the web sandbox filesystem, creating and
/// persisting it on first use. A corrupt record is replaced just like the
/// native file-backed loader; a failed write is surfaced so an unpersisted
/// identity is never used as though it were stable.
Future<HubIdentity?> loadOrCreateIdentity(
  ExecutionEnv env,
  String? path,
) async {
  if (path == null) return null;
  final stored = (await env.readTextFile(path)).valueOrNull;
  if (stored != null) {
    try {
      return await hubIdentityFromKeyFile(stored);
    } on Object {
      // Regenerate below. Never log the record: it contains private keys.
    }
  }
  final identity = await HubIdentity.generate();
  final result = await env.writeFile(
    path,
    await hubIdentityToKeyFile(identity),
  );
  if (result case Err(:final error)) throw error;
  return identity;
}

/// Injectable browser socket boundary. The URI passed to an authenticated
/// connector contains a credential and must never be logged or stringified
/// into an error.
typedef WebHubSocketConnector = Future<HubSocket> Function(Uri url);

/// A real browser [HubTransport] with bearer-equivalent enrollment auth.
final class WebHubTransport implements HubTransport, HubBearerTransport {
  const WebHubTransport({WebHubSocketConnector connector = _defaultConnector})
    // Public parameter name, private storage: keep the injection seam usable.
    // ignore: prefer_initializing_formals
    : _connector = connector;

  final WebHubSocketConnector _connector;

  @override
  Future<HubSocket> connect(Uri url) => _connect(url);

  @override
  Future<HubSocket> connectWithBearer(Uri url, String secret) =>
      _connect(hubUrlWithBrowserBearer(url, secret));

  Future<HubSocket> _connect(Uri url) async {
    try {
      return await _connector(url);
    } on Object {
      // Browser and server errors can echo the complete upgrade URI. Never
      // propagate one: an authenticated URI carries the enrollment secret.
      throw StateError('hub WebSocket connection failed');
    }
  }

  static Future<HubSocket> _defaultConnector(Uri url) async {
    final channel = WebSocketChannel.connect(url);
    try {
      await channel.ready;
      return WebHubSocket(channel);
    } on Object {
      try {
        await channel.sink.close();
      } on Object {
        // The original failure is sanitized by [_connect].
      }
      rethrow;
    }
  }
}

/// One text-frame browser socket. Binary frames are dropped at the boundary,
/// matching the native transport and the hub's text-only protocol.
final class WebHubSocket implements HubSocket {
  WebHubSocket(this._channel) {
    _messages = _channel.stream
        .where((frame) => frame is String)
        .cast<String>()
        .transform(
          StreamTransformer<String, String>.fromHandlers(
            handleError: (error, stack, sink) {
              _open = false;
              sink.addError(error, stack);
            },
            handleDone: (sink) {
              _open = false;
              sink.close();
            },
          ),
        )
        .asBroadcastStream();
  }

  final WebSocketChannel _channel;
  late final Stream<String> _messages;
  var _open = true;

  @override
  Stream<String> get messages => _messages;

  @override
  bool get isOpen => _open;

  @override
  Future<void> send(String text) async {
    if (!_open) throw StateError('hub WebSocket is closed');
    _channel.sink.add(text);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _channel.sink.close();
  }
}
