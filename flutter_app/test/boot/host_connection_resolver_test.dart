// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host-session resolver tests (issue #2391): the bridge read, the
/// idempotent `host` registry entry, memory-only key handling, and the
/// profile defaults that never override a user's saved selections.
library;

import 'package:fa/boot/host_connection_resolver.dart';
import 'package:fa/boot/host_session_bridge.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bridge backed by an in-memory map — what the host page writes.
final class _FakeBridge implements HostSessionBridge {
  _FakeBridge([this.values = const {}]);

  final Map<String, String> values;

  @override
  String? read(String key) => values[key];
}

FaProductConfig _product({Map<String, Object?>? section}) {
  final json = <String, Object?>{
    'productId': 'ain',
    'displayName': 'AIIN Agent',
    'apiEndpoint': 'https://api.ain.example/v1',
    'featureFlags': <String>[],
    if (section != null) 'hostConnection': section,
  };
  return FaProductConfig.fromJson(json);
}

Map<String, Object?> _section() => {
  'name': 'AIN',
  'baseUrl': 'https://api.ain.example/v1',
  'sessionBridge': {'storage': 'localStorage', 'key': 'aiin_agent_session'},
  'defaultModel': 'ain/aiin_flash',
  'modelRoles': {'smol': 'ain/aiin_flash', 'subagent': 'ain/aiin_flash'},
  'mediaSlots': {
    'imageGeneration': {'model': 'aiin/aiin_image'},
  },
};

void main() {
  group('HostConnectionResolver (issue #2391)', () {
    test(
      'resolves a populated bridge into the host entry + memory key',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final taskModels = TaskModelsStore.inMemory();
        final mediaModels = MediaModelsStore.inMemory();
        final state = await resolveHostSession(
          productConfig: _product(section: _section()),
          registry: registry,
          taskModels: taskModels,
          mediaModels: mediaModels,
          bridge: _FakeBridge({'aiin_agent_session': '  bridged-key  '}),
        );
        expect(state, isNotNull);
        expect(state!.bridgedKey, 'bridged-key');
        final entry = registry.providers.single;
        expect(entry.id, 'host');
        expect(entry.name, 'AIN');
        expect(entry.baseUrl, 'https://api.ain.example/v1');
        expect(entry.modelId, 'ain/aiin_flash');
        expect(entry.provenance, 'host');
        expect(entry.kind, 'host-session');
        expect(entry.requiresKey, isFalse);
        // Memory-only key resolution, session-scoped.
        expect(registry.keyFor('host'), 'bridged-key');
        expect(
          registry.keyValueForName(
            ProviderRegistry.keyNameFor('https://api.ain.example/v1'),
          ),
          'bridged-key',
        );
        expect(state.bootConfig, isNotNull);
        expect(state.bootConfig!.providerKind, 'openai-completions');
        expect(state.bootConfig!.baseUrl, 'https://api.ain.example/v1');
        expect(state.bootConfig!.modelId, 'ain/aiin_flash');
        expect(state.bootConfig!.apiKey, 'bridged-key');
      },
    );

    test(
      'two consecutive boots leave exactly one entry (idempotent)',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final taskModels = TaskModelsStore.inMemory();
        final mediaModels = MediaModelsStore.inMemory();
        final bridge = _FakeBridge({'aiin_agent_session': 'k1'});
        final config = _product(section: _section());
        await resolveHostSession(
          productConfig: config,
          registry: registry,
          taskModels: taskModels,
          mediaModels: mediaModels,
          bridge: bridge,
        );
        await resolveHostSession(
          productConfig: config,
          registry: registry,
          taskModels: taskModels,
          mediaModels: mediaModels,
          bridge: bridge,
        );
        final hosts = registry.providers.where((p) => p.id == 'host').toList();
        expect(hosts.length, 1);
        // A stale persisted copy is corrected to the profile's values.
        await registry.upsert(
          const CustomProvider(
            id: 'host',
            name: 'Stale',
            baseUrl: 'https://stale.example/v1',
            modelId: 'old/model',
            provenance: 'host',
            kind: 'host-session',
          ),
        );
        await resolveHostSession(
          productConfig: config,
          registry: registry,
          taskModels: taskModels,
          mediaModels: mediaModels,
          bridge: bridge,
        );
        expect(
          registry.providers.where((p) => p.id == 'host').single.baseUrl,
          'https://api.ain.example/v1',
        );
      },
    );

    test(
      'an empty or whitespace bridge resolves to no session (E12)',
      () async {
        for (final value in ['', '   ']) {
          final env = MemoryExecutionEnv();
          final registry = await ProviderRegistry.load(env);
          final taskModels = TaskModelsStore.inMemory();
          final mediaModels = MediaModelsStore.inMemory();
          final state = await resolveHostSession(
            productConfig: _product(section: _section()),
            registry: registry,
            taskModels: taskModels,
            mediaModels: mediaModels,
            bridge: _FakeBridge({'aiin_agent_session': value}),
          );
          expect(state, isNull);
          expect(registry.providers, isEmpty);
          expect(taskModels.configuredRoles, isEmpty);
          expect(mediaModels.configuredSlots, isEmpty);
        }
      },
    );

    test(
      'a profile without the section removes the stale host entry',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        await registry.upsert(
          const CustomProvider(
            id: 'host',
            name: 'Old',
            baseUrl: 'https://old.example/v1',
            modelId: 'old/model',
            provenance: 'host',
            kind: 'host-session',
          ),
        );
        final state = await resolveHostSession(
          productConfig: _product(),
          registry: registry,
          taskModels: TaskModelsStore.inMemory(),
          mediaModels: MediaModelsStore.inMemory(),
          bridge: _FakeBridge({'aiin_agent_session': 'k'}),
        );
        expect(state, isNull);
        expect(registry.providers, isEmpty);
      },
    );

    test(
      'role defaults land on unset roles; user selections win (AC13)',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final taskModels = TaskModelsStore.inMemory();
        await taskModels.setOverride(
          'smol',
          const TaskRoleConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://user.example/v1',
            modelId: 'user/flash',
          ),
        );
        final mediaModels = MediaModelsStore.inMemory();
        await resolveHostSession(
          productConfig: _product(section: _section()),
          registry: registry,
          taskModels: taskModels,
          mediaModels: mediaModels,
          bridge: _FakeBridge({'aiin_agent_session': 'k'}),
        );
        // The user's saved smol selection is preserved.
        expect(taskModels.overrideFor('smol')!.modelId, 'user/flash');
        expect(
          taskModels.overrideFor('smol')!.baseUrl,
          'https://user.example/v1',
        );
        // The undeclared subagent role gets the profile default.
        expect(taskModels.overrideFor('subagent')!.modelId, 'ain/aiin_flash');
        expect(
          taskModels.overrideFor('subagent')!.baseUrl,
          'https://api.ain.example/v1',
        );
        expect(taskModels.overrideFor('subagent')!.apiKeyName, isNull);
      },
    );

    test(
      'media slot defaults carry the named host key; user overrides win',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final mediaModels = MediaModelsStore.inMemory();
        await mediaModels.setOverride(
          'audioTts',
          const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://user.example/v1',
            modelId: 'user/tts',
            apiKeyName: 'USER_KEY',
          ),
        );
        await resolveHostSession(
          productConfig: _product(section: _section()),
          registry: registry,
          taskModels: TaskModelsStore.inMemory(),
          mediaModels: mediaModels,
          bridge: _FakeBridge({'aiin_agent_session': 'k'}),
        );
        // The declared slot is prefilled from the profile...
        final image = mediaModels.overrideFor('imageGeneration');
        expect(image!.providerKind, 'openai-completions');
        expect(image.baseUrl, 'https://api.ain.example/v1');
        expect(image.modelId, 'aiin/aiin_image');
        expect(
          image.apiKeyName,
          ProviderRegistry.keyNameFor('https://api.ain.example/v1'),
        );
        expect(image.useMainConnection, isFalse);
        // ...the user's saved audioTts override stays.
        expect(mediaModels.overrideFor('audioTts')!.modelId, 'user/tts');
        // The undeclared transcription slot stays unconfigured (gh-1844).
        expect(mediaModels.overrideFor('transcription'), isNull);
      },
    );

    test('no bridge on the platform default is safe (non-web boot)', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final state = await resolveHostSession(
        productConfig: _product(section: _section()),
        registry: registry,
        taskModels: TaskModelsStore.inMemory(),
        mediaModels: MediaModelsStore.inMemory(),
      );
      expect(state, isNull);
      expect(registry.providers, isEmpty);
    });
  });
}
