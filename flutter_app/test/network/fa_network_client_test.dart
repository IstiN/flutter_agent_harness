// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A recorded outgoing request.
class _RecordedRequest {
  _RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

/// Hand-written fake [http.Client]: records every request, replays the
/// scripted responses in order, and throws [StateError] on unexpected calls.
class _FakeHttpClient extends http.BaseClient {
  final List<_RecordedRequest> requests = [];
  final List<http.Response> _responses = [];
  int _index = 0;

  void respond(
    int status, {
    String body = '',
    Map<String, String> headers = const {},
  }) {
    _responses.add(http.Response(body, status, headers: headers));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    requests.add(
      _RecordedRequest(
        request.method,
        request.url,
        Map.of(request.headers),
        utf8.decode(bodyBytes),
      ),
    );
    if (_index >= _responses.length) {
      throw StateError('unexpected request: ${request.method} ${request.url}');
    }
    final res = _responses[_index++];
    return http.StreamedResponse(
      Stream<Uint8List>.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
      request: request,
      reasonPhrase: res.reasonPhrase,
    );
  }
}

const _networkJson =
    '{"id":"net1","name":"fa-team","ownerId":"u1","publicChannels":["c1"],'
    '"createdAt":"2026-01-02T03:04:05Z"}';

void main() {
  late _FakeHttpClient httpClient;
  late FaNetworkClient client;

  FaNetworkClient build({
    String baseUrl = 'https://network.fa1.dev',
    String? jwtToken,
    String? sessionToken,
  }) => FaNetworkClient(
    baseUrl: Uri.parse(baseUrl),
    httpClient: httpClient,
    jwtToken: jwtToken,
    sessionToken: sessionToken,
  );

  setUp(() {
    httpClient = _FakeHttpClient();
    client = build();
  });

  group('url joining and auth headers', () {
    test('trailing slash in baseUrl does not produce double slashes', () async {
      client = build(baseUrl: 'https://network.fa1.dev/');
      httpClient.respond(200, body: '{"status":"ok"}');
      await client.health();
      expect(
        httpClient.requests.single.url.toString(),
        'https://network.fa1.dev/healthz',
      );
    });

    test(
      'management routes prefer the JWT; member routes prefer the session',
      () async {
        client = build(jwtToken: 'jwt-tok', sessionToken: 'sess-tok');
        httpClient.respond(
          201,
          body: '{"id":"n","name":"x","ownerId":"u","publicChannels":[]}',
        );
        await client.createNetwork(name: 'x', password: 'hunter2hunter2');
        expect(
          httpClient.requests.single.headers['authorization'],
          'Bearer jwt-tok',
        );

        httpClient.respond(200, body: '[]');
        await client.listMembers('net1');
        expect(
          httpClient.requests.last.headers['authorization'],
          'Bearer sess-tok',
        );
      },
    );

    test('token setters swap the bearer', () async {
      client = build(sessionToken: 'a');
      client.session = 'b';
      httpClient.respond(200, body: '[]');
      await client.listMembers('net1');
      expect(httpClient.requests.single.headers['authorization'], 'Bearer b');
      client.jwt = 'j';
      httpClient.respond(204);
      await client.deleteNetwork('net1');
      expect(httpClient.requests.last.headers['authorization'], 'Bearer j');
    });
  });

  group('endpoints', () {
    test('health returns true on ok', () async {
      httpClient.respond(200, body: '{"status":"ok"}');
      expect(await client.health(), isTrue);
      expect(httpClient.requests.single.method, 'GET');
    });

    test(
      'createNetwork posts name+password and parses joinCredentials',
      () async {
        httpClient.respond(
          201,
          // The server's real envelope: {network: {...}, joinCredentials: {...}}
          // (fa_network internal/server/networks.go createNetwork).
          body:
              '{"network":{"id":"net1","name":"fa-team","ownerId":"u1",'
              '"publicChannels":[]},'
              '"joinCredentials":{"networkId":"net1","password":"pw123456"}}',
        );
        final result = await client.createNetwork(
          name: 'fa-team',
          password: 'hunter2hunter2',
        );
        expect(result.network.id, 'net1');
        expect(result.joinCredentials?.networkId, 'net1');
        expect(result.joinCredentials?.password, 'pw123456');
        final req = httpClient.requests.single;
        expect(req.method, 'POST');
        expect(req.url.path, '/api/networks');
        expect(jsonDecode(req.body), {
          'name': 'fa-team',
          'password': 'hunter2hunter2',
        });
      },
    );

    test('management routes never fall back to a session token (a bare '
        'session token earns a confusing invalid token 401 — send no '
        'header instead)', () async {
      final sessionOnly = FaNetworkClient(
        baseUrl: Uri.parse('https://network.fa1.dev'),
        httpClient: httpClient,
        sessionToken: 'st-1',
      );
      httpClient.respond(
        401,
        body:
            '{"error":{"code":"unauthorized","message":"auth token required"}}',
      );
      await expectLater(
        sessionOnly.createNetwork(name: 'fa-team', password: 'supersecret1'),
        throwsA(isA<FaNetworkException>()),
      );
      expect(httpClient.requests.single.headers['authorization'], isNull);
    });

    test(
      'joinNetwork posts password+displayName and parses JoinResult',
      () async {
        httpClient.respond(
          200,
          body:
              '{"sessionToken":"sess","identity":{"id":"m1",'
              '"class":"guest","displayName":"G"},"network":$_networkJson}',
        );
        final result = await client.joinNetwork(
          'net1',
          password: 'hunter2hunter2',
          displayName: 'G',
        );
        expect(result.sessionToken, 'sess');
        expect(result.identity.memberClass, MemberClass.guest);
        expect(result.network?.name, 'fa-team');
        final req = httpClient.requests.single;
        expect(req.url.path, '/api/networks/net1/join');
        expect(jsonDecode(req.body), {
          'password': 'hunter2hunter2',
          'displayName': 'G',
        });
      },
    );

    test('getNetwork parses Network', () async {
      httpClient.respond(200, body: _networkJson);
      final n = await client.getNetwork('net1');
      expect(n.name, 'fa-team');
      expect(httpClient.requests.single.method, 'GET');
    });

    test('updateNetwork patches and parses Network', () async {
      httpClient.respond(200, body: _networkJson);
      final n = await client.updateNetwork('net1', name: 'new-name');
      expect(n.id, 'net1');
      final req = httpClient.requests.single;
      expect(req.method, 'PATCH');
      expect(jsonDecode(req.body), {'name': 'new-name'});
    });

    test('updateNetwork toggles the public-directory listing', () async {
      httpClient.respond(
        200,
        body:
            '{"id":"net1","name":"fa-team","ownerId":"u1",'
            '"publicChannels":[],"public":true}',
      );
      final n = await client.updateNetwork('net1', isPublic: true);
      expect(n.isPublic, isTrue);
      expect(jsonDecode(httpClient.requests.single.body), {'public': true});
    });

    test('listPublicNetworks is anonymous and parses the envelope', () async {
      client = build(jwtToken: 'jwt-tok', sessionToken: 'sess-tok');
      httpClient.respond(
        200,
        body:
            '{"items":[{"id":"pub-1","name":"open-hub",'
            '"publicChannels":3,"memberCount":42}],"nextCursor":"p2"}',
      );
      final page = await client.listPublicNetworks(limit: 10, cursor: 'p1');
      expect(page, isNotNull);
      expect(page!.items.single.id, 'pub-1');
      expect(page.items.single.name, 'open-hub');
      expect(page.items.single.publicChannelCount, 3);
      expect(page.items.single.memberCount, 42);
      expect(page.nextCursor, 'p2');
      final req = httpClient.requests.single;
      expect(req.method, 'GET');
      expect(req.url.path, '/api/networks/public');
      expect(req.url.queryParameters, {'limit': '10', 'cursor': 'p1'});
      // Anonymous route: no bearer even when both tokens are set.
      expect(req.headers.containsKey('authorization'), isFalse);
    });

    test('listPublicNetworks: an empty nextCursor is the last page', () async {
      httpClient.respond(200, body: '{"items":[],"nextCursor":""}');
      final page = await client.listPublicNetworks();
      expect(page, isNotNull);
      expect(page!.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(httpClient.requests.single.url.query, isEmpty);
    });

    test(
      'listPublicNetworks returns null on 404/429 instead of throwing',
      () async {
        httpClient.respond(
          404,
          body: '{"error":{"code":"not_found","message":"nope"}}',
        );
        expect(await client.listPublicNetworks(), isNull);
        httpClient.respond(
          429,
          body: '{"error":{"code":"throttled","message":"slow down"}}',
          headers: {'retry-after': '30'},
        );
        expect(await client.listPublicNetworks(), isNull);
      },
    );

    test('deleteNetwork accepts 204', () async {
      httpClient.respond(204);
      await client.deleteNetwork('net1');
      expect(httpClient.requests.single.method, 'DELETE');
    });

    test('addAdmin posts userId and parses Member', () async {
      httpClient.respond(
        201,
        body:
            '{"id":"u2","class":"admin","displayName":"B",'
            '"presence":"offline"}',
      );
      final m = await client.addAdmin('net1', userId: 'u2');
      expect(m.memberClass, MemberClass.admin);
      expect(jsonDecode(httpClient.requests.single.body), {'userId': 'u2'});
    });

    test('removeAdmin deletes', () async {
      httpClient.respond(204);
      await client.removeAdmin('net1', 'u2');
      expect(
        httpClient.requests.single.url.path,
        '/api/networks/net1/admins/u2',
      );
    });

    test('listMembers parses the roster', () async {
      httpClient.respond(
        200,
        body:
            '[{"id":"m1","class":"owner","displayName":"A",'
            '"presence":"live"},{"id":"m2","class":"agent",'
            '"displayName":"B","presence":"offline"}]',
      );
      final members = await client.listMembers('net1');
      expect(members, hasLength(2));
      expect(members[1].memberClass, MemberClass.agent);
    });

    test('listChannels parses channels', () async {
      httpClient.respond(
        200,
        body:
            '[{"id":"c1","networkId":"net1","name":"general",'
            '"public":false}]',
      );
      final channels = await client.listChannels('net1');
      expect(channels.single.name, 'general');
      expect(channels.single.isPublic, isFalse);
    });

    test('createChannel posts the create request', () async {
      httpClient.respond(
        201,
        body:
            '{"id":"c1","networkId":"net1","name":"show","public":true,'
            '"retentionDays":7}',
      );
      final c = await client.createChannel(
        'net1',
        name: 'show',
        isPublic: true,
        retentionDays: 7,
      );
      expect(c.isPublic, isTrue);
      expect(c.retentionDays, 7);
      expect(jsonDecode(httpClient.requests.single.body), {
        'name': 'show',
        'public': true,
        'retentionDays': 7,
      });
    });

    test('getChannel parses channel', () async {
      httpClient.respond(
        200,
        body: '{"id":"c1","networkId":"net1","public":false}',
      );
      final c = await client.getChannel('c1');
      expect(c.networkId, 'net1');
      expect(httpClient.requests.single.url.path, '/api/channels/c1');
    });

    test('updateChannel sends public/acl/clearRetention', () async {
      httpClient.respond(
        200,
        body: '{"id":"c1","networkId":"net1","public":true}',
      );
      await client.updateChannel(
        'c1',
        isPublic: true,
        acl: const ['k1', 'k2'],
        clearRetention: true,
      );
      expect(jsonDecode(httpClient.requests.single.body), {
        'public': true,
        'acl': ['k1', 'k2'],
        'clearRetention': true,
      });
    });

    test('deleteChannel deletes', () async {
      httpClient.respond(204);
      await client.deleteChannel('c1');
      expect(httpClient.requests.single.url.path, '/api/channels/c1');
    });

    test('listMessages passes cursor+limit and parses the page', () async {
      httpClient.respond(
        200,
        body:
            '{"items":[{"id":"e1","channelId":"c1","senderId":"m1",'
            '"payload":"aGk=","createdAt":"2026-01-02T03:04:05Z"}],'
            '"nextCursor":"cur2"}',
      );
      final page = await client.listMessages('c1', cursor: 'cur1', limit: 10);
      expect(page.items.single.payload, 'aGk=');
      expect(page.nextCursor, 'cur2');
      final uri = httpClient.requests.single.url;
      expect(uri.queryParameters['cursor'], 'cur1');
      expect(uri.queryParameters['limit'], '10');
    });

    test('sendMessage posts the envelope and parses the 202 echo', () async {
      httpClient.respond(
        202,
        body:
            '{"id":"e1","channelId":"c1","senderId":"m1","payload":"aGk=",'
            '"mentions":["a1"],"createdAt":"2026-01-02T03:04:05Z"}',
      );
      final e = await client.sendMessage(
        'c1',
        id: 'e1',
        payload: 'aGk=',
        mentions: const ['a1'],
      );
      expect(e.mentions, ['a1']);
      expect(jsonDecode(httpClient.requests.single.body), {
        'id': 'e1',
        'payload': 'aGk=',
        'mentions': ['a1'],
      });
    });

    test('listAgents parses the agent roster', () async {
      httpClient.respond(
        200,
        body:
            '[{"agentId":"a1","displayName":"Helper","presence":"offline",'
            '"wakeupRegistered":true}]',
      );
      final agents = await client.listAgents('net1');
      expect(agents.single.agentId, 'a1');
      expect(agents.single.wakeupRegistered, isTrue);
    });

    group('enrollAgent', () {
      const enrollBody =
          '{"name":"ops-bot","hubUrl":"wss://hub.fa1.dev/ws",'
          '"clientSecret":"sk_enroll_123",'
          '"enrolledAt":"2026-02-03T04:05:06Z",'
          '"note":"store clientSecret now - never returned again"}';

      test('posts the name as a management call and parses the one-time '
          'credential', () async {
        client = build(jwtToken: 'jwt-1', sessionToken: 'sess-1');
        httpClient.respond(201, body: enrollBody);
        final enrollment = await client.enrollAgent('net1', name: 'ops-bot');
        expect(enrollment.name, 'ops-bot');
        expect(enrollment.hubUrl, 'wss://hub.fa1.dev/ws');
        expect(enrollment.clientSecret, 'sk_enroll_123');
        expect(enrollment.enrolledAt, '2026-02-03T04:05:06Z');
        expect(enrollment.note, contains('never returned again'));
        final req = httpClient.requests.single;
        expect(req.method, 'POST');
        expect(req.url.path, '/api/networks/net1/agents/enroll');
        expect(jsonDecode(req.body), {'name': 'ops-bot'});
        // Management class only — the JWT wins over the session token.
        expect(req.headers['authorization'], 'Bearer jwt-1');
      });

      test('tolerates a missing note', () async {
        httpClient.respond(
          201,
          body:
              '{"name":"ops-bot","hubUrl":"wss://hub.fa1.dev/ws",'
              '"clientSecret":"sk_enroll_123",'
              '"enrolledAt":"2026-02-03T04:05:06Z"}',
        );
        final enrollment = await client.enrollAgent('net1', name: 'ops-bot');
        expect(enrollment.note, isNull);
      });

      Future<FaNetworkException> captureEnrollError(
        int status,
        String body,
      ) async {
        httpClient.respond(status, body: body);
        try {
          await client.enrollAgent('net1', name: 'ops-bot');
        } on FaNetworkException catch (e) {
          return e;
        }
        fail('expected FaNetworkException');
      }

      test(
        '403 forbidden_by_class surfaces the server code + message',
        () async {
          final e = await captureEnrollError(
            403,
            '{"error":{"code":"forbidden_by_class",'
            '"message":"owner or admin only"}}',
          );
          expect(e.statusCode, 403);
          expect(e.code, 'forbidden_by_class');
          expect(e.message, 'owner or admin only');
        },
      );

      test('400 invalid_credentials (bad name) maps its code', () async {
        final e = await captureEnrollError(
          400,
          '{"error":{"code":"invalid_credentials",'
          '"message":"invalid agent name"}}',
        );
        expect(e.statusCode, 400);
        expect(e.code, 'invalid_credentials');
      });

      test('503 hub_unavailable maps its code', () async {
        final e = await captureEnrollError(
          503,
          '{"error":{"code":"hub_unavailable","message":"hub offline"}}',
        );
        expect(e.statusCode, 503);
        expect(e.code, 'hub_unavailable');
      });
    });

    test('getWakeup parses the registration', () async {
      httpClient.respond(
        200,
        body: '{"url":"https://hook.example/x","debounceSeconds":300}',
      );
      final r = await client.getWakeup('net1', 'a1');
      expect(r.debounceSeconds, 300);
      expect(
        httpClient.requests.single.url.path,
        '/api/networks/net1/agents/a1/wakeups',
      );
    });

    test('registerWakeup posts url+secret+debounce', () async {
      httpClient.respond(
        201,
        body: '{"url":"https://hook.example/x","debounceSeconds":60}',
      );
      final r = await client.registerWakeup(
        'net1',
        'a1',
        url: 'https://hook.example/x',
        secret: 's3cr3t',
        debounceSeconds: 60,
      );
      expect(r.url, 'https://hook.example/x');
      expect(jsonDecode(httpClient.requests.single.body), {
        'url': 'https://hook.example/x',
        'secret': 's3cr3t',
        'debounceSeconds': 60,
      });
    });

    test('deleteWakeup deletes', () async {
      httpClient.respond(204);
      await client.deleteWakeup('net1', 'a1');
      expect(httpClient.requests.single.method, 'DELETE');
    });

    test('listWakeupLog parses dispatches and passes the cursor', () async {
      httpClient.respond(
        200,
        body:
            '{"items":[{"agentId":"a1","at":"2026-01-02T03:04:05Z",'
            '"outcome":"delivered"}],"nextCursor":"w2"}',
      );
      final page = await client.listWakeupLog('net1', cursor: 'w1');
      expect(page.items.single.outcome, 'delivered');
      expect(page.nextCursor, 'w2');
      expect(
        httpClient.requests.single.url.path,
        '/api/networks/net1/wakeups/log',
      );
      expect(httpClient.requests.single.url.queryParameters['cursor'], 'w1');
    });

    test('devLogin posts credentials and returns the token', () async {
      httpClient.respond(200, body: '{"token":"dev-tok"}');
      final token = await client.devLogin(login: 'dev', password: 'dev');
      expect(token, 'dev-tok');
      final req = httpClient.requests.single;
      expect(req.url.path, '/api/dev/login');
      expect(jsonDecode(req.body), {'login': 'dev', 'password': 'dev'});
      expect(req.headers.containsKey('authorization'), isFalse);
    });
  });

  group('auth endpoints (issue #955 iteration 3)', () {
    test('oauthProviders parses a bare list, anonymously', () async {
      httpClient.respond(200, body: '["google","github"]');
      final providers = await build().oauthProviders();
      expect(providers, ['google', 'github']);
      final req = httpClient.requests.single;
      expect(req.url.path, '/api/oauth-proxy/providers');
      expect(req.headers.containsKey('authorization'), isFalse);
    });

    test('oauthProviders parses {providers:[...]} and '
        '{enabledProviders:[...]}', () async {
      httpClient.respond(200, body: '{"providers":["apple"]}');
      expect(await build().oauthProviders(), ['apple']);

      httpClient.respond(
        200,
        body: '{"authenticationMode":"oauth","enabledProviders":["microsoft"]}',
      );
      expect(await build().oauthProviders(), ['microsoft']);
    });

    test(
      'oauthInitiate posts the proxy contract and parses auth_url',
      () async {
        httpClient.respond(
          200,
          body:
              '{"auth_url":"https://accounts.google.com/o/oauth2?state=st-1",'
              '"state":"st-1","expires_in":600}',
        );
        final result = await build().oauthInitiate(
          provider: 'google',
          redirectUri: Uri.parse('http://127.0.0.1:0/callback'),
        );
        expect(result.authUrl.host, 'accounts.google.com');
        expect(result.state, 'st-1');
        expect(result.expiresIn, 600);
        final req = httpClient.requests.single;
        expect(req.url.path, '/api/oauth-proxy/initiate');
        expect(jsonDecode(req.body), {
          'provider': 'google',
          'client_redirect_uri': 'http://127.0.0.1:0/callback',
          'client_type': 'desktop',
          'environment': 'prod',
        });
        expect(req.headers.containsKey('authorization'), isFalse);
      },
    );

    test('oauthExchange posts code+state and folds expiresIn into an '
        'absolute instant', () async {
      httpClient.respond(
        200,
        body:
            '{"accessToken":"at-1","refreshToken":"rt-1","expiresIn":3600,'
            '"refreshExpiresIn":86400,"tokenType":"Bearer"}',
      );
      final now = DateTime.utc(2026, 2, 1, 12);
      final bundle = await build().oauthExchange(
        code: 'temp-1',
        state: 'st-1',
        now: now,
      );
      expect(bundle.accessToken, 'at-1');
      expect(bundle.refreshToken, 'rt-1');
      expect(bundle.expiresAt, now.add(const Duration(hours: 1)));
      expect(bundle.refreshExpiresAt, now.add(const Duration(days: 1)));
      final req = httpClient.requests.single;
      expect(req.url.path, '/api/oauth-proxy/exchange');
      expect(jsonDecode(req.body), {'code': 'temp-1', 'state': 'st-1'});
    });

    test('oauthExchange surfaces the server error shape', () async {
      httpClient.respond(
        400,
        body:
            '{"error":{"code":"invalid_grant",'
            '"message":"code expired or unknown"}}',
      );
      await expectLater(
        build().oauthExchange(code: 'bad', state: 'st-1'),
        throwsA(
          isA<FaNetworkException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.code, 'code', 'invalid_grant')
              .having((e) => e.message, 'message', 'code expired or unknown'),
        ),
      );
    });

    test('refreshTokens posts the refresh token and tolerates a missing '
        'refresh lifetime', () async {
      httpClient.respond(
        200,
        body: '{"accessToken":"at-2","refreshToken":"rt-2","expiresIn":3600}',
      );
      final now = DateTime.utc(2026, 2, 1, 12);
      final bundle = await build().refreshTokens('rt-1', now: now);
      expect(bundle.accessToken, 'at-2');
      expect(bundle.refreshExpiresAt, isNull);
      final req = httpClient.requests.single;
      expect(req.url.path, '/api/auth/refresh');
      expect(jsonDecode(req.body), {'refreshToken': 'rt-1'});
    });

    test('authUser sends the explicit Bearer token and parses the '
        'profile', () async {
      httpClient.respond(
        200,
        body:
            '{"authenticated":true,"id":"u1","email":"a@b.dev",'
            '"name":"Alice","pictureUrl":"https://img/a.png",'
            '"provider":"google"}',
      );
      final profile = await build(jwtToken: 'jwt-other').authUser('at-1');
      expect(profile.id, 'u1');
      expect(profile.email, 'a@b.dev');
      expect(profile.name, 'Alice');
      expect(profile.pictureUrl, 'https://img/a.png');
      expect(profile.provider, 'google');
      final req = httpClient.requests.single;
      expect(req.url.path, '/api/auth/user');
      expect(req.headers['authorization'], 'Bearer at-1');
    });

    test('authUser throws when the profile carries neither name nor '
        'email', () async {
      httpClient.respond(200, body: '{"authenticated":true,"id":"u1"}');
      await expectLater(
        build().authUser('at-1'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('error mapping', () {
    Future<FaNetworkException> capture(
      int status, {
      String body = '',
      Map<String, String> headers = const {},
    }) async {
      httpClient.respond(status, body: body, headers: headers);
      try {
        await client.getNetwork('net1');
      } on FaNetworkException catch (e) {
        return e;
      }
      fail('expected FaNetworkException');
    }

    test('403 invalid_credentials carries the Retry-After seconds', () async {
      final e = await capture(
        403,
        body:
            '{"error":{"code":"invalid_credentials",'
            '"message":"wrong password"}}',
        headers: {'retry-after': '17'},
      );
      expect(e.statusCode, 403);
      expect(e.code, 'invalid_credentials');
      expect(e.message, 'wrong password');
      expect(e.retryAfterSeconds, 17);
    });

    test('403 channel_read_only maps its code', () async {
      final e = await capture(
        403,
        body: '{"error":{"code":"channel_read_only","message":"read only"}}',
      );
      expect(e.code, 'channel_read_only');
      expect(e.retryAfterSeconds, isNull);
    });

    test('429 throttled maps code and Retry-After', () async {
      final e = await capture(
        429,
        body: '{"error":{"code":"throttled","message":"slow down"}}',
        headers: {'retry-after': '5'},
      );
      expect(e.code, 'throttled');
      expect(e.retryAfterSeconds, 5);
    });

    test('404 not_found maps its code', () async {
      final e = await capture(
        404,
        body: '{"error":{"code":"not_found","message":"nope"}}',
      );
      expect(e.code, 'not_found');
    });

    test('non-Error 5xx body maps to http_5xx', () async {
      final e = await capture(502, body: 'bad gateway');
      expect(e.code, 'http_5xx');
      expect(e.statusCode, 502);
    });

    test('malformed JSON error body still raises FaNetworkException', () async {
      final e = await capture(400, body: '{not json');
      expect(e.code, 'http_400');
      expect(e.statusCode, 400);
    });

    test('malformed JSON success body raises a FormatException', () async {
      httpClient.respond(200, body: '{not json');
      await expectLater(client.getNetwork('net1'), throwsFormatException);
    });
  });
}
