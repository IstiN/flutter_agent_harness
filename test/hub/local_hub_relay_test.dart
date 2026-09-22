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
/// CORS is origin-allowlisted (the taskpane origins only — never `*`, and
/// a disallowed origin is a 403 rejection). Authentication (issue #792):
/// every scope demands a bearer — the master secret on a protected hub,
/// else the ephemeral per-serve secret — and destinations are allowlisted
/// to known provider hosts (redirects re-checked per hop).
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
    // The dev opt-in exists exactly for a loopback mock provider like
    // this fixture; the policy tests below spin a strict hub inline.
    hub = LocalHub(relayAllowAnyHost: true);
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
    String? bearer = '',
  }) async {
    final client = HttpClient();
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/relay'),
    );
    req.headers.set('Origin', origin);
    req.headers.contentType = ContentType.json;
    // '' = the default ephemeral bearer; null = none (unauthenticated).
    final token = bearer == '' ? hub.relaySecret : bearer;
    if (token != null) req.headers.set('Authorization', 'Bearer $token');
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
    hub = LocalHub(bind: 'lan', masterSecret: 'master-key', relayAllowAnyHost: true);
    await hub.start();
    port = hub.url.port;
    // The master secret IS the relay credential on a protected hub.
    expect(hub.relaySecret, 'master-key');

    final (denied, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      bearer: null,
    );
    expect(denied.statusCode, 401);
    expect(upstreamRequests, isEmpty);

    final (wrong, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      bearer: 'not-the-key',
    );
    expect(wrong.statusCode, 401);

    final (ok, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      bearer: 'master-key',
    );
    expect(ok.statusCode, 200);
  });

  test('every relay request carries a secret — an ephemeral hub still '
      'refuses the credential-less (issue #792 AC1)', () async {
    // `hub` is the default loopback fixture: no master secret, yet the
    // relay demands its per-serve bearer.
    expect(hub.isProtected, isFalse);
    expect(hub.relaySecret, isNotNull);
    expect(hub.relaySecret, isNot(isEmpty));

    final (denied, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      bearer: null,
    );
    expect(denied.statusCode, 401);
    final (wrong, _) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      bearer: 'guess',
    );
    expect(wrong.statusCode, 401);
    // Zero upstream attempts for both.
    expect(upstreamRequests, isEmpty);

    // And the secret is per-serve: a fresh hub rolls a new one.
    final second = LocalHub();
    addTearDown(second.stop);
    await second.start();
    expect(second.relaySecret, isNot(hub.relaySecret));
  });

  test('denied destinations answer 403 before any outbound attempt '
      '(issue #792 AC3)', () async {
    await hub.stop();
    hub = LocalHub(); // strict: no dev opt-in
    await hub.start();
    port = hub.url.port;
    for (final url in [
      'http://127.0.0.1:1/',
      'http://localhost:8787/',
      'http://169.254.169.254/latest/meta-data/',
      'http://10.1.2.3/',
      'http://192.168.1.10/',
      'http://172.16.0.9/',
      'http://[::1]:9000/',
      'http://0.0.0.0/',
    ]) {
      final (res, body) = await relay(envelope(url));
      expect(res.statusCode, 403, reason: 'destination $url');
      expect(body, contains('destination not allowed'), reason: url);
    }
    // The fixture provider saw nothing.
    expect(upstreamRequests, isEmpty);
  });

  test('the provider allowlist admits known hosts (and their '
      'subdomains), denies strangers; dev opt-in lifts it', () async {
    final ok = relayDestinationAllowed(Uri.parse('https://api.anthropic.com/v1/x'));
    expect(ok, isTrue);
    expect(
      relayDestinationAllowed(Uri.parse('https://eu.api.aiin.by/v1')),
      isTrue,
      reason: 'subdomain of an allowlisted host',
    );
    expect(
      relayDestinationAllowed(Uri.parse('https://evil.example/')),
      isFalse,
    );
    // The dev opt-in lifts everything — including loopback mocks.
    expect(
      relayDestinationAllowed(
        Uri.parse('http://127.0.0.1:9000/'),
        allowAnyHost: true,
      ),
      isTrue,
    );
  });

  test('redirects are followed manually: a same-host hop lands, a '
      'redirect loop is capped (issue #792 AC4)', () async {
    await upstream.close(force: true);
    // /hop answers; anything else 302s — to /hop, or to itself forever.
    final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => redirector.close(force: true));
    unawaited(
      redirector.forEach((req) async {
        if (req.uri.path == '/hop') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          req.response.write('data: {"delta":"landed"}\n\n');
          await req.response.close();
          return;
        }
        req.response.statusCode = 302;
        req.response.headers.set(
          'location',
          req.uri.path == '/to-loop' ? '/to-loop' : '/hop',
        );
        await req.response.close();
      }),
    );

    final (ok, okBody) = await relay(
      envelope('http://127.0.0.1:${redirector.port}/to-same-host'),
    );
    expect(ok.statusCode, 200);
    expect(okBody, 'data: {"delta":"landed"}\n\n');

    final (capped, cappedBody) = await relay(
      envelope('http://127.0.0.1:${redirector.port}/to-loop'),
    );
    expect(capped.statusCode, 502);
    expect(cappedBody, contains('too many redirects'));
  });

  test('a disallowed Origin is a 403 rejection — the upstream is never '
      'touched (issue #792 AC4)', () async {
    final (res, body) = await relay(
      envelope('http://127.0.0.1:${upstream.port}/chat/completions'),
      origin: 'https://evil.example',
    );
    expect(res.statusCode, 403);
    expect(body, contains('origin not allowed'));
    expect(upstreamRequests, isEmpty);
  });

  test('a non-http(s) or missing url is a clean 400', () async {
    final (res, body) = await relay({'url': 'file:///etc/passwd'});
    expect(res.statusCode, 400);
    expect(body, contains('url'));
  });
}
