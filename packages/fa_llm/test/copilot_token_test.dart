import 'dart:convert';
import 'dart:async';

import 'package:fa_llm/src/copilot/copilot_token.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('requestCopilotDeviceCode', () {
    test('sends client_id and scope, parses the response', () async {
      late Uri uri;
      late String body;
      late Map<String, String> headers;
      final client = MockClient((request) async {
        uri = request.url;
        body = request.body;
        headers = request.headers;
        return http.Response(
          jsonEncode({
            'device_code': 'dev123',
            'user_code': 'ABCD-1234',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          }),
          200,
        );
      });

      final device = await requestCopilotDeviceCode(client: client);

      expect(uri, Uri.parse('https://github.com/login/device/code'));
      expect(body, contains('client_id=Iv1.b507a08c87ecfe98'));
      expect(body, contains('scope=read%3Auser'));
      expect(headers['accept'], 'application/json');
      expect(device.deviceCode, 'dev123');
      expect(device.userCode, 'ABCD-1234');
      expect(device.verificationUri, 'https://github.com/login/device');
      expect(device.expiresIn, 900);
      expect(device.interval, const Duration(seconds: 5));
    });

    test('client id override wins', () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(
          jsonEncode({
            'device_code': 'd',
            'user_code': 'U',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          }),
          200,
        );
      });
      await requestCopilotDeviceCode(clientId: 'my_client', client: client);
      expect(body, contains('client_id=my_client'));
    });

    test('non-200 device-code request fails clearly', () async {
      final client = MockClient((_) async => http.Response('no', 429));
      await expectLater(
        requestCopilotDeviceCode(client: client),
        throwsA(isA<CopilotDeviceFlowException>()),
      );
    });
  });

  group('pollCopilotAccessToken', () {
    late List<Duration> waits;
    late http.Client client;
    var responses = <Map<String, dynamic>>[];

    setUp(() {
      waits = [];
    });

    Future<String> poll({int? expiresIn, Duration? interval}) =>
        pollCopilotAccessToken(
          deviceCode: 'dev123',
          expiresIn: expiresIn,
          interval: interval ?? const Duration(seconds: 5),
          client: client,
          delay: (d) async {
            waits.add(d);
          },
        );

    test('pending then success waits once and returns the token', () async {
      responses = [
        {'error': 'authorization_pending'},
        {'access_token': 'gho_ok'},
      ];
      var call = 0;
      client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(responses[call++]))),
          200,
        );
      });

      final token = await poll(interval: const Duration(seconds: 5));

      expect(token, 'gho_ok');
      expect(waits, [const Duration(seconds: 5)]);
    });

    test('slow_down bumps the interval by 5s cumulatively', () async {
      responses = [
        {'error': 'authorization_pending'},
        {'error': 'slow_down'},
        {'access_token': 'gho_ok'},
      ];
      var call = 0;
      client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(responses[call++]))),
          200,
        );
      });

      await poll(interval: const Duration(seconds: 5));

      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 10)]);
    });

    test('poll posts the device grant body', () async {
      responses = [
        {'access_token': 'gho_ok'},
      ];
      late String body;
      late Uri uri;
      client = MockClient.streaming((request, bodyStream) async {
        body = await utf8.decodeStream(bodyStream);
        uri = request.url;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(responses.first))),
          200,
        );
      });

      await poll();

      expect(uri, Uri.parse('https://github.com/login/oauth/access_token'));
      expect(
        body,
        contains(
          'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code',
        ),
      );
      expect(body, contains('device_code=dev123'));
      expect(body, contains('client_id=Iv1.b507a08c87ecfe98'));
    });
    test('expired_token fails with a human-readable error', () async {
      client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'error': 'expired_token'}))),
          200,
        );
      });

      await expectLater(
        poll(),
        throwsA(
          isA<CopilotDeviceFlowException>().having(
            (e) => e.message,
            'message',
            contains('expired'),
          ),
        ),
      );
    });

    test('access_denied fails with a human-readable error', () async {
      client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'error': 'access_denied'}))),
          200,
        );
      });

      await expectLater(
        poll(),
        throwsA(
          isA<CopilotDeviceFlowException>().having(
            (e) => e.message,
            'message',
            contains('denied'),
          ),
        ),
      );
    });

    test('unknown poll error fails clearly', () async {
      client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'error': 'weird_error'}))),
          200,
        );
      });

      await expectLater(
        poll(),
        throwsA(
          isA<CopilotDeviceFlowException>().having(
            (e) => e.toString(),
            'toString',
            contains('weird_error'),
          ),
        ),
      );
    });

    test('bounds the loop by expires_in', () async {
      client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(jsonEncode({'error': 'authorization_pending'})),
          ),
          200,
        );
      });

      await expectLater(
        poll(expiresIn: 10, interval: const Duration(seconds: 5)),
        throwsA(isA<CopilotDeviceFlowException>()),
      );
      // 5s + 10s wait attempts before the bound trips; no wait past it.
      expect(waits.length, lessThanOrEqualTo(2));
    });

    test('transport errors propagate', () async {
      client = MockClient.streaming((request, bodyStream) async {
        throw http.ClientException('boom');
      });

      await expectLater(poll(), throwsA(isA<http.ClientException>()));
    });
  });

  group('fetchCopilotToken', () {
    test('exchanges with editor headers and parses the token', () async {
      late Uri uri;
      late Map<String, String> headers;
      final client = MockClient((request) async {
        uri = request.url;
        headers = request.headers;
        return http.Response(
          jsonEncode({
            'token': 'tid=abc;exp=1;sku=copilot_chat',
            'expires_at': 1756400000,
            'refresh_in': 1500,
          }),
          200,
        );
      });

      final token = await fetchCopilotToken(
        githubToken: 'gho_github',
        client: client,
      );

      expect(
        uri,
        Uri.parse('https://api.github.com/copilot_internal/v2/token'),
      );
      expect(headers['authorization'], 'token gho_github');
      expect(headers['accept'], 'application/json');
      expect(headers['editor-version'], 'vscode/1.109.3');
      expect(headers['editor-plugin-version'], 'copilot-chat/0.37.6');
      expect(headers['user-agent'], 'GitHubCopilotChat/0.37.6');
      expect(headers['copilot-integration-id'], 'vscode-chat');
      expect(token.token, 'tid=abc;exp=1;sku=copilot_chat');
      expect(
        token.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1756400000 * 1000, isUtc: true),
      );
      expect(token.refreshIn, 1500);
    });

    test('dead GitHub token (401) is distinguishable', () async {
      final client = MockClient(
        (_) async => http.Response('{"message":"Bad credentials"}', 401),
      );

      await expectLater(
        fetchCopilotToken(githubToken: 'gho_dead', client: client),
        throwsA(isA<CopilotDeadGithubTokenException>()),
      );
    });

    test('other non-200 carries the body', () async {
      final client = MockClient((_) async => http.Response('boom server', 500));

      await expectLater(
        fetchCopilotToken(githubToken: 'gho_x', client: client),
        throwsA(
          isA<CopilotTokenExchangeException>().having(
            (e) => e.message,
            'message',
            contains('boom server'),
          ),
        ),
      );
    });
  });

  group('fetchGithubLogin', () {
    test('returns the login', () async {
      late Map<String, String> headers;
      final client = MockClient((request) async {
        headers = request.headers;
        return http.Response(jsonEncode({'login': 'octocat'}), 200);
      });

      final login = await fetchGithubLogin(
        githubToken: 'gho_github',
        client: client,
      );

      expect(login, 'octocat');
      expect(headers['authorization'], isNotNull);
      expect(headers['accept'], 'application/json');
    });

    test('non-200 fails with the status', () async {
      final client = MockClient((_) async => http.Response('nope', 403));
      await expectLater(
        fetchGithubLogin(githubToken: 'x', client: client),
        throwsA(isA<CopilotAuthException>()),
      );
    });
  });

  test('auth exception toString prefixes the message', () {
    expect(
      CopilotAuthException('hello').toString(),
      'CopilotAuthException: hello',
    );
  });
}
