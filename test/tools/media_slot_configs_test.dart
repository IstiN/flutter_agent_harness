/// Tests for the media-slot → tool-config resolvers (gh-1984 AC5/AC8):
/// the persisted `models:` slots (`vision`, `transcription`) are the ONE
/// source of truth every host reads; these adapters turn them into the
/// `InspectImageConfig`/`TranscribeAudioConfig` the tools consume.
library;

import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:flutter_agent_harness/src/model_roles/models_config.dart';
import 'package:flutter_agent_harness/src/tools/inspect_image.dart';
import 'package:flutter_agent_harness/src/tools/media_slot_configs.dart';
import 'package:flutter_agent_harness/src/tools/transcribe_audio.dart';
import 'package:test/test.dart';

MediaSlotModelConfig _override({
  bool useMainConnection = false,
  String? apiKeyName = 'SLOT_KEY',
}) => MediaSlotModelConfig(
  providerKind: useMainConnection ? '' : 'openai-completions',
  baseUrl: useMainConnection ? '' : 'https://api.example.com/v1',
  modelId: useMainConnection ? '' : 'slot-model',
  apiKeyName: useMainConnection ? null : apiKeyName,
  useMainConnection: useMainConnection,
);

ModelsConfig _models(String slot, {bool useMainConnection = false}) =>
    ModelsConfig(
      slots: {slot: _override(useMainConnection: useMainConnection)},
    );

void main() {
  group('resolveVisionSlotInspectConfig', () {
    test(
      'resolves a concrete vision slot into an InspectImageConfig',
      () async {
        final config = await resolveVisionSlotInspectConfig(
          _models('vision'),
          resolveKey: (name) async => 'key-for-$name',
        );
        expect(config, isNotNull);
        expect(config!.modelId, 'slot-model');
        expect(config.baseUrl, 'https://api.example.com/v1');
        expect(config.apiKey, 'key-for-SLOT_KEY');
        expect(config.providerKind, 'openai-completions');
      },
    );

    test('returns null without a models config or a vision slot', () async {
      expect(
        await resolveVisionSlotInspectConfig(
          null,
          resolveKey: (_) async => 'k',
        ),
        isNull,
      );
      expect(
        await resolveVisionSlotInspectConfig(
          ModelsConfig(slots: {'imageGeneration': _override()}),
          resolveKey: (_) async => 'k',
        ),
        isNull,
      );
    });

    test('useMainConnection opt-in does NOT serve inspect_image', () async {
      // The main connection's model is the CHAT model: riding it would
      // inspect images with the very model that cannot see them (or with
      // itself when it can — redundant). The slot must name its own
      // endpoint for inspect_image.
      expect(
        await resolveVisionSlotInspectConfig(
          _models('vision', useMainConnection: true),
          resolveKey: (_) async => 'k',
        ),
        isNull,
      );
    });

    test('an unresolvable key still builds the config (empty key)', () async {
      // Honesty at call time: the tool registers (the slot IS configured),
      // the call fails with the provider's auth error, and the auto-route
      // degrades to the omission note + reason (AC6).
      final config = await resolveVisionSlotInspectConfig(
        _models('vision'),
        resolveKey: (_) async => null,
      );
      expect(config, isNotNull);
      expect(config!.apiKey, isEmpty);
    });

    test(
      'same-host slots reuse the main key when no apiKeyName is set',
      () async {
        final models = ModelsConfig(
          slots: {
            'vision': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://main.example.com/v1',
              modelId: 'slot-model',
            ),
          },
        );
        final config = await resolveVisionSlotInspectConfig(
          models,
          resolveKey: (_) async => 'named',
          mainBaseUrl: 'https://main.example.com/v1',
          mainApiKey: 'main-key',
        );
        expect(config!.apiKey, 'main-key');
      },
    );
  });

  group('resolveTranscriptionSlotConfig', () {
    test('resolves a concrete transcription slot', () async {
      final config = await resolveTranscriptionSlotConfig(
        _models('transcription'),
        resolveKey: (name) async => 'key-for-$name',
      );
      expect(config, isNotNull);
      expect(config!.modelId, 'slot-model');
      expect(config.baseUrl, 'https://api.example.com/v1');
      expect(config.apiKey, 'key-for-SLOT_KEY');
      // Adapter family inferred from the endpoint host (null = infer).
      expect(config.providerKind, isNull);
    });

    test(
      'returns null without a slot or on the main-connection opt-in',
      () async {
        expect(
          await resolveTranscriptionSlotConfig(
            null,
            resolveKey: (_) async => 'k',
          ),
          isNull,
        );
        expect(
          await resolveTranscriptionSlotConfig(
            _models('transcription', useMainConnection: true),
            resolveKey: (_) async => 'k',
          ),
          isNull,
        );
      },
    );

    test('each resolver reads only its own slot', () async {
      // The slot map carries ONLY known slot names (the models config
      // validates them); a resolver asked for its slot never picks up
      // another slot's entry.
      final models = _models('imageGeneration');
      expect(
        await resolveVisionSlotInspectConfig(
          models,
          resolveKey: (_) async => 'k',
        ),
        isNull,
      );
      expect(
        await resolveTranscriptionSlotConfig(
          models,
          resolveKey: (_) async => 'k',
        ),
        isNull,
      );
    });
  });

  group('slot schema sanity', () {
    test('vision and transcription are declared media slots', () {
      expect(mediaModelSlotIds, containsAll(['vision', 'transcription']));
    });

    test('MediaSlotModelConfig carries the fields the resolvers consume', () {
      final override = _override();
      expect(override.modelId, 'slot-model');
      expect(override.apiKeyName, 'SLOT_KEY');
      expect(override.isMainConnectionOptIn, isFalse);
    });
  });

  group('cliVisionSlotResolver (the host wiring builder)', () {
    test(
      'the --vision-model flag is the override even when a slot exists',
      () async {
        var flagBuilt = 0;
        final resolve = cliVisionSlotResolver(
          flagModel: 'flag-vision',
          flagBaseUrl: 'https://flag.example.com/v1',
          modelsConfig: _models('vision'),
          resolveKey: (_) async => 'slot-key',
          mainBaseUrl: 'https://main.example.com/v1',
          mainApiKey: 'main-key',
          flagConfig: (modelId, baseUrl) {
            flagBuilt++;
            return InspectImageConfig(
              modelId: modelId,
              apiKey: 'flag-key',
              baseUrl: baseUrl,
            );
          },
        );
        final config = await resolve();
        expect(config!.modelId, 'flag-vision');
        expect(config.baseUrl, 'https://flag.example.com/v1');
        expect(flagBuilt, 1, reason: 'the flag config is built lazily, once');
      },
    );

    test('flagless: the slot serves from the LIVE models instance '
        '(a mid-session set is visible — review thread 6)', () async {
      // Fresh install: no `models:` section — the host passes the EMPTY
      // fallback instance, the same one its `/models set` mutates. The
      // resolver must read THAT instance at call time, not a snapshot.
      final liveModels = ModelsConfig();
      final resolve = cliVisionSlotResolver(
        modelsConfig: liveModels,
        resolveKey: (_) async => 'slot-key',
        mainBaseUrl: 'https://main.example.com/v1',
        mainApiKey: 'main-key',
        flagConfig: (modelId, baseUrl) => InspectImageConfig(
          modelId: modelId,
          apiKey: 'flag-key',
          baseUrl: baseUrl,
        ),
      );
      expect(await resolve(), isNull, reason: 'no slot yet');
      liveModels.setSlotOverride(
        'vision',
        MediaSlotModelConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.example.com/v1',
          modelId: 'slot-model',
        ),
      );
      final config = await resolve();
      expect(config, isNotNull);
      expect(config!.modelId, 'slot-model');
      // …and withdrawing it live degrades to null (no stale config).
      expect(liveModels.removeSlotOverride('vision'), isTrue);
      expect(await resolve(), isNull);
    });

    test(
      'flagless: a same-host slot with no apiKeyName reuses the MAIN key '
      '(review thread 2 — one rule with generate_image/generate_video)',
      () async {
        final liveModels = ModelsConfig(
          slots: {
            'vision': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://main.example.com/v1',
              modelId: 'slot-model',
            ),
          },
        );
        final resolve = cliVisionSlotResolver(
          modelsConfig: liveModels,
          resolveKey: (_) async => 'unused-named',
          mainBaseUrl: 'https://main.example.com/v1',
          mainApiKey: 'main-key',
          flagConfig: (modelId, baseUrl) => InspectImageConfig(
            modelId: modelId,
            apiKey: 'flag-key',
            baseUrl: baseUrl,
          ),
        );
        final config = await resolve();
        expect(config, isNotNull);
        expect(
          config!.apiKey,
          'main-key',
          reason:
              'the main connection must be in scope — the flagship '
              '`/models set vision <id>` flow writes exactly this slot '
              'shape, and an empty key would auth-fail every call',
        );
      },
    );

    test(
      'flagless: a cross-host slot without apiKeyName resolves empty',
      () async {
        final liveModels = ModelsConfig(
          slots: {
            'vision': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://other.example.com/v1',
              modelId: 'slot-model',
            ),
          },
        );
        final resolve = cliVisionSlotResolver(
          modelsConfig: liveModels,
          resolveKey: (_) async => null,
          mainBaseUrl: 'https://main.example.com/v1',
          mainApiKey: 'main-key',
          flagConfig: (modelId, baseUrl) => InspectImageConfig(
            modelId: modelId,
            apiKey: 'flag-key',
            baseUrl: baseUrl,
          ),
        );
        // Honesty at call time: the config builds (the slot IS configured),
        // the empty key surfaces as the provider's auth error, and the read
        // auto-route degrades (AC6) instead of hiding the misconfiguration.
        final config = await resolve();
        expect(config, isNotNull);
        expect(config!.apiKey, isEmpty);
      },
    );
  });

  group('cliTranscriptionSlotResolver (the host wiring builder)', () {
    test('the --transcribe-model flag is the override', () async {
      final resolve = cliTranscriptionSlotResolver(
        flagModel: 'flag-transcribe',
        flagBaseUrl: 'https://flag.example.com/v1',
        modelsConfig: _models('transcription'),
        resolveKey: (_) async => 'slot-key',
        mainBaseUrl: 'https://main.example.com/v1',
        mainApiKey: 'main-key',
        flagConfig: (modelId, baseUrl) => TranscribeAudioConfig(
          modelId: modelId,
          apiKey: 'flag-key',
          baseUrl: baseUrl,
        ),
      );
      final config = await resolve();
      expect(config!.modelId, 'flag-transcribe');
      expect(config.baseUrl, 'https://flag.example.com/v1');
    });

    test('flagless: the slot serves live and the same-host main-key rule '
        'applies', () async {
      final liveModels = ModelsConfig();
      final resolve = cliTranscriptionSlotResolver(
        modelsConfig: liveModels,
        resolveKey: (_) async => 'named',
        mainBaseUrl: 'https://main.example.com/v1',
        mainApiKey: 'main-key',
        flagConfig: (modelId, baseUrl) => TranscribeAudioConfig(
          modelId: modelId,
          apiKey: 'flag-key',
          baseUrl: baseUrl,
        ),
      );
      expect(await resolve(), isNull);
      liveModels.setSlotOverride(
        'transcription',
        MediaSlotModelConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://main.example.com/v1',
          modelId: 'slot-model',
        ),
      );
      final config = await resolve();
      expect(config!.modelId, 'slot-model');
      expect(config.apiKey, 'main-key');
    });
  });
}
