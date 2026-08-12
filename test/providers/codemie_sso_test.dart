import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('codeMieApiBase', () {
    test('appends the API path to a bare org URL', () {
      expect(
        codeMieApiBase('https://codemie.lab.epam.com'),
        'https://codemie.lab.epam.com/code-assistant-api',
      );
      expect(
        codeMieApiBase('https://codemie.lab.epam.com/'),
        'https://codemie.lab.epam.com/code-assistant-api',
      );
    });

    test('is idempotent', () {
      const api = 'https://host.example/code-assistant-api';
      expect(codeMieApiBase(api), api);
      expect(codeMieApiBase('$api/'), api);
    });
  });

  group('buildCodeMieSsoUrl', () {
    test('embeds the callback port in the login path', () {
      expect(
        buildCodeMieSsoUrl('https://org.example', 4567),
        'https://org.example/code-assistant-api/v1/auth/login/4567',
      );
    });
  });

  group('decodeCodeMieSsoToken', () {
    test('decodes the base64 JSON cookies object', () {
      final token = base64.encode(
        utf8.encode(
          jsonEncode({
            'cookies': {'codemie_access_token': 'jwt-1', 'session': 's-1'},
          }),
        ),
      );
      expect(decodeCodeMieSsoToken(token), {
        'codemie_access_token': 'jwt-1',
        'session': 's-1',
      });
    });

    test('rejects malformed tokens', () {
      expect(() => decodeCodeMieSsoToken('not-base64!'), throwsFormatException);
      expect(
        () => decodeCodeMieSsoToken(base64.encode(utf8.encode('{"x":1}'))),
        throwsFormatException,
      );
    });
  });

  group('deriveCodeMieExpiresAt', () {
    test('reads the exp claim of codemie_access_token', () {
      final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final payload = base64Url.encode(utf8.encode(jsonEncode({'exp': exp})));
      final jwt = 'h.$payload.s';
      final result = deriveCodeMieExpiresAt({'codemie_access_token': jwt});
      expect(result, exp * 1000);
    });

    test('falls back to ~24h without a usable JWT', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final result = deriveCodeMieExpiresAt(const {});
      expect(result, greaterThan(before + 23 * 3600000));
    });
  });

  group('CodeMieSsoCredentials', () {
    test('accessToken reads the codemie_access_token cookie', () {
      const credentials = CodeMieSsoCredentials(
        cookies: {'codemie_access_token': 'jwt-1'},
        apiUrl: 'https://org/code-assistant-api',
        expiresAt: 0,
      );
      expect(credentials.accessToken, 'jwt-1');
      expect(credentials.isExpired, isTrue);
    });
  });

  group('fetchCodeMieModels', () {
    test('sends the bearer token and parses all id field variants', () async {
      String? authorization;
      final client = http_testing.MockClient((request) async {
        authorization = request.headers['authorization'];
        expect(request.url.path, endsWith('/v1/llm_models'));
        expect(request.url.queryParameters['include_all'], 'true');
        return http.Response(
          jsonEncode([
            {'id': 'gpt-4o'},
            {'base_name': 'claude-sonnet-4'},
            {'deployment_name': 'gemini-2.5-pro'},
            {'id': ''},
            'garbage',
          ]),
          200,
        );
      });
      final models = await fetchCodeMieModels(
        'https://org/code-assistant-api/v1',
        'jwt-1',
        client: client,
      );
      expect(authorization, 'Bearer jwt-1');
      expect(models, ['gpt-4o', 'claude-sonnet-4', 'gemini-2.5-pro']);
    });

    test('401 raises a re-login hint', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('', 401),
      );
      expect(
        () => fetchCodeMieModels('https://x/v1', 'jwt', client: client),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('codemie sso'),
          ),
        ),
      );
    });
  });
}
