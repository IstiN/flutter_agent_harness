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

    test('useMainConnection survives the JSON round-trip', () async {
      final env = MemoryExecutionEnv();
      final store = await MediaModelsStore.load(env);
      await store.setOverride(
        MediaSlot.videoGeneration,
        const MediaSlotOverride(
          providerKind: '',
          baseUrl: '',
          modelId: '',
          useMainConnection: true,
        ),
      );

      final reloaded = await MediaModelsStore.load(env);
      final restored = reloaded.overrideFor(MediaSlot.videoGeneration);
      expect(restored, isNotNull);
      expect(restored!.useMainConnection, isTrue);
      // Absent in the JSON → default false on a plain override.
      await store.setOverride(MediaSlot.imageGeneration, override);
      final plain =
          (await MediaModelsStore.load(env)).overrideFor(
            MediaSlot.imageGeneration,
          );
      expect(plain!.useMainConnection, isFalse);
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

  group('MediaModelsStore.resolve (gh-1844)', () {
    test('no override leaves EVERY slot UNCONFIGURED — the main '
        'connection is never an implicit fallback', () async {
      final store = MediaModelsStore.inMemory();
      for (final slot in MediaSlot.all) {
        expect(
          await store.resolve(slot, fallback),
          isNull,
          reason: 'slot $slot must be UNCONFIGURED without an override',
        );
      }
    });

    test(
      'useMainConnection: true opts every slot into the main connection',
      () async {
        final store = MediaModelsStore.inMemory();
        for (final slot in MediaSlot.all) {
          await store.setOverride(
            slot,
            const MediaSlotOverride(
              providerKind: '',
              baseUrl: '',
              modelId: '',
              useMainConnection: true,
            ),
          );
        }

        final image = await store.resolve(MediaSlot.imageGeneration, fallback);
        expect(image, isNotNull);
        expect(image!.fromOverride, isFalse);
        expect(image.baseUrl, 'https://openrouter.ai/api/v1');
        expect(image.modelId, 'gpt-image-1'); // NOT the chat model id
        expect(image.apiKey, 'sk-main');

        expect(
          (await store.resolve(MediaSlot.audioTts, fallback))!.modelId,
          'tts-1',
        );
        expect(
          (await store.resolve(MediaSlot.transcription, fallback))!.modelId,
          'whisper-1',
        );
        // vision preserves the intentional main-model behavior, opt-in only.
        expect(
          (await store.resolve(MediaSlot.vision, fallback))!.modelId,
          'gpt-5',
        );
        // music/video have no OpenAI default: they ride the main model id.
        expect(
          (await store.resolve(MediaSlot.musicGeneration, fallback))!.modelId,
          'gpt-5',
        );
        expect(
          (await store.resolve(MediaSlot.videoGeneration, fallback))!.modelId,
          'gpt-5',
        );
      },
    );

    test('an on-device main connection is never usable, even opted in', () async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.imageGeneration,
        const MediaSlotOverride(
          providerKind: '',
          baseUrl: '',
          modelId: '',
          useMainConnection: true,
        ),
      );
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
      'an override without apiKeyName never inherits the main key',
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

        // The slot's provider is a different endpoint: sending the main
        // connection's key there would be a credential leak, so the
        // endpoint is unusable instead.
        final endpoint = await store.resolve(
          MediaSlot.imageGeneration,
          fallback,
        );
        expect(endpoint, isNull);
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
          apiKeyName: 'TTS_KEY',
        ),
      );

      final endpoint = await store.resolve(
        MediaSlot.audioTts,
        fallback,
        resolveKey: (name) async => name == 'TTS_KEY' ? 'sk-tts' : null,
      );
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
          apiKeyName: 'TTS_KEY',
        ),
      );

      final endpoint = await store.resolve(
        MediaSlot.audioTts,
        fallback,
        resolveKey: (name) async => name == 'TTS_KEY' ? 'sk-tts' : null,
      );
      expect(endpoint!.voice, 'af_heart');
      // A main-connection opt-in never invents a voice.
      await store.setOverride(
        MediaSlot.imageGeneration,
        const MediaSlotOverride(
          providerKind: '',
          baseUrl: '',
          modelId: '',
          useMainConnection: true,
        ),
      );
      final plain = await store.resolve(MediaSlot.imageGeneration, fallback);
      expect(plain!.voice, isNull);
    });
  });
}
