// SEC-01, shared HTTP layer: redirects are decided INSIDE
// `sendProviderRequest`, never by the underlying client. `followRedirects`
// is forced off so a cross-origin 3xx can never re-send
// `Authorization: Bearer …` to the redirect target — some injected clients
// (CupertinoClient/URLSession on the app hosts) follow cross-host by
// default and keep the header. Same-origin hops are re-issued verbatim
// (method, body, headers — credentials stay on-origin); anything crossing
// origins fails as a ProviderHttpError the SSO/moved-URL diagnostics
// already understand.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A scripted redirect/testing client recording every outbound request.
final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.respond);

  final Future<http.StreamedResponse> Function(int call, http.BaseRequest r)
      respond;

  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return respond(requests.length, request);
  }
}

http.Request _post(String url) => http.Request('POST', Uri.parse(url))
  ..headers['authorization'] = 'Bearer sk-protected'
  ..headers['content-type'] = 'application/json'
  ..body = '{"model":"m","stream":true}';

http.StreamedResponse _empty(int status, [Map<String, String> headers = const {}]) =>
    http.StreamedResponse(Stream.value(utf8.encode('')), status, headers: headers);

void main() {
  group('sendProviderRequest — cross-origin redirect auth-stripping (SEC-01)',
      () {
    test('a 302 to another host FAILS: exactly one request, never re-sent',
        () async {
      final client = _RecordingClient((call, request) async =>
          call == 1
              ? _empty(302, {'location': 'https://attacker.example/v1/steal'})
              : _empty(200));
      await expectLater(
        sendProviderRequest(client, _post('https://api.example.com/v1/chat'), null),
        throwsA(
          isA<ProviderHttpError>()
              .having((e) => e.statusCode, 'statusCode', 302)
              .having((e) => e.redirectLocation, 'redirectLocation',
                  'https://attacker.example/v1/steal'),
        ),
      );
      expect(client.requests, hasLength(1),
          reason: 'the request must never be re-issued at the cross-origin '
              'target');
      expect(client.requests.single.url.host, 'api.example.com');
    });

    test('the failure formats as the familiar redirect/SSO diagnosis',
        () async {
      final client = _RecordingClient((call, request) async => _empty(
          302, {'location': 'https://login.example.org/sso?rd=%2Fv1'}));
      try {
        await sendProviderRequest(
            client, _post('https://api.example.com/v1/chat'), null);
        fail('expected ProviderHttpError');
      } on ProviderHttpError catch (error) {
        final message = formatProviderError(error);
        expect(message, contains('302'));
        expect(message, contains('redirect'));
        expect(message, contains('login.example.org'));
      }
    });

    test('a cross-origin 3xx on a GET fails the same way (no silent '
        'auto-follow)', () async {
      final client = _RecordingClient((call, request) async => call == 1
          ? _empty(301, {'location': 'https://other.example.com/models'})
          : _empty(200));
      final request = http.Request(
          'GET', Uri.parse('https://api.example.com/v1/models'))
        ..headers['authorization'] = 'Bearer sk-protected';
      await expectLater(
        sendProviderRequest(client, request, null),
        throwsA(isA<ProviderHttpError>()),
      );
      expect(client.requests, hasLength(1));
    });

    test('a same-origin 302 is followed verbatim: method, body, auth', () async {
      final client = _RecordingClient((call, request) async => call == 1
          ? _empty(302, {'location': 'https://api.example.com/v2/chat'})
          : _empty(200, {'content-type': 'text/event-stream'}));
      final response = await sendProviderRequest(
          client, _post('https://api.example.com/v1/chat'), null);
      expect(response.statusCode, 200);
      expect(client.requests, hasLength(2));
      final followed = client.requests[1];
      expect(followed.url.toString(), 'https://api.example.com/v2/chat');
      expect(followed.method, 'POST');
      expect(followed.headers['authorization'], 'Bearer sk-protected');
      expect(followed.headers['content-type'], contains('application/json'));
      expect(
        utf8.decode((followed as http.Request).bodyBytes),
        '{"model":"m","stream":true}',
      );
    });

    test('a relative same-origin Location resolves against the request',
        () async {
      final client = _RecordingClient((call, request) async => call == 1
          ? _empty(307, {'location': '/v1/chat/completions'})
          : _empty(200, {'content-type': 'text/event-stream'}));
      final response = await sendProviderRequest(
          client, _post('https://api.example.com/v1/chat'), null);
      expect(response.statusCode, 200);
      expect(client.requests[1].url.toString(),
          'https://api.example.com/v1/chat/completions');
    });

    test('the same-origin follow loop is capped (5 hops, then an error)',
        () async {
      final client = _RecordingClient(
          (call, request) async => _empty(302, {
                'location':
                    'https://api.example.com/v1/hop$call',
              }));
      await expectLater(
        sendProviderRequest(client, _post('https://api.example.com/v1/chat'), null),
        throwsA(isA<ProviderHttpError>()),
      );
      expect(client.requests.length, 6,
          reason: 'the original + 5 followed hops, then fail loudly');
    });

    test('a 3xx without a Location fails as a provider error', () async {
      final client = _RecordingClient((call, request) async => _empty(302));
      await expectLater(
        sendProviderRequest(client, _post('https://api.example.com/v1/chat'), null),
        throwsA(
          isA<ProviderHttpError>().having(
              (e) => e.redirectLocation, 'redirectLocation', isNull),
        ),
      );
    });

    test('the 200-with-HTML SSO guard still applies after a followed hop',
        () async {
      final client = _RecordingClient((call, request) async => call == 1
          ? _empty(302, {'location': 'https://api.example.com/login'})
          : _empty(200, {'content-type': 'text/html'}));
      await expectLater(
        sendProviderRequest(client, _post('https://api.example.com/v1/chat'), null),
        throwsA(
          isA<ProviderHttpError>()
              .having((e) => e.answeredHtml, 'answeredHtml', isTrue),
        ),
      );
    });

    test('a plain 200 event stream still validates as before', () async {
      final client = _RecordingClient(
          (call, request) async => _empty(200, {'content-type': 'text/event-stream'}));
      final response = await sendProviderRequest(
          client, _post('https://api.example.com/v1/chat'), null);
      expect(response.statusCode, 200);
      expect(client.requests, hasLength(1));
    });
  });
}
