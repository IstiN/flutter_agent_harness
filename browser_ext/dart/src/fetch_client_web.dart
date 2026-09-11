// The dart2js half of fetch_client.dart (see the shell file for rationale).
library;

import 'dart:js_interop';

import 'package:http/http.dart' as http;

/// JS `fetch(url, init)`.
@JS('fetch')
external JSPromise<_FetchResponse> _fetch(JSString url, JSObject init);

extension type _FetchResponse._(JSObject _) implements JSObject {
  external int get status;
  external JSAny? get body; // ReadableStream | null
  external _Headers get headers;
}

extension type _Headers._(JSObject _) implements JSObject {
  external String? get(JSString name);
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_Chunk> read();
}

extension type _Chunk._(JSObject _) implements JSObject {
  external JSBoolean get done;
  external JSAny? get value; // Uint8Array
}

/// [http.Client] over the platform `fetch` — the only HTTP path inside a
/// MV3 service worker. Install with `providerHttpClientFactory`.
final class FetchClient extends http.BaseClient {
  /// [credentials] rides the fetch credentials mode: `include` for the
  /// provider traffic (cookie-auth hosts — CodeMie & friends: the SW
  /// fetch itself must carry the user's jar — with <all_urls> host
  /// permissions the browser attaches it, no header surgery; provider
  /// targets are user-configured, so sending credentials is the design,
  /// not a leak), `omit` for agent-driven web_fetch/web_search (the URL
  /// is model-chosen — sending the user's cookies there would be an
  /// exfil channel).
  FetchClient({this.credentials = 'include'});

  /// The fetch credentials mode (`include` / `omit`).
  final String credentials;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    final init =
        ({
              'method': req.method,
              'headers': req.headers,
              // fetch() rejects ANY body (even an empty string) on
              // GET/HEAD — and package:http fills req.body with ''.
              if (req.method != 'GET' &&
                  req.method != 'HEAD' &&
                  req.body.isNotEmpty)
                'body': req.body,
              'credentials': credentials,
            }).jsify()
            as JSObject;
    try {
      final response = await _fetch(req.url.toString().toJS, init).toDart;
      final headers = <String, String>{};
      for (final name in [
        'content-type',
        'content-length',
        'retry-after',
        'location',
      ]) {
        final value = response.headers.get(name.toJS);
        if (value != null) headers[name] = value;
      }
      final body = response.body;
      final stream = body == null ? Stream<List<int>>.empty() : _read(body);
      return http.StreamedResponse(
        http.ByteStream(stream),
        response.status,
        contentLength: int.tryParse(headers['content-length'] ?? ''),
        headers: headers,
        request: request,
      );
    } catch (error) {
      throw http.ClientException('$error', request.url);
    }
  }

  /// Drains a fetch ReadableStream into a Dart byte stream.
  Stream<List<int>> _read(JSAny? bodyStream) async* {
    final reader = (bodyStream as _ReadableStream).getReader();
    while (true) {
      final chunk = await reader.read().toDart;
      if (chunk.done.toDart) return;
      yield (chunk.value as JSUint8Array).toDart;
    }
  }
}
