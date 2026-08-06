import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fallback = MediaFallback(
    providerKind: 'openai-completions',
    baseUrl: 'https://openrouter.ai/api/v1',
    modelId: 'gpt-5',
    apiKey: 'sk-main',
  );

  const override = MediaSlotOverride(
    providerKind: 'openai-completions',
    baseUrl: 'https://api.openai.com/v1',
    modelId: 'gpt-image-1',
    apiKeyName: 'OPENAI_API_KEY',
  );

  group('MediaModelsStore persistence', () {
    test('missing file loads as empty', () async {
      final env = MemoryExecutionEnv();
      final store = await MediaModelsStore.load(env);
      expect(store.configuredSlots, isEmpty);
      expect(store.overrideFor(MediaSlot.imageGeneration), isNull);
    });

    test('corrupt file loads as empty instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/media_models.json', 'not json {');
      final store = await MediaModelsStore.load(env);
      expect(store.configuredSlots, isEmpty);
    });

    test('wrong schema version loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/media_models.json',
        '{"version": 99, "slots": {}}',
      );
      final store = await MediaModelsStore.load(env);
      expect(store.configuredSlots, isEmpty);
    });

    test('overrides round-trip through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = await MediaModelsStore.load(env);
      await store.setOverride(MediaSlot.imageGeneration, override);
      await store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          modelId: 'tts-1',
        ),
      );

      final reloaded = await MediaModelsStore.load(env);
      expect(reloaded.configuredSlots, [
        MediaSlot.imageGeneration,
        MediaSlot.audioTts,
      ]);
      final image = reloaded.overrideFor(MediaSlot.imageGeneration)!;
      expect(image.providerKind, 'openai-completions');
      expect(image.baseUrl, 'https://api.openai.com/v1');
      expect(image.modelId, 'gpt-image-1');
      expect(image.apiKeyName, 'OPENAI_API_KEY');
      expect(reloaded.overrideFor(MediaSlot.audioTts)!.apiKeyName, isNull);
    });

    test('the store file never contains key values, only names', () async {
      final env = MemoryExecutionEnv();
      final store = await MediaModelsStore.load(env);
      await store.setOverride(MediaSlot.imageGeneration, override);

      final raw = (await env.readTextFile(
        '${env.cwd}/${MediaModelsStore.fileName}',
      )).valueOrNull!;
      expect(raw, contains('OPENAI_API_KEY'));
      expect(raw, isNot(contains('sk-')));
    });

    test('the tts voice round-trips through the store file', () async {
      final env = MemoryExecutionEnv();
      final store = await MediaModelsStore.load(env);
      await store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          modelId: 'tts-1',
          voice: 'af_heart',
        ),
      );

      final raw = (await env.readTextFile(
        '${env.cwd}/${MediaModelsStore.fileName}',
      )).valueOrNull!;
      expect(raw, contains('"voice":"af_heart"'));

      final reloaded = await MediaModelsStore.load(env);
      expect(reloaded.overrideFor(MediaSlot.audioTts)!.voice, 'af_heart');
    });

    test('an absent voice stays absent from the store file', () async {
      final env = MemoryExecutionEnv();
      final store = await MediaModelsStore.load(env);
      await store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          modelId: 'tts-1',
        ),
      );

      final raw = (await env.readTextFile(
        '${env.cwd}/${MediaModelsStore.fileName}',
      )).valueOrNull!;
      expect(raw, isNot(contains('voice')));
      final reloaded = await MediaModelsStore.load(env);
      expect(reloaded.overrideFor(MediaSlot.audioTts)!.voice, isNull);
    });

    test('setting null clears the slot; unknown slots are ignored', () async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.imageGeneration, override);
      expect(store.configuredSlots, [MediaSlot.imageGeneration]);

      await store.setOverride('notASlot', override);
      expect(store.configuredSlots, [MediaSlot.imageGeneration]);

      await store.setOverride(MediaSlot.imageGeneration, null);
      expect(store.configuredSlots, isEmpty);
    });

    test(
      'mutations notify listeners (in-memory store persists nothing)',
      () async {
        final store = MediaModelsStore.inMemory();
        var notifications = 0;
        store.addListener(() => notifications++);

        await store.setOverride(MediaSlot.audioTts, override);
        expect(notifications, 1);
        await store.clear();
        expect(notifications, 2);
        expect(store.configuredSlots, isEmpty);
      },
    );
  });

  group('MediaModelsStore.resolve', () {
    test('no override falls back to the main connection with the slot '
        'default model', () async {
      final store = MediaModelsStore.inMemory();

      final image = await store.resolve(MediaSlot.imageGeneration, fallback);
      expect(image, isNotNull);
      expect(image!.fromOverride, isFalse);
      expect(image.baseUrl, 'https://openrouter.ai/api/v1');
      expect(image.modelId, 'gpt-image-1'); // NOT the chat model id
      expect(image.apiKey, 'sk-main');

      final tts = await store.resolve(MediaSlot.audioTts, fallback);
      expect(tts!.modelId, 'tts-1');

      final transcription = await store.resolve(
        MediaSlot.transcription,
        fallback,
      );
      expect(transcription!.modelId, 'whisper-1');
    });

    test('the vision slot falls back to the chat model itself', () async {
      final store = MediaModelsStore.inMemory();
      final vision = await store.resolve(MediaSlot.vision, fallback);
      expect(vision!.modelId, 'gpt-5');
    });

    test('music and video have no main-connection fallback', () async {
      final store = MediaModelsStore.inMemory();
      expect(await store.resolve(MediaSlot.musicGeneration, fallback), isNull);
      expect(await store.resolve(MediaSlot.videoGeneration, fallback), isNull);
    });

    test('an on-device main connection is never a usable fallback', () async {
      final store = MediaModelsStore.inMemory();
      final onDevice = await store.resolve(
        MediaSlot.imageGeneration,
        const MediaFallback(
          providerKind: 'gemma',
          baseUrl: '',
          modelId: 'gemma3n',
          apiKey: '',
        ),
      );
      expect(onDevice, isNull);
    });

    test('an override resolves its named key through the resolver', () async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.imageGeneration, override);

      final endpoint = await store.resolve(
        MediaSlot.imageGeneration,
        fallback,
        resolveKey: (name) async =>
            name == 'OPENAI_API_KEY' ? 'sk-openai' : null,
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.fromOverride, isTrue);
      expect(endpoint.baseUrl, 'https://api.openai.com/v1');
      expect(endpoint.modelId, 'gpt-image-1');
      expect(endpoint.apiKey, 'sk-openai');
    });

    test(
      'an override without apiKeyName reuses the main connection key',
      () async {
        final store = MediaModelsStore.inMemory();
        await store.setOverride(
          MediaSlot.imageGeneration,
          const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://openrouter.ai/api/v1',
            modelId: 'dall-e-3',
          ),
        );

        final endpoint = await store.resolve(
          MediaSlot.imageGeneration,
          fallback,
        );
        expect(endpoint!.apiKey, 'sk-main');
        expect(endpoint.modelId, 'dall-e-3');
      },
    );

    test('an unresolvable apiKeyName makes the endpoint unusable', () async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.imageGeneration, override);

      final endpoint = await store.resolve(
        MediaSlot.imageGeneration,
        fallback,
        resolveKey: (name) async => null,
      );
      expect(endpoint, isNull);
      // No resolver at all: also unusable (the named key cannot be read).
      expect(await store.resolve(MediaSlot.imageGeneration, fallback), isNull);
    });

    test('an empty override base URL resolves to the OpenAI default', () async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: '',
          modelId: 'tts-1',
        ),
      );

      final endpoint = await store.resolve(MediaSlot.audioTts, fallback);
      expect(endpoint!.baseUrl, MediaModelsStore.defaultBaseUrl);
    });

    test('an override carries its voice into the resolved endpoint', () async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          modelId: 'tts-1',
          voice: 'af_heart',
        ),
      );

      final endpoint = await store.resolve(MediaSlot.audioTts, fallback);
      expect(endpoint!.voice, 'af_heart');
      // The main-connection fallback never invents a voice.
      final plain = await store.resolve(MediaSlot.imageGeneration, fallback);
      expect(plain!.voice, isNull);
    });
  });
}
