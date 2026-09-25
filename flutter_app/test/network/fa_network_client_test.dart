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
          body:
              '{"id":"net1","name":"fa-team","ownerId":"u1",'
              '"publicChannels":[],'
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
