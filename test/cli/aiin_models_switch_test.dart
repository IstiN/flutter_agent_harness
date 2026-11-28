// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-2466: the AIN gateway's `/v1/models` answer flows through the CLI's
/// own fetch path with the per-family window correction and the
/// endpoint-reported input modalities applied — a `/model` switch onto a
/// gateway id inherits the corrected window and the reported image input
/// (gh-1742: ONE window per model identity everywhere).
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
  });

  // The live gateway shape (api.aiin.by /v1/models, fetched 2026-11):
  // blanket ≈1M stamps on unverified families, precise values elsewhere.
  const modelsBody =
      '{"models": ['
      '{"alias": "anthropic/claude-sonnet-5", "context_length": 1048576, '
      '"input_modalities": ["text", "image", "file"]}, '
      '{"alias": "mistralai/mistral-large-4-0", "context_length": 1048576, '
      '"input_modalities": ["text", "image"]}, '
      '{"alias": "minimax/minimax-m3", "context_length": 1048576, '
      '"input_modalities": ["text"]}'
      ']}';

  final mockClient = http_testing.MockClient((request) async {
    return http.Response(modelsBody, 200);
  });

  // A modality-less endpoint whose list shares an id with the AIN answer
  // (gateways commonly proxy the same upstream ids) — the plain OpenAI
  // `data` shape, no `input_modalities` anywhere. The context_length rides
  // as the deterministic refresh-landed signal.
  const plainModelsBody =
      '{"data": ['
      '{"id": "mistralai/mistral-large-4-0", "context_length": 77123}]}';

  // Routes per host: the AIN gateway answers its live shape, everything
  // else answers the plain shape above.
  final routingClient = http_testing.MockClient((request) async {
    if (request.url.host.contains('aiin')) {
      return http.Response(modelsBody, 200);
    }
    return http.Response(plainModelsBody, 200);
  });

  final aiinModel = Model(
    id: 'z-ai/glm-5.1',
    api: 'openai-completions',
    provider: 'aiin',
    baseUrl: 'https://api.aiin.by/v1',
    input: ['text'],
    contextWindow: 200000,
    maxTokens: 8192,
  );

  Future<AgentCli> cliFor(
    FakeStreamFunction fake, {
    http.Client? client,
  }) async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: aiinModel,
        apiKey: 'sk-aiin-test',
        env: env,
        sessionRoot: '/sessions',
        modelsHttpClient: client ?? mockClient,
      ),
      io: io,
      streamFunction: fake.call,
    );
    return cli;
  }

  test(
    'ain /models: claude keeps 200k and reports image input at the switch',
    () async {
      final fake = FakeStreamFunction([]);
      final cli = await cliFor(fake);
      final run = cli.run();
      // The boot's cache warm prints the carried-default note for the
      // ACTIVE id (z-ai/glm-5.1 is not in the answer) — wait for it so the
      // fetch has landed before listing.
      await io.out.waitUntilContains('not reported by the endpoint');
      io.sendLine('/models');
      await io.out.waitUntilContains('anthropic/claude-sonnet-5');
      io.sendLine('/model anthropic/claude-sonnet-5');
      await io.out.waitUntilContains(
        'switched model to anthropic/claude-sonnet-5',
      );
      io.sendLine('/exit');
      await run;

      final model = cli.agent.state.model;
      expect(model.contextWindow, 200000, reason: 'blanket stamp corrected');
      expect(
        model.input,
        contains('image'),
        reason: 'endpoint modalities win over the id heuristic',
      );
    },
  );

  test('ain /models: uncurated families keep the endpoint report', () async {
    final fake = FakeStreamFunction([]);
    final cli = await cliFor(fake);
    final run = cli.run();
    await io.out.waitUntilContains('not reported by the endpoint');
    io.sendLine('/models');
    await io.out.waitUntilContains('minimax/minimax-m3');
    io.sendLine('/model minimax/minimax-m3');
    await io.out.waitUntilContains('switched model to minimax/minimax-m3');
    io.sendLine('/exit');
    await run;

    final model = cli.agent.state.model;
    expect(
      model.contextWindow,
      1048576,
      reason:
          'no global 1M fallback — the endpoint report stands for uncurated '
          'families',
    );
    expect(model.input, ['text'], reason: 'reported text-only stays text-only');
  });

  test(
    'a provider switch drops the previous provider modality verdicts',
    () async {
      final fake = FakeStreamFunction([]);
      final cli = await cliFor(fake, client: routingClient);
      final run = cli.run();
      // The boot's cache warm fetched the AIN answer (map filled).
      await io.out.waitUntilContains('not reported by the endpoint');
      io.sendLine('/models');
      await io.out.waitUntilContains('mistralai/mistral-large-4-0');
      // Take the shared id on AIN first: the verdict [text, image] lands in
      // the cache and on the active model.
      io.sendLine('/model mistralai/mistral-large-4-0');
      await io.out.waitUntilContains(
        'switched model to mistralai/mistral-large-4-0',
      );
      expect(cli.agent.state.model.input, contains('image'));

      // Switch to a modality-less endpoint whose list shares the SAME id:
      // the AIN verdict must not survive the switch — neither baked into the
      // model the switch builds nor served to a later /model pick.
      io.sendLine(
        '/provider openai http://plain.local/v1 sk-plain-test-1234567890',
      );
      await io.out.waitUntilContains('switched provider to openai');
      // The plain endpoint's refresh landed: its window report re-applied.
      await io.out.waitUntilContains(
        'model context window: 77123 (from endpoint)',
      );
      expect(
        cli.agent.state.model.input,
        ['text'],
        reason:
            'the provider switch rebuilt the model — the previous provider\'s '
            'image verdict must not ride it',
      );

      io.sendLine('/model mistralai/mistral-large-4-0');
      await io.out.waitUntilContains(
        'switched model to mistralai/mistral-large-4-0',
      );
      io.sendLine('/exit');
      await run;

      expect(
        cli.agent.state.model.input,
        ['text'],
        reason:
            'the plain endpoint reports no modalities — the id heuristic '
            '(text-only for mistral-large-4-0) owns the pick',
      );
    },
  );
}
