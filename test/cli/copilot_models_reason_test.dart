// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1990 — `/models` never shows a silent hole for a Copilot provider:
/// the dialect's named failure (exchange status / HTTP status / filter
/// counts, with the remediation hint) is printed as a `fetch notes:`
/// section, and a healthy provider adds no failure lines.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    http.Client? modelsHttpClient,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    Model? model,
    String? providerKind,
    String? Function(String name)? envVarValue,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model ?? testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: envVarValue ?? (_) => null,
        modelsHttpClient: modelsHttpClient,
        secureKeys: secureKeys,
        customProviders: customProviders,
        providerKind: providerKind ?? 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  CustomProviderRegistry copilotRegistry(String keyName) =>
      CustomProviderRegistry([
        CustomProviderEntry(
          name: 'copilot-isti',
          apiType: 'copilot',
          baseUrl: 'https://api.githubcopilot.com',
          modelId: 'gpt-4.1',
          keyName: keyName,
        ),
      ]);

  test('/models prints the named failure for a copilot provider whose '
      'fetch answers empty', () async {
    final fake = FakeStreamFunction([]);
    final store = FakeSecureKeyStore()
      ..map['FA_KEY_COPILOT_ISTI'] = 'ghp_classic';
    final cache = SecureKeyCache(store);
    await cache.probe();
    final client = http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response('{"message":"Bad credentials"}', 401);
      }
      return http.Response('{"message":"denied"}', 401);
    });
    final cli = cliFor(
      fake.call,
      modelsHttpClient: client,
      secureKeys: cache,
      customProviders: copilotRegistry('FA_KEY_COPILOT_ISTI'),
    );
    final run = cli.run();

    io.sendLine('/models');
    await waitForIt(() => io.out.toString().contains('fetch notes:'));
    io.sendLine('/exit');
    await run;

    final out = io.out.toString();
    expect(out, contains('fetch notes:'));
    expect(out, contains('copilot-isti:'));
    // Both credential paths are named — a classic PAT rescues through
    // PAT-direct after the exchange rejects it.
    expect(out, contains('exchange path:'));
    expect(out, contains('pat-direct path:'));
    expect(out, contains('401'));
  });

  test('/models prints the HTTP branch with the tier-host hint for an '
      'exchanging provider', () async {
    final fake = FakeStreamFunction([]);
    final store = FakeSecureKeyStore()..map['FA_KEY_COPILOT_ISTI'] = 'gho_dead';
    final cache = SecureKeyCache(store);
    await cache.probe();
    final client = http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          '{"token":"cop-tok","expires_at":9999999999}',
          200,
        );
      }
      return http.Response('{"message":"seat inactive"}', 403);
    });
    final cli = cliFor(
      fake.call,
      modelsHttpClient: client,
      secureKeys: cache,
      customProviders: copilotRegistry('FA_KEY_COPILOT_ISTI'),
    );
    final run = cli.run();

    io.sendLine('/models');
    await waitForIt(() => io.out.toString().contains('fetch notes:'));
    io.sendLine('/exit');
    await run;

    final out = io.out.toString();
    expect(out, contains('copilot-isti:'));
    expect(out, contains('answered HTTP 403'));
    expect(out, contains('github.com/settings/copilot'));
  });

  test(
    '/models of a healthy copilot provider adds no failure section',
    () async {
      final fake = FakeStreamFunction([]);
      final store = FakeSecureKeyStore()..map['FA_KEY_COPILOT_ISTI'] = 'gho_ok';
      final cache = SecureKeyCache(store);
      await cache.probe();
      final client = http_testing.MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            '{"token":"cop-tok","expires_at":9999999999}',
            200,
          );
        }
        return http.Response(
          '{"data":[{"id":"gpt-4.1","model_picker_enabled":true,'
          '"supported_endpoints":["/chat/completions"]}]}',
          200,
        );
      });
      final cli = cliFor(
        fake.call,
        modelsHttpClient: client,
        secureKeys: cache,
        customProviders: copilotRegistry('FA_KEY_COPILOT_ISTI'),
      );
      final run = cli.run();

      io.sendLine('/models');
      await waitForIt(
        () => io.out.toString().contains('models (provider/model):'),
      );
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('copilot-isti/gpt-4.1'));
      expect(out, isNot(contains('fetch notes:')));
    },
  );

  // gh-1990 review round 2 — the saved-entry path above is covered; the
  // two SIBLING Copilot fetch paths (unsaved active-catalog provider,
  // env-keyed provider) must surface the same named failure instead of
  // silently falling back to the seed lists.
  group('fetch notes on the sibling copilot paths (unsaved providers)', () {
    test(
      'an unsaved ACTIVE copilot catalog provider names its failure',
      () async {
        final fake = FakeStreamFunction([]);
        const activeCopilot = Model(
          id: 'gpt-4.1',
          api: 'openai-completions',
          provider: 'copilot',
          baseUrl: copilotIndividualBaseUrl,
          contextWindow: 1000000,
          maxTokens: 32768,
        );
        final requests = <String>[];
        final client = http_testing.MockClient((request) async {
          requests.add(request.url.toString());
          if (request.url.host == 'api.github.com') {
            return http.Response('{"message":"Bad credentials"}', 401);
          }
          return http.Response('{"message":"denied"}', 401);
        });
        final cli = cliFor(
          fake.call,
          modelsHttpClient: client,
          model: activeCopilot,
          providerKind: 'copilot',
        );
        final run = cli.run();
        // The boot's context-window refresh rides the same dispatch (the
        // legacy active-only path): its two requests settle before `/models`
        // below, so the all-providers refresh is not raced mid-boot.
        await waitForIt(() => requests.length >= 2);

        io.sendLine('/models');
        await waitForIt(
          () => io.out.toString().contains('models (provider/model):'),
        );
        io.sendLine('/exit');
        await run;

        final out = io.out.toString();
        expect(out, contains('fetch notes:'));
        expect(out, contains('copilot:'));
        // The dual-path shape: the classic-shaped session key rescues
        // through PAT-direct after the exchange rejects it.
        expect(out, contains('exchange path:'));
        expect(out, contains('pat-direct path:'));
      },
    );

    test('an env-keyed copilot provider names its failure', () async {
      final fake = FakeStreamFunction([]);
      final client = http_testing.MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            '{"token":"[REDACTED:credential]","expires_at":9999999999}',
            200,
          );
        }
        return http.Response('{"message":"seat inactive"}', 403);
      });
      final cli = cliFor(
        fake.call,
        modelsHttpClient: client,
        envVarValue: (name) =>
            name == 'COPILOT_GITHUB_TOKEN' ? 'gho_dead' : null,
      );
      final run = cli.run();

      io.sendLine('/models');
      await waitForIt(
        () => io.out.toString().contains('models (provider/model):'),
      );
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('fetch notes:'));
      expect(out, contains('copilot:'));
      expect(out, contains('answered HTTP 403'));
    });

    test(
      'a healthy env-keyed copilot provider adds no failure section',
      () async {
        final fake = FakeStreamFunction([]);
        final client = http_testing.MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              '{"token":"[REDACTED:credential]","expires_at":9999999999}',
              200,
            );
          }
          return http.Response(
            '{"data":[{"id":"gpt-4.1","model_picker_enabled":true,'
            '"supported_endpoints":["/chat/completions"]}]}',
            200,
          );
        });
        final cli = cliFor(
          fake.call,
          modelsHttpClient: client,
          envVarValue: (name) =>
              name == 'COPILOT_GITHUB_TOKEN' ? 'gho_ok' : null,
        );
        final run = cli.run();

        io.sendLine('/models');
        await waitForIt(
          () => io.out.toString().contains('models (provider/model):'),
        );
        io.sendLine('/exit');
        await run;

        final out = io.out.toString();
        expect(out, isNot(contains('fetch notes:')));
      },
    );
  });
}
