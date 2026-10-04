import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  group('folderModelStatePath', () {
    test('namespaces the state file under the encoded cwd', () {
      expect(
        folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work'),
        '/sessions/${encodeSessionCwd('/work')}/model-state.json',
      );
    });
  });

  group('folderModelStateApplies', () {
    test('applies when nothing explicit was given on this launch', () {
      expect(
        folderModelStateApplies(
          modelExplicit: false,
          providerExplicit: false,
          baseUrlExplicit: false,
          hasProviderPreconfig: false,
        ),
        isTrue,
      );
    });
    test('explicit launch flags win over the folder state', () {
      for (final (bool model, bool provider, bool baseUrl, bool preconfig) in [
        (true, false, false, false),
        (false, true, false, false),
        (false, false, true, false),
        (false, false, false, true),
      ]) {
        expect(
          folderModelStateApplies(
            modelExplicit: model,
            providerExplicit: provider,
            baseUrlExplicit: baseUrl,
            hasProviderPreconfig: preconfig,
          ),
          isFalse,
          reason: 'model=$model provider=$provider baseUrl=$baseUrl '
              'preconfig=$preconfig',
        );
      }
    });
  });

  group('save/load roundtrip', () {
    test('restores provider, model and base URL', () async {
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'openai-completions',
        modelId: 'kimi-k2.6',
        baseUrl: 'https://api.example.com/v1',
      );
      final state = await loadFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
      );
      expect(
        state,
        const FolderModelState(
          providerKind: 'openai-completions',
          modelId: 'kimi-k2.6',
          baseUrl: 'https://api.example.com/v1',
        ),
      );
    });

    test('a null base URL survives the roundtrip', () async {
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'anthropic',
        modelId: 'claude-x',
        baseUrl: null,
      );
      final state = await loadFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
      );
      expect(
        state,
        const FolderModelState(
          providerKind: 'anthropic',
          modelId: 'claude-x',
          baseUrl: null,
        ),
      );
    });

    test('folders do not see each other (per-folder scoping)', () async {
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work/a',
        providerKind: 'openai-completions',
        modelId: 'model-a',
        baseUrl: null,
      );
      expect(
        await loadFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work/b',
        ),
        isNull,
      );
    });
  });

  group('tolerant reads', () {
    test('a missing file loads as null', () async {
      expect(
        await loadFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
        ),
        isNull,
      );
    });

    test('corrupt JSON loads as null', () async {
      final path = folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work');
      await env.writeFile(path, '{not json');
      expect(
        await loadFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
        ),
        isNull,
      );
    });

    test('wrong field types load as null', () async {
      final path = folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work');
      await env.writeFile(
        path,
        jsonEncode({'providerKind': 42, 'modelId': ['x']}),
      );
      expect(
        await loadFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
        ),
        isNull,
      );
    });

    test('a JSON array loads as null', () async {
      final path = folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work');
      await env.writeFile(path, '[1,2,3]');
      expect(
        await loadFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
        ),
        isNull,
      );
    });

    test('a missing modelId loads as null', () async {
      final path = folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work');
      await env.writeFile(path, jsonEncode({'providerKind': 'anthropic'}));
      expect(
        await loadFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
        ),
        isNull,
      );
    });
  });

  group('customProvider pin (gh-1000)', () {
    test('round-trips the pinned entry name', () async {
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: 'https://api.kimi.com/coding/v1',
        customProvider: 'kimi_me',
      );
      final state = await loadFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
      );
      expect(state!.customProvider, 'kimi_me');
    });

    test('a pre-change state file loads with a null pin (AC4)', () async {
      final path = folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work');
      await env.writeFile(
        path,
        jsonEncode({
          'providerKind': 'openai-completions',
          'modelId': 'k3-256k',
          'baseUrl': 'https://api.kimi.com/coding/v1',
        }),
      );
      final state = await loadFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
      );
      expect(state, isNotNull);
      expect(state!.customProvider, isNull);
    });

    test('a non-string pin degrades to null', () async {
      final path = folderModelStatePath(sessionsRoot: '/sessions', cwd: '/work');
      await env.writeFile(
        path,
        jsonEncode({
          'providerKind': 'openai-completions',
          'modelId': 'k3-256k',
          'customProvider': 42,
        }),
      );
      final state = await loadFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
      );
      expect(state!.customProvider, isNull);
    });

    CustomProviderRegistry registryWith() => CustomProviderRegistry([
      CustomProviderEntry(
        name: 'ira-1',
        apiType: 'kimi',
        baseUrl: 'https://api.kimi.com/coding/v1',
        modelId: 'k3-256k',
        keyName: 'FA_KEY_API_KIMI_COM_IRA_1',
      ),
      CustomProviderEntry(
        name: 'kimi_me',
        apiType: 'openai',
        baseUrl: 'https://api.kimi.com/coding/v1',
        modelId: 'k3-256k',
        keyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
      ),
    ]);

    test('pinnedEntry resolves the named entry among same-modelId twins '
        '(AC1)', () {
      final state = FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: 'https://api.kimi.com/coding/v1',
        customProvider: 'kimi_me',
      );
      final decision = folderStateProviderEntry(state, registryWith());
      expect(decision.entry, isNotNull);
      expect(decision.entry!.name, 'kimi_me');
      expect(decision.entry!.keyName, 'FA_KEY_API_KIMI_COM_KIMI_ME');
      expect(decision.note, isNull);
    });

    test('pin resolution is case-insensitive', () {
      final state = FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: 'https://api.kimi.com/coding/v1',
        customProvider: 'Kimi_Me',
      );
      expect(folderStateProviderEntry(state, registryWith()).entry!.name,
          'kimi_me');
    });

    test('a deleted entry yields the E1 note with the model kept', () {
      final state = FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: 'https://api.kimi.com/coding/v1',
        customProvider: 'gone-provider',
      );
      final decision = folderStateProviderEntry(state, registryWith());
      expect(decision.entry, isNull);
      expect(decision.note, contains('gone-provider'));
      expect(decision.note, contains('no longer configured'));
    });

    test('no pin → no entry and no note (legacy state)', () {
      final state = FolderModelState(
        providerKind: 'openai-completions',
        modelId: 'k3-256k',
        baseUrl: 'https://api.kimi.com/coding/v1',
      );
      final decision = folderStateProviderEntry(state, registryWith());
      expect(decision.entry, isNull);
      expect(decision.note, isNull);
    });

    test('a null state yields nothing', () {
      final decision = folderStateProviderEntry(null, registryWith());
      expect(decision.entry, isNull);
      expect(decision.note, isNull);
    });
  });
}
