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
}
