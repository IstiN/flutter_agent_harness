// Pure-Dart integration tests for the CodeMie SSO → cookie-auth pipeline.
//
// Verifies the full flow: SSO returns _oauth2_proxy cookies → guided setup
// runs → projects/models fetched with Cookie header → provider switched with
// cookie-header model auth (not Bearer).
//
// Uses the same FakeCliIO / AgentCli pattern as the CLI provider tests.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/testing.dart' as http_testing;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor({
    required StreamFunction streamFunction,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    Future<CodeMieSsoCredentials?> Function(
      String codeMieUrl,
      void Function(String) onStatus,
    )?
    codeMieSsoAuthenticateFn,
    Future<String?> Function(
      String apiBase,
      String cookie,
      Future<String?> Function(
        String title,
        List<(String, String, String)> options,
      )
      pickOption,
      Future<String?> Function(String question, {bool secret}) askLine,
    )?
    codeMieGuidedSetupFn,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: (_) => null,
        secureKeys: secureKeys,
        customProviders: customProviders,
        providerKind: 'openai-completions',
        codeMieSsoAuthenticateFn: codeMieSsoAuthenticateFn,
        codeMieGuidedSetupFn: codeMieGuidedSetupFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('CodeMie SSO cookie-auth integration', () {
    test(
      'SSO with _oauth2_proxy cookie stores full cookie string and sets cookie header',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);

        // Track what the guided setup receives.
        var guidedSetupCookie = '';

        final cli = cliFor(
          streamFunction: fake.call,
          secureKeys: cache,
          customProviders: registry,
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            return const CodeMieSsoCredentials(
              cookies: {
                '_oauth2_proxy': 'proxy-session-val',
                'KEYCLOAK_IDENTITY': 'kc-identity',
              },
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
          codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
            guidedSetupCookie = cookie;
            return 'gpt-4o';
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie sso');
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        // The guided setup received the full cookie string.
        expect(
          guidedSetupCookie,
          '_oauth2_proxy=proxy-session-val;KEYCLOAK_IDENTITY=kc-identity',
        );

        // The stored key is the full cookie string.
        final entry = registry.find('codemie.lab.epam.com');
        expect(entry, isNotNull);
        expect(store.map[entry!.keyName], guidedSetupCookie);

        // The model uses cookie-header auth.
        expect(cli.agent.state.model.headers, {'cookie': guidedSetupCookie});

        // The model endpoint is the CodeMie v1 API.
        expect(
          cli.agent.state.model.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
      },
    );

    test('fetchCodeMieModels sends Cookie header, not Authorization', () async {
      String? cookieHeader;
      String? authHeader;
      final client = http_testing.MockClient((request) async {
        cookieHeader = request.headers['cookie'];
        authHeader = request.headers['authorization'];
        return http.Response('[{"id":"gpt-4o"},{"base_name":"claude"}]', 200);
      });

      final cookie = '_oauth2_proxy=val;KEYCLOAK_IDENTITY=id';
      final models = await fetchCodeMieModels(
        'https://codemie.lab.epam.com/code-assistant-api/v1',
        cookie,
        client: client,
      );

      expect(cookieHeader, cookie);
      expect(authHeader, isNull);
      expect(models, ['gpt-4o', 'claude']);
    });

    test('fetchCodeMieProjects sends Cookie header, not Authorization', () async {
      String? cookieHeader;
      String? authHeader;
      final client = http_testing.MockClient((request) async {
        cookieHeader = request.headers['cookie'];
        authHeader = request.headers['authorization'];
        return http.Response(
          '{"applications":["proj-a","proj-b"],"applications_admin":["proj-c"]}',
          200,
        );
      });

      final cookie = '_oauth2_proxy=val';
      final projects = await fetchCodeMieProjects(
        'https://codemie.lab.epam.com/code-assistant-api',
        cookie,
        client: client,
      );

      expect(cookieHeader, cookie);
      expect(authHeader, isNull);
      expect(projects, ['proj-a', 'proj-b', 'proj-c']);
    });

    test('re-switching a saved CodeMie provider uses cookie auth', () async {
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      // Pre-store the cookie under the key name the entry will use.
      const cookie = '_oauth2_proxy=saved-val';
      final keyName = CustomProviderRegistry.keyNameFor(
        'https://codemie.lab.epam.com/code-assistant-api/v1',
        providerName: 'codemie.lab.epam.com',
      );
      // Save through the cache so the value lands in the cache's snapshot
      // (SecureKeyCache.read only sees preloaded/saved values).
      await cache.save(keyName, cookie);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'gpt-4o',
          keyName: keyName,
        ),
      ]);

      final cli = cliFor(
        streamFunction: fake.call,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      // Switch to the saved provider.
      io.sendLine('/provider codemie.lab.epam.com');
      await waitForIt(() => io.out.toString().contains('switched provider'));
      io.sendLine('/exit');
      await run;

      // The model should have cookie headers, not Bearer.
      expect(cli.agent.state.model.headers, {'cookie': cookie});
    });
  });
}
