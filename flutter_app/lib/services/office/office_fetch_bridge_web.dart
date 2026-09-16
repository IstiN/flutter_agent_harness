// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web implementation of the SW fetch-bridge transport (issue #470).
///
/// The transport is chosen lazily per client: on the first request the client
/// pings the relay content script (`window.postMessage` →
/// `browser_ext/content/embed_relay.js`). A pong means the extension is here —
/// requests ride the relay to the SW and come back as head/chunk/end frames
/// over postMessage, so provider SSE streams arrive incrementally (AC2). No
/// pong means no extension in this frame: the client falls back to the direct
/// transport and behaves exactly like the plain-web build (AC6), CORS rules
/// included.
///
/// The relay answers only frames tagged `__faEmbed*` with a matching reqId and
/// only when `event.source` is our own window, so ordinary page traffic and
/// messages from Outlook's surrounding frames are ignored.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:fa/services/relay/relay_probe.dart' show kFaBuildHost;
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client Function()? installOfficeHttpBridgeImpl() {
  if (kFaBuildHost != 'office') return null;
  return () => EmbedHttpClient();
}

final class EmbedHttpClient extends http.BaseClient {
  http.Client? _direct;
  Future<bool>? _relayUp;
  final _replies = <String, void Function(Map<Object?, Object?>)>{};
  late final _listener = ((web.MessageEvent e) => _onMessage(e)).toJS;
  var _seq = 0;

  /// One probe per client: `true` when the relay content script answered.
  Future<bool> get relayUp => _relayUp ??= _ping().then((up) {
    debugBridgeLog(
      'http bridge: ${up ? 'up — provider traffic via SW' : 'absent — direct fetch'}',
    );
    return up;
  });

  void _ensureListener() {
    web.window.addEventListener('message', _listener);
  }

  /// Pings the relay; a missing/throwing channel resolves false (250 ms).
  Future<bool> _ping() async {
    try {
      _ensureListener();
      final pong = Completer<bool>();
      final reqId = _next('ping');
      _replies[reqId] = (_) {
        if (!pong.isCompleted) pong.complete(true);
      };
      _post({'__faEmbed': 1, 'kind': 'ping', 'reqId': reqId});
      Timer(const Duration(milliseconds: 250), () {
        _replies.remove(reqId);
        if (!pong.isCompleted) pong.complete(false);
      });
      return await pong.future;
    } on Object {
      return false;
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!await relayUp) {
      // No extension here: today's direct transport, unchanged (AC6).
      return (_direct ??= http.Client()).send(request);
    }
    return _bridgeSend(request);
  }

  Future<http.StreamedResponse> _bridgeSend(http.BaseRequest request) async {
    final reqId = _next('http');
    final body = request is http.Request && request.bodyBytes.isNotEmpty
        ? base64Encode(request.bodyBytes)
        : null;
    final envelope = <String, Object?>{
      '__faEmbed': 1,
      'kind': 'stream',
      'reqId': reqId,
      'req': {
        'url': request.url.toString(),
        'method': request.method,
        'headers': request.headers,
        'bodyB64': ?body,
      },
    };
    final chunks = StreamController<List<int>>(
      onCancel: () {
        _post({'__faEmbed': 1, 'kind': 'abort', 'reqId': reqId});
        _replies.remove(reqId);
      },
    );
    final head = Completer<http.StreamedResponse>();
    _replies[reqId] = (res) {
      final frame = res['frame'];
      if (frame is! Map) return;
      switch (frame['t']) {
        case 'head':
          if (head.isCompleted) return;
          head.complete(
            http.StreamedResponse(
              chunks.stream,
              (frame['status'] as num).toInt(),
              headers: {
                for (final e in (frame['headers'] as Map? ?? {}).entries)
                  '${e.key}': '${e.value}',
              },
              request: request,
            ),
          );
        case 'chunk':
          chunks.add(base64Decode(frame['b64'] as String));
        case 'end':
          _replies.remove(reqId);
          chunks.close();
        case 'err':
          _replies.remove(reqId);
          chunks.addError(StateError('fetch bridge: ${frame['error']}'));
          chunks.close();
      }
    };
    _post(envelope);
    return head.future;
  }

  String _next(String kind) => 'fa-embed-$kind-${_seq++}';

  void _post(Map<String, Object?> message) {
    web.window.postMessage(message.jsify()!, web.window.location.origin.toJS);
  }

  void _onMessage(web.MessageEvent e) {
    final JSAny? source = e.source;
    if (source == null || !source.isA<web.Window>()) return;
    final data = e.data.dartify();
    if (data is! Map || data['__faEmbedRes'] != 1) return;
    _replies['${data['reqId']}']?.call(data);
  }
}

/// Boot-log visibility without pulling the app logger into this file.
void debugBridgeLog(String message) {
  assert(() {
    // ignore: avoid_print
    print('[fah][office] $message');
    return true;
  }());
}
