/// Capability-conditional tool registration (GOAL #28, issue #2416
/// UT-4): the media-slot predicates (slot set / unsupported / opt-in) and
/// the OpenRouter predicate decide REGISTRATION on the CLI — a missing
/// capability is ABSENT (no manifest row, no others listing, /tools
/// reason), never present-and-erroring.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  group('mediaGenerationSlotCapability (pure predicates)', () {
    test('a null models config keeps the capability absent', () {
      final capability = mediaGenerationSlotCapability(null, 'imageGeneration');
      expect(capability.present, isFalse);
      expect(capability.absentReason, contains('imageGeneration'));
    });

    test('an unset slot keeps the capability absent, naming the slot', () {
      final capability = mediaGenerationSlotCapability(
        ModelsConfig(),
        'videoGeneration',
      );
      expect(capability.present, isFalse);
      expect(capability.absentReason, contains('videoGeneration'));
    });

    test('a configured slot is present (pure config check)', () {
      final capability = mediaGenerationSlotCapability(
        ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://media.test/v1',
              modelId: 'img-1',
            ),
          },
        ),
        'imageGeneration',
      );
      expect(capability.present, isTrue);
      expect(capability.absentReason, isNull);
    });

    test('an unsupported slot is absent (#2085 un-mark reason)', () {
      final capability = mediaGenerationSlotCapability(
        ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://media.test/v1',
              modelId: 'img-1',
              unsupported: true,
            ),
          },
        ),
        'imageGeneration',
      );
      expect(capability.present, isFalse);
      expect(capability.absentReason, contains('unsupported'));
    });

    test('the two slots decide independently', () {
      final models = ModelsConfig(
        slots: {
          'imageGeneration': MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://media.test/v1',
            modelId: 'img-1',
          ),
        },
      );
      expect(
        mediaGenerationSlotCapability(models, 'imageGeneration').present,
        isTrue,
      );
      expect(
        mediaGenerationSlotCapability(models, 'videoGeneration').present,
        isFalse,
      );
    });
  });

  group('CLI registration follows the capability (IT-4 shape)', () {
    Future<(Set<String>, FakeCliIO, AgentCli)> bootCli(
      ModelsConfig? modelsConfig, {
      Model? model,
    }) async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final stream = FakeStreamFunction([textTurn('ok')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: model ?? testModel,
          apiKey: 'test-key',
          env: env,
          homeDir: '/home/u',
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          loadMode: AgentLoadMode.defaultMode,
          modelsConfig: modelsConfig,
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await io.out.waitUntilContains('fa>', reason: 'boot prompt');
      io.sendLine('hello');
      await waitForIt(() => stream.calls >= 1, reason: 'hello turn');
      io.sendLine('/exit');
      await run;
      io.close();
      return (cli.agent.state.tools.map((t) => t.name).toSet(), io, cli);
    }

    test('configured media slots put both tools in the manifest', () async {
      final (names, _, _) = await bootCli(
        ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://media.test/v1',
              modelId: 'img-1',
            ),
            'videoGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://media.test/v1',
              modelId: 'vid-1',
            ),
          },
        ),
      );
      expect(names, containsAll(['generate_image', 'generate_video']));
    });

    test('an OpenRouter main puts decide in the manifest', () async {
      const openrouterModel = Model(
        id: 'test/model',
        api: 'openai-completions',
        provider: 'openrouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      final (names, _, _) = await bootCli(null, model: openrouterModel);
      expect(names, contains('decide'));
    });
  });
}
