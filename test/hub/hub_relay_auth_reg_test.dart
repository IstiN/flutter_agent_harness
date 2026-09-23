/// REG (issue #792 AC5): the hub relay auth suite. Pins the whole
/// SEC-04 contract in one named job — a regression here re-opens an
/// unauthenticated LAN/loopback HTTP proxy + SSRF primitive:
///
/// - `/relay` is authenticated on EVERY scope (loopback: ephemeral
///   per-serve secret; lan: the master secret) — no credential → 401;
/// - a credential-less secret never means "skip" (fail closed);
/// - destinations are allowlisted to known provider hosts; loopback,
///   private, link-local (cloud metadata) and stranger hosts are denied
///   BEFORE any outbound connection exists;
/// - redirects are re-checked per hop; a denied hop is refused;
/// - a disallowed Origin is a 403 rejection, the upstream untouched;
/// - `--bind lan` without a secret refuses to start (named error).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/local_hub.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_serve.dart' show hubLanSecretRefusal, hubServe;

void main() {
  group('relay auth on every scope (SEC-04)', () {
    late LocalHub hub;
    late int port;
    late HttpServer upstream;
    var upstreamHits = 0;

    setUp(() async {
      // The dev opt-in: the REG auth/origin fixtures proxy to a loopback
      // mock; the destination-policy test spins a strict hub inline.
      hub = LocalHub(relayAllowAnyHost: true);
      await hub.start();
      port = hub.url.port;
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamHits = 0;
      unawaited(
        upstream.forEach((req) async {
          upstreamHits++;
          req.response.statusCode = 200;
          req.response.write('ok');
          await req.response.close();
        }),
      );
    });

    tearDown(() async {
      await hub.stop();
      await upstream.close(force: true);
    });

    Map<String, Object?> envelope(String url) => {'url': url};

    Future<HttpClientResponse> post(
      String bearer, {
      String origin = 'https://fa1.dev',
      Object? body,
    }) async {
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/relay'),
      );
      req.headers.set('Origin', origin);
      req.headers.contentType = ContentType.json;
      if (bearer.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $bearer');
      }
      req.write(
        jsonEncode(body ?? envelope('http://127.0.0.1:${upstream.port}/')),
      );
      final res = await req.close();
      await res.drain<void>();
      client.close();
      return res;
    }

    test(
      'AC1: loopback fixture — no credential and wrong credential → 401',
      () async {
        expect((await post('')).statusCode, 401);
        expect((await post('wrong')).statusCode, 401);
        expect(upstreamHits, 0, reason: 'unauthenticated: no upstream work');
        expect(
          (await post(hub.relaySecret!)).statusCode,
          200,
          reason: 'the ephemeral bearer authenticates',
        );
      },
    );

    test(
      'AC1: lan fixture — the master bearer is the relay credential',
      () async {
        await hub.stop();
        hub = LocalHub(
          bind: 'lan',
          masterSecret: 'reg-master',
          relayAllowAnyHost: true,
        );
        await hub.start();
        port = hub.url.port;
        expect((await post('')).statusCode, 401);
        expect((await post('reg-master')).statusCode, 200);
      },
    );

    test('fail closed: a hub with no secret at all serves nothing', () {
      // The decision seam: a null credential must 401 everything — the
      // old contract treated null as "no auth".
      expect(hub.relaySecret, isNotNull);
      expect(hubLanSecretRefusal(bind: 'lan', secret: null), isNotNull);
    });

    test('REG: fail closed over the wire — a null credential answers '
        '401, never proxies (issue #792 AC5)', () async {
      // The exact shape the old hub answered `null` on (loopback skip):
      // the decision seam returning null MUST refuse, on the wire.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((request) async {
          await handleRelayRequest(
            request,
            requireCredential: () => null,
            origin: request.headers.value('origin'),
            allowAnyHost: true,
          );
        }),
      );
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/relay'),
      );
      req.headers.set('Origin', 'https://fa1.dev');
      final res = await req.close();
      expect(res.statusCode, 401);
      expect(
        res.headers.value('connection'),
        'close',
        reason: 'rejected sockets must not be pooled',
      );
      // Hub-GENERATED rejections carry the marker so clients can tell
      // them apart from a forwarded provider 401 (issue #792 review).
      expect(res.headers.value('x-fah-relay'), 'rejection');
      await res.drain<void>();
      client.close();
      expect(upstreamHits, 0, reason: 'refused, not skipped');
    });

    test('AC3: metadata / loopback / private destinations are denied '
        'before any outbound attempt', () async {
      await hub.stop();
      hub = LocalHub(); // strict: no dev opt-in
      await hub.start();
      port = hub.url.port;
      for (final dest in [
        'http://169.254.169.254/latest/meta-data/iam/',
        'http://127.0.0.1:9229/',
        'http://10.0.0.7/',
        'http://192.168.2.2/',
        'http://172.20.1.1/',
      ]) {
        final res = await post(hub.relaySecret!, body: envelope(dest));
        expect(res.statusCode, 403, reason: dest);
        expect(res.headers.value('x-fah-relay'), 'rejection', reason: dest);
        expect(res.headers.value('connection'), 'close', reason: dest);
      }
      expect(upstreamHits, 0);
    });

    test('AC4: a redirect into denied space is refused by the hop verdict; '
        'a disallowed origin is a 403 with the upstream untouched', () async {
      final res = await post(
        hub.relaySecret!,
        origin: 'https://phisher.example',
      );
      expect(res.statusCode, 403);
      expect(upstreamHits, 0);

      // The per-hop verdict is the same kernel as the front door: a
      // 3xx cannot walk the request into internal space.
      expect(
        relayDestinationAllowed(Uri.parse('http://127.0.0.1:1/')),
        isFalse,
        reason: 'the redirect hop verdict: loopback denied',
      );
      expect(
        relayDestinationAllowed(Uri.parse('http://169.254.169.254/x')),
        isFalse,
      );
    });

    test('AC2: --bind lan without a secret refuses to start (named)', () async {
      expect(
        hubLanSecretRefusal(bind: 'lan', secret: null),
        contains('--bind lan requires a master secret'),
      );
      final stateFile = File(
        '${Directory.systemTemp.createTempSync('fah-reg-792').path}/hub.json',
      );
      addTearDown(() => stateFile.parent.delete(recursive: true));
      final code = await hubServe(
        (port: 0, flagSecret: null, flagBind: 'lan', relayAllowAnyHost: false),
        stateFile: stateFile,
        pidFile: File('${stateFile.parent.path}/hub.pid'),
        serveLoop: (_, _) async {},
      );
      expect(code, 1, reason: 'the process refuses to start');
    });
  });
}
