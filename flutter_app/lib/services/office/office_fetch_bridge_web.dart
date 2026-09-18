// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web implementation of the SW fetch-bridge transport (issues #470, #633).
///
/// The taskpane (fa1.dev framed inside Outlook) can never fetch providers
/// directly — providers send no ACAO headers, so the browser kills every
/// request with its network-failure phrase ("Load failed" on WebKit). The
/// transport chain per send:
///
/// 1. the extension bridge, when the relay content script answers
///    (`window.postMessage` → `browser_ext/content/embed_relay.js` → SW
///    fetch under `host_permissions`), frames coming back as
///    head/chunk/end over postMessage — SSE arrives incrementally;
/// 2. the local fa hub relay (`POST $officeHubRelayBase/relay`), when no
///    extension answers but the hub is up — the desktop path (WKWebView,
///    no extension exists there); the hub fetches CORS-free by
///    construction and streams the upstream answer back raw;
/// 3. a direct fetch — kept last so non-provider CORS-free traffic still
///    works — but when it dies, the failure is reworded to
///    [officeRelayDownError]: the user is told what to run where, never
///    shown "Load failed" (issue #633 contract).
///
/// A bridge whose SW died mid-handshake (MV3 restart) is retried once with
/// a fresh handshake (E1) before degrading to step 2.
///
/// The relay answers only frames tagged `__faEmbed*` with a matching reqId
/// and messages from Outlook's surrounding frames are ignored.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:fa/services/office/office_fetch_bridge.dart';
import 'package:fa/services/relay/relay_probe.dart' show kFaBuildHost;
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

EmbedHttpClient Function()? installOfficeHttpBridgeImpl() {
  if (kFaBuildHost != 'office') return null;
  return EmbedHttpClient.new;
}

/// The err-frame text of a transport that died under us (SW restart,
/// invalidated extension context) — retryable with a fresh handshake.
final class _BridgeDead implements Exception {
  _BridgeDead(this.raw);
  final String raw;
  @override
  String toString() => raw;
}

final class EmbedHttpClient extends http.BaseClient {
  Future<bool>? _relayUp;
  Future<bool>? _hubUp;
  final _replies = <String, void Function(Map<Object?, Object?>)>{};
  late final _listener = ((web.MessageEvent e) => _onMessage(e)).toJS;
  var _seq = 0;

  /// One probe per client: `true` when the relay content script answered.
  Future<bool> get relayUp => _relayUp ??= _ping().then((up) {
    debugBridgeLog(
      'http bridge: ${up ? 'up — provider traffic via SW' : 'absent'}',
    );
    return up;
  });

  /// One probe per client: `true` when the local fa hub relay answers.
  Future<bool> get hubUp => _hubUp ??= _probeHub().then((up) {
    debugBridgeLog('hub relay: ${up ? 'up — provider traffic via hub' : 'absent'}');
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
    if (await relayUp) {
      try {
        return await _bridgeSend(request);
      } on _BridgeDead {
        // E1: the SW died under us — re-handshake once, then degrade.
        debugBridgeLog('http bridge: died mid-handshake, re-handshaking');
        if (!await _ping()) {
          if (!await hubUp) throw StateError(officeRelayDownError);
        } else {
          try {
            return await _bridgeSend(request);
          } on _BridgeDead {
            // fall through to the hub
          }
        }
      }
    }
    if (await hubUp) return _hubSend(request);
    return _directSend(request);
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
          final text = '${frame['error']}';
          final error = bridgeTransportDead(text)
              ? _BridgeDead(text)
              : StateError('fetch bridge: $text');
          if (head.isCompleted) {
            // mid-stream: the POST already happened, surface it as body
            chunks.addError(error);
            chunks.close();
          } else {
            // pre-head: fail send() itself so the retry can answer (E1)
            chunks.close();
            head.completeError(error);
          }
      }
    };
    _post(envelope);
    return head.future;
  }

  /// The desktop path: the request rides the hub's /relay mount, the
  /// upstream answer (status + content-type + body) streams back raw.
  Future<http.StreamedResponse> _hubSend(http.BaseRequest request) async {
    final controller = web.AbortController();
    return _sendViaFetch(
      request,
      '$officeHubRelayBase/relay',
      body: jsonEncode({
        'url': request.url.toString(),
        'method': request.method,
        'headers': request.headers,
        if (request is http.Request && request.bodyBytes.isNotEmpty)
          'bodyB64': base64Encode(request.bodyBytes),
      }),
      contentType: 'application/json',
      controller: controller,
    );
  }

  /// The last resort (non-provider CORS-free traffic). A CORS death — the
  /// only possible outcome for provider hosts — is reworded per the #633
  /// contract: named fix, raw browser phrase demoted to the cause.
  Future<http.StreamedResponse> _directSend(http.BaseRequest request) async {
    try {
      return await _sendViaFetch(
        request,
        request.url.toString(),
        body: request is http.Request && request.bodyBytes.isNotEmpty
            ? utf8.decode(request.bodyBytes)
            : null,
        contentType: request.headers['content-type'],
      );
    } on Object catch (e) {
      throw StateError('$officeRelayDownError (direct fetch failed: $e)');
    }
  }

  Future<http.StreamedResponse> _sendViaFetch(
    http.BaseRequest request,
    String url, {
    required String? body,
    required String? contentType,
    web.AbortController? controller,
  }) async {
    final init = <String, Object?>{
      'method': request.method,
      'headers': {
        'content-type': ?contentType,
      },
      'body': ?body,
      'signal': ?controller?.signal,
    };
    final response = await _fetch(url, init.jsify()! as web.RequestInit);
    return http.StreamedResponse(
      _pump(
        response.body!,
        onDetach: controller == null ? null : () => controller.abort(),
      ),
      response.status,
      headers: {
        'content-type': ?response.headers.get('content-type'),
      },
      request: request,
    );
  }

  /// Streams a fetch Response body through the client's reader; cancelling
  /// the subscription unlocks the reader and aborts the upstream fetch
  /// when one was wired (AC3).
  Stream<List<int>> _pump(
    web.ReadableStream body, {
    void Function()? onDetach,
  }) {
    final reader = body.getReader() as web.ReadableStreamDefaultReader;
    final out = StreamController<List<int>>(
      onCancel: () {
        onDetach?.call();
        reader.cancel().toDart.then((_) {}, onError: (_) {});
      },
    );
    void pump() {
      reader.read().toDart.then((result) {
        if (out.isClosed) return;
        if (result.done) {
          out.close();
          return;
        }
        final chunk = result.value;
        if (chunk != null) {
          out.add((chunk as JSUint8Array).toDart);
        }
        pump();
      }).catchError((Object e) {
        if (!out.isClosed) out.addError(e);
      });
    }

    pump();
    return out.stream;
  }

  Future<web.Response> _fetch(String url, web.RequestInit init) async =>
      await (globalContext
              .callMethod('fetch'.toJS, url.toJS, init) as JSPromise)
          .toDart as web.Response;

  /// The hub presence probe: healthz inside a short timeout window.
  Future<bool> _probeHub() async {
    final controller = web.AbortController();
    final timer = Timer(const Duration(milliseconds: 400), () {
      controller.abort();
    });
    try {
      final response = await _fetch(
        '$officeHubRelayBase/healthz',
        ({'signal': controller.signal}).jsify()! as web.RequestInit,
      );
      return response.status == 200;
    } on Object {
      return false;
    } finally {
      timer.cancel();
    }
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
  if (kFaBuildHost == 'office') {
    // ignore: avoid_print
    print('[fah][office] $message');
  }
}
