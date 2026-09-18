/// Issue #633 desktop relay: `POST /relay` on the LocalHub HTTP mount.
///
/// The Outlook desktop taskpane (WKWebView — no extension exists there)
/// cannot fetch providers directly (CORS: providers send no ACAO headers),
/// so its provider HTTP routes through the local fa hub, which fetches
/// CORS-free by construction. The pane speaks the SW-bridge request
/// envelope (`{url, method, headers, bodyB64}`); the hub answers the RAW
/// upstream response (status + content-type + streamed body), so SSE rides
/// through incrementally.
///
/// CORS is origin-allowlisted (the taskpane origins only — never `*`), so
/// a hostile web page cannot read this loopback proxy; a lan-bound hub
/// additionally requires the master bearer credential.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/local_hub.dart';
import 'package:test/test.dart';

void main() {
  late LocalHub hub;
  late int port;
  late HttpServer upstream;
  final upstreamRequests = <HttpRequest>[];
  final upstreamBodies = <String>[];

  /// Serves a fake provider: POST → SSE stream of two data chunks.
  /// Deliberately sends NO CORS headers — like z.ai, the point of the hub.
  setUp(() async {
    hub = LocalHub();
    await hub.start();
    port = hub.url.port;
    upstreamRequests.clear();
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBodies.clear();
    unawaited(
      upstream.forEach((req) async {
        upstreamRequests.add(req);
        upstreamBodies.add(await utf8.decoder.bind(req).join());
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        req.response.write('data: {"delta":"Hel"}\n\n');
        await req.response.flush();
        req.response.write('data: {"delta":"lo"}\n\n');
        await req.response.flush();
        await req.response.close();
      }),
    );
  });

  tearDown(() async {
    await hub.stop();
    await upstream.close(force: true);
  });

  Future<(HttpClientResponse, String)> relay(
    Map<String, Object?> envelope, {
    String origin = 'https://fa1.dev',
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/relay'),
    );
    req.headers.set('Origin', origin);
    req.headers.contentType = ContentType.json;
    headers.forEach(req.headers.set);
    req.write(jsonEncode(envelope));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    return (res, body);
  }

  Map<String, Object?> envelope(String url) => {
    'url': url,
    'method': 'POST',
    'headers': {
      'Authorization': 'Bearer test-key',
      'Content-Type': 'application/json',
    },
    'bodyB64': base64Encode(utf8.encode('{"model":"glm-5.3-flash"}')),
  };
  test('POST /relay proxies the upstream status, content-type and '
      'streamed SSE body to the taskpane origin', () async {
    final (res, body) = await relay(envelope('http://127.0.0.1:${upstream.port}/chat/completions'));

    expect(res.statusCode, 200);
    expect(res.headers.value('access-control-allow-origin'), 'https://fa1.dev');
    expect(res.headers.contentType?.mimeType, 'text/event-stream');
    expect(upstreamRequests, hasLength(1));
    // The upstream saw the forwarded auth + body.
    expect(
      upstreamRequests.single.headers.value('authorization'),
      'Bearer test-key',
    );
    expect(upstreamBodies.single, contains('glm-5.3-flash'));
    // Both SSE chunks arrived, in order, in the passthrough body.
    expect(body, 'data: {"delta":"Hel"}\n\ndata: {"delta":"lo"}\n\n');
  });

  test('CORS preflight answers allowlisted taskpane origins only', () async {
    final client = HttpClient();
    for (final (origin, allowed) in [
      ('https://fa1.dev', true),
      ('http://localhost:5173', true),
      ('https://evil.example', false),
    ]) {
      final req = await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:$port/relay'),
      );
      req.headers.set('Origin', origin);
      req.headers.set(
        'Access-Control-Request-Method',
        'POST',
      );
      final res = await req.close();
      await res.drain<void>();
      expect(
        res.headers.value('access-control-allow-origin'),
        allowed ? origin : null,
        reason: 'origin $origin',
      );
    }
    client.close();
  });

  test('upstream failures pass through with their status and body', () async {
    await upstream.close(force: true);
    final failing = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => failing.close(force: true));
    unawaited(
      failing.forEach((req) async {
        req.response.statusCode = 401;
        req.response.write('{"error":"bad key"}');
        await req.response.close();
      }),
    );

    final (res, body) = await relay(
      envelope('http://127.0.0.1:${failing.port}/chat/completions'),
    );

    expect(res.statusCode, 401);
    expect(body, '{"error":"bad key"}');
    expect(res.headers.value('access-control-allow-origin'), 'https://fa1.dev');
  });

  test('a lan-bound protected hub requires the master bearer on /relay',
      () async {
    await hub.stop();
    hub = LocalHub(bind: 'lan', masterSecret: 'master-key');
    await hub.start();
    port = hub.url.port;

    final (denied, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
    );
    expect(denied.statusCode, 401);
    expect(upstreamRequests, isEmpty);

    final (ok, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      headers: {'Authorization': 'Bearer master-key'},
    );
    expect(ok.statusCode, 200);
  });

  test('a non-http(s) or missing url is a clean 400', () async {
    final (res, body) = await relay({'url': 'file:///etc/passwd'});
    expect(res.statusCode, 400);
    expect(body, contains('url'));
  });
}
