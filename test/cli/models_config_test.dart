import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// Scripted [StreamFunction] replaying pre-recorded turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// In-memory [CliIO]: scripted input lines, captured output.
class _FakeCliIO implements CliIO {
  @override
  int columns = 80;

  @override
  int rows = 24;

  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  @override
  bool isInteractive = true;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  bool get supportsRawMode => true;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  Future<void> close() async {
    unawaited(_lines.close());
    unawaited(_keys.close());
    await _interrupts.close();
  }
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

void main() {
  group('ModelsConfig yaml', () {
    test('parses slots and custom definitions from plain yaml', () {
      final config = CliConfig.fromYaml(
        loadYaml('''
models:
  slots:
    vision:
      providerKind: openai-completions
      baseUrl: https://api.openai.com/v1
      modelId: gpt-4o
      apiKeyName: OPENAI_API_KEY
    audioTts:
      providerKind: openai-completions
      baseUrl: https://api.openai.com/v1
      modelId: tts-1
  custom:
    fast:
      provider: openai
      baseUrl: https://api.openai.com/v1
      model: gpt-4o-mini
      contextWindow: 128000
      maxTokens: 4096
      input: [text, image]
''')
            as YamlMap,
      );
      final models = config.models!;
      expect(models.slots.length, 2);
      final vision = models.slots['vision']!;
      expect(vision.providerKind, 'openai-completions');
      expect(vision.baseUrl, 'https://api.openai.com/v1');
      expect(vision.modelId, 'gpt-4o');
      expect(vision.apiKeyName, 'OPENAI_API_KEY');
      expect(models.slots['audioTts']!.apiKeyName, isNull);
      final fast = models.custom['fast']!;
      expect(fast.provider, 'openai');
      expect(fast.baseUrl, 'https://api.openai.com/v1');
      expect(fast.model, 'gpt-4o-mini');
      expect(fast.contextWindow, 128000);
      expect(fast.maxTokens, 4096);
      expect(fast.input, ['text', 'image']);
    });

    test('round-trips through toYaml/loadYaml unchanged', () {
      final models = ModelsConfig(
        slots: {
          'vision': const MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'gpt-4o',
            apiKeyName: 'OPENAI_API_KEY',
          ),
        },
        custom: {
          'fast': const CustomModelDefinition(
            provider: 'openai',
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o-mini',
            contextWindow: 128000,
            input: ['text'],
          ),
        },
      );
      final once = CliConfig(models: models).toYaml();
      final twice = CliConfig.fromYaml(loadYaml(once) as YamlMap).toYaml();
      expect(twice, once);
      final reparsed = CliConfig.fromYaml(loadYaml(twice) as YamlMap).models!;
      expect(reparsed.slots['vision']!.modelId, 'gpt-4o');
      expect(reparsed.custom['fast']!.contextWindow, 128000);
      expect(reparsed.custom['fast']!.maxTokens, isNull);
    });

    test('empty models config is omitted from toYaml', () {
      final yaml = CliConfig(models: ModelsConfig()).toYaml();
      expect(yaml, isNot(contains('models:')));
    });

    test('persists through saveCliConfig/loadCliConfig', () async {
      final home = await Directory.systemTemp.createTemp('fah_models_test');
      addTearDown(() => home.deleteSync(recursive: true));
      await saveCliConfig(
        home.path,
        CliConfig(
          models: ModelsConfig(
            slots: {
              'transcription': const MediaSlotModelConfig(
                providerKind: 'openai-completions',
                baseUrl: 'https://api.openai.com/v1',
                modelId: 'whisper-1',
              ),
            },
          ),
        ),
      );
      final loaded = loadCliConfig(home.path);
      expect(loaded.models!.slots['transcription']!.modelId, 'whisper-1');
    });

    group('strict parse errors (ConfigException)', () {
      void expectBad(String yaml, String messagePart) {
        expect(
          () => CliConfig.fromYaml(loadYaml(yaml) as YamlMap),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains(messagePart),
            ),
          ),
        );
      }

      test('models is not a map', () {
        expect(
          () => ModelsConfig.fromYaml('nope'),
          throwsA(isA<ConfigException>()),
        );
        expectBad('models: 42', 'models must be a map');
      });

      test('unknown models section', () {
        expectBad('models:\n  bogus: {}', 'unknown models section "bogus"');
      });

      test('unknown media slot', () {
        expectBad(
          'models:\n  slots:\n    badSlot:\n      providerKind: x\n'
              '      baseUrl: y\n      modelId: z',
          'unknown media slot "badSlot"',
        );
      });

      test('slot missing modelId', () {
        expectBad(
          'models:\n  slots:\n    vision:\n      providerKind: x\n'
              '      baseUrl: y',
          'models.slots.vision.modelId must be a non-empty string',
        );
      });

      test('slot unknown field', () {
        expectBad(
          'models:\n  slots:\n    vision:\n      providerKind: x\n'
              '      baseUrl: y\n      modelId: z\n      token: nope',
          'unknown field "token" in models.slots.vision',
        );
      });

      test('slot bad apiKeyName', () {
        expectBad(
          'models:\n  slots:\n    vision:\n      providerKind: x\n'
              '      baseUrl: y\n      modelId: z\n      apiKeyName: 7',
          'models.slots.vision.apiKeyName must be a non-empty string',
        );
      });

      test('custom missing model', () {
        expectBad(
          'models:\n  custom:\n    fast:\n      provider: openai\n'
              '      baseUrl: https://api.openai.com/v1',
          'models.custom.fast.model must be a non-empty string',
        );
      });

      test('custom unknown provider', () {
        expectBad(
          'models:\n  custom:\n    fast:\n      provider: mistral\n'
              '      baseUrl: https://x\n      model: m',
          'unknown provider "mistral" in models.custom.fast',
        );
      });

      test('custom bad contextWindow', () {
        expectBad(
          'models:\n  custom:\n    fast:\n      provider: openai\n'
              '      baseUrl: https://x\n      model: m\n      contextWindow: -5',
          'models.custom.fast.contextWindow must be a positive integer',
        );
      });

      test('custom bad input entry', () {
        expectBad(
          'models:\n  custom:\n    fast:\n      provider: openai\n'
              '      baseUrl: https://x\n      model: m\n      input: [video]',
          'models.custom.fast.input entries must be "text" or "image"',
        );
      });

      test('custom unknown field', () {
        expectBad(
          'models:\n  custom:\n    fast:\n      provider: openai\n'
              '      baseUrl: https://x\n      model: m\n      region: eu',
          'unknown field "region" in models.custom.fast',
        );
      });
    });

    test('setSlotOverride rejects unknown slots', () {
      final models = ModelsConfig();
      expect(
        () => models.setSlotOverride(
          'nope',
          const MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://x',
            modelId: 'm',
          ),
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(models.removeSlotOverride('vision'), isFalse);
    });
  });

  group('REPL /models commands', () {
    late MemoryExecutionEnv env;
    late _FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = _FakeCliIO();
    });

    tearDown(() => io.close());

    AgentCli cliFor(
      StreamFunction streamFunction, {
      ModelsConfig? modelsConfig,
      void Function()? onModelsConfigChanged,
      Future<void> Function(Model model)? onModelChanged,
    }) {
      return AgentCli(
        config: AgentCliConfig(
          model: _model,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          modelsConfig: modelsConfig,
          onModelsConfigChanged: onModelsConfigChanged,
          onModelChanged: onModelChanged,
          // Keep the model-cache refresh hermetic (no real /models fetch).
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        ),
        io: io,
        streamFunction: streamFunction,
      );
    }

    test('/models set pins a slot and persists via the callback', () async {
      final models = ModelsConfig();
      var persisted = 0;
      final cli = cliFor(
        _FakeStreamFunction([]).call,
        modelsConfig: models,
        onModelsConfigChanged: () => persisted++,
      );
      final run = cli.run();
      io.sendLine('/models set vision gpt-4o');
      await _waitFor(
        () => io.out.toString().contains('slot vision → gpt-4o'),
        reason: 'set confirmation',
      );
      io.sendLine('/exit');
      await run;
      final vision = models.slots['vision']!;
      expect(vision.modelId, 'gpt-4o');
      // The base URL defaults to the main connection's endpoint.
      expect(vision.baseUrl, 'https://example.test');
      expect(vision.providerKind, 'openai-completions');
      expect(persisted, 1);
    });

    test('/models set accepts an explicit base URL', () async {
      final models = ModelsConfig();
      final cli = cliFor(_FakeStreamFunction([]).call, modelsConfig: models);
      final run = cli.run();
      io.sendLine('/models set audioTts tts-1 https://tts.example/v1');
      await _waitFor(
        () => io.out.toString().contains('slot audioTts → tts-1'),
        reason: 'set confirmation',
      );
      io.sendLine('/exit');
      await run;
      expect(models.slots['audioTts']!.baseUrl, 'https://tts.example/v1');
    });

    test('/models set validates slot and argument count', () async {
      final models = ModelsConfig();
      final cli = cliFor(_FakeStreamFunction([]).call, modelsConfig: models);
      final run = cli.run();
      io.sendLine('/models set nope gpt-4o');
      await _waitFor(
        () => io.out.toString().contains('unknown slot: nope'),
        reason: 'unknown slot error',
      );
      io.sendLine('/models set vision');
      await _waitFor(
        () => io.out.toString().contains('usage: /models set'),
        reason: 'usage error',
      );
      io.sendLine('/exit');
      await run;
      expect(models.slots, isEmpty);
    });

    test(
      '/models remove drops an override and reports a missing one',
      () async {
        final models = ModelsConfig();
        var persisted = 0;
        final cli = cliFor(
          _FakeStreamFunction([]).call,
          modelsConfig: models,
          onModelsConfigChanged: () => persisted++,
        );
        final run = cli.run();
        io.sendLine('/models set vision gpt-4o');
        await _waitFor(() => models.slots.containsKey('vision'));
        io.sendLine('/models remove vision');
        await _waitFor(
          () => io.out.toString().contains('slot vision → main connection'),
          reason: 'remove confirmation',
        );
        io.sendLine('/models remove vision');
        await _waitFor(
          () => io.out.toString().contains('no override for slot vision'),
          reason: 'missing override note',
        );
        io.sendLine('/exit');
        await run;
        expect(models.slots, isEmpty);
        expect(persisted, 2);
      },
    );

    test('/models config shows slots, fallback, and custom models', () async {
      final models = ModelsConfig(
        slots: {
          'vision': const MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'gpt-4o',
            apiKeyName: 'OPENAI_API_KEY',
          ),
        },
        custom: {
          'fast': const CustomModelDefinition(
            provider: 'openai',
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o-mini',
          ),
        },
      );
      final cli = cliFor(_FakeStreamFunction([]).call, modelsConfig: models);
      final run = cli.run();
      io.sendLine('/models config');
      await _waitFor(
        () => io.out.toString().contains('custom models'),
        reason: 'config output',
      );
      io.sendLine('/exit');
      await run;
      final out = io.out.toString();
      expect(out, contains('main connection: test-model'));
      expect(out, contains('vision: gpt-4o @ https://api.openai.com/v1'));
      expect(out, contains('key: OPENAI_API_KEY'));
      expect(out, contains('audioTts: main connection'));
      expect(out, contains('fast: gpt-4o-mini'));
    });

    test('/models set without a models config is unavailable', () async {
      final cli = cliFor(_FakeStreamFunction([]).call);
      final run = cli.run();
      io.sendLine('/models set vision gpt-4o');
      await _waitFor(
        () => io.out.toString().contains('models config is unavailable'),
        reason: 'unavailable note',
      );
      io.sendLine('/exit');
      await run;
    });

    test('/model <custom-name> resolves a custom model definition', () async {
      final models = ModelsConfig(
        custom: {
          'fast': const CustomModelDefinition(
            provider: 'openai',
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o-mini',
            contextWindow: 128000,
            maxTokens: 4096,
            input: ['text', 'image'],
          ),
        },
      );
      Model? changed;
      final cli = cliFor(
        _FakeStreamFunction([]).call,
        modelsConfig: models,
        onModelChanged: (model) async { changed = model; }
      );
      final run = cli.run();
      io.sendLine('/model fast');
      await _waitFor(
        () => io.out.toString().contains('switched model to fast'),
        reason: 'custom switch confirmation',
      );
      io.sendLine('/exit');
      await run;
      final model = cli.agent.state.model;
      expect(model.id, 'gpt-4o-mini');
      expect(model.provider, 'openai');
      expect(model.baseUrl, 'https://api.openai.com/v1');
      expect(model.contextWindow, 128000);
      expect(model.maxTokens, 4096);
      expect(model.input, ['text', 'image']);
      expect(changed?.id, 'gpt-4o-mini');
    });

    test('/model <custom-name> keeps catalog defaults when unset', () async {
      final models = ModelsConfig(
        custom: {
          'sonnet': const CustomModelDefinition(
            provider: 'anthropic',
            baseUrl: 'https://api.anthropic.com',
            model: 'claude-sonnet-4-5',
          ),
        },
      );
      final cli = cliFor(_FakeStreamFunction([]).call, modelsConfig: models);
      final run = cli.run();
      io.sendLine('/model sonnet');
      await _waitFor(
        () => io.out.toString().contains('switched model to sonnet'),
        reason: 'custom switch confirmation',
      );
      io.sendLine('/exit');
      await run;
      final model = cli.agent.state.model;
      expect(model.contextWindow, 200000);
      expect(model.maxTokens, 16384);
      expect(model.input, ['text', 'image']);
    });
  });
}
