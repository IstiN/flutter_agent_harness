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
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: (_) => null,
        modelsHttpClient: modelsHttpClient,
        secureKeys: secureKeys,
        customProviders: customProviders,
        providerKind: 'openai-completions',
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
}
