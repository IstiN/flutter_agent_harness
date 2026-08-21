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

  group('isCodeMieBaseUrl', () {
    test('matches the API path with and without /v1', () {
      expect(isCodeMieBaseUrl('https://h.example/code-assistant-api'), isTrue);
      expect(
        isCodeMieBaseUrl('https://h.example/code-assistant-api/v1'),
        isTrue,
      );
      expect(isCodeMieBaseUrl('https://h.example/v1'), isFalse);
      expect(
        isCodeMieBaseUrl('https://code-assistant-api.example/v1'),
        isFalse,
      );
    });
  });

  group('codeMieOrgUrl', () {
    test('strips the API suffix from a stored provider base URL', () {
      expect(
        codeMieOrgUrl('https://h.example/code-assistant-api/v1'),
        'https://h.example',
      );
      expect(
        codeMieOrgUrl('https://h.example/code-assistant-api'),
        'https://h.example',
      );
      expect(codeMieOrgUrl('https://h.example/'), 'https://h.example/');
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
    test('authToken joins all cookies into key=value;key=value', () {
      const credentials = CodeMieSsoCredentials(
        cookies: {'_oauth2_proxy': 'proxy-val', 'session': 's-1'},
        apiUrl: 'https://org/code-assistant-api',
        expiresAt: 0,
      );
      expect(credentials.authToken, '_oauth2_proxy=proxy-val;session=s-1');
      expect(credentials.isExpired, isTrue);
    });

    test('authToken works with codemie_access_token cookie too', () {
      const credentials = CodeMieSsoCredentials(
        cookies: {'codemie_access_token': 'jwt-1'},
        apiUrl: 'https://org/code-assistant-api',
        expiresAt: 0,
      );
      expect(credentials.authToken, 'codemie_access_token=jwt-1');
    });
  });

  group('fetchCodeMieModels', () {
    test('sends the cookie header and parses all id field variants', () async {
      String? cookieHeader;
      String? authHeader;
      final client = http_testing.MockClient((request) async {
        cookieHeader = request.headers['cookie'];
        authHeader = request.headers['authorization'];
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
        '_oauth2_proxy=val;session=s',
        client: client,
      );
      expect(cookieHeader, '_oauth2_proxy=val;session=s');
      expect(authHeader, isNull);
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

  group('fetchCodeMieProjects', () {
    test('merges and deduplicates application fields', () async {
      final client = http_testing.MockClient((request) async {
        expect(request.url.path, endsWith('/v1/user'));
        expect(request.headers['cookie'], 'k=v');
        return http.Response(
          jsonEncode({
            'applications': ['app-a', 'app-b', ' app-a '],
            'applications_admin': ['app-c'],
            'applicationsAdmin': ['app-d'],
            'other': 42,
          }),
          200,
        );
      });
      final projects = await fetchCodeMieProjects(
        'https://org/code-assistant-api',
        'k=v',
        client: client,
      );
      // Deduplicated, trimmed, sorted.
      expect(projects, ['app-a', 'app-b', 'app-c', 'app-d']);
    });

    test('non-2xx throws ConfigException', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('', 500),
      );
      expect(
        () => fetchCodeMieProjects('https://x', 'k=v', client: client),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-object response returns empty list', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('[]', 200),
      );
      final projects = await fetchCodeMieProjects(
        'https://x',
        'k=v',
        client: client,
      );
      expect(projects, isEmpty);
    });
  });
}
