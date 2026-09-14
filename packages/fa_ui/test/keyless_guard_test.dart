// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `/models` fetch reporting two models.
Future<ModelsEndpointInfo> _fetch(
  String baseUrl, {
  required String apiKey,
}) async {
  return (
    const ['acme-1', 'acme-9'],
    const <String, int>{},
    const <String, int>{},
  );
}

/// A registry holding one keyed entry (z.ai) whose key does not resolve —
/// the post-restart shape the keyless-request guard exists for.
Future<ProviderRegistry> _registryWithKeyedKeylessEntry() async {
  final env = MemoryExecutionEnv();
  await env.writeFile(
    '${env.cwd}/providers.json',
    jsonEncode({
      'version': 1,
      'providers': [
        {
          'id': 'p1',
          'name': 'z.ai',
          'baseUrl': 'https://api.z.ai/api/coding/paas/v4',
          'modelId': 'glm-4.7',
          'requiresKey': true,
        },
      ],
    }),
  );
  return ProviderRegistry.load(env);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('keyless-request guard (issue #329)', () {
    test('a keyed entry whose key is gone is flagged', () async {
      final registry = await _registryWithKeyedKeylessEntry();
      final zai = registry.providers.single;
      expect(zai.requiresKey, isTrue);
      expect(isKeyMissingOnSurface(zai, registry: registry), isTrue);
    });

    test('a keyless-by-design entry is never flagged', () async {
      final registry = ProviderRegistry.inMemory();
      final ollama = await registry.add(
        name: 'Ollama',
        baseUrl: 'http://127.0.0.1:11434/v1',
        modelId: 'llama3',
      );
      // Never remembered a key — keyless local endpoints are legal.
      expect(isKeyMissingOnSurface(ollama, registry: registry), isFalse);
    });

    test('a resolved key clears the flag', () async {
      final registry = await _registryWithKeyedKeylessEntry();
      final zai = registry.providers.single;
      registry.rememberKey(zai.id, 'sk-zai');
      expect(isKeyMissingOnSurface(zai, registry: registry), isFalse);
    });

    testWidgets('a keyed entry with no key fails by name, never applies', (
      tester,
    ) async {
      final registry = await _registryWithKeyedKeylessEntry();
      final applied = <FaChatModelConfig>[];
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedModelPickerPage(
            connection: FaStaticChatConnection(
              providerKind: 'openai-completions',
              activeBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
              activeProviderId: 'p1',
              modelId: 'glm-4.7',
            ),
            onApply: (config) async => applied.add(config),
            registry: registry,
            modelsFetcher: _fetch,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The listed entry's model row taps into the guard: a named error
      // replaces the apply (the host never assembles a keyless request).
      await tester.tap(find.textContaining('acme-1', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(
        find.text('z.ai: no API key on this device — re-enter it.'),
        findsOneWidget,
      );
      expect(applied, isEmpty);
    });
  });

  group('key-storage note honesty (issue #329 AC3)', () {
    testWidgets(
      'a platform without a secure backend states session-only',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ProviderEditorPage(
              title: 'Edit provider',
              prefillName: 'Acme',
              prefillBaseUrl: 'https://acme.example/v1',
              prefillModelId: 'acme-1',
              modelsFetcher: _fetch,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The session-only wording — never discovered via a 401.
        expect(find.textContaining('never persisted'), findsOneWidget);
        expect(find.textContaining('Keychain'), findsNothing);
        // Android rides the secure group below (issue #329 flipped it).
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.linux,
      }),
    );

    testWidgets(
      'a secure-backend platform names the secure store',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ProviderEditorPage(
              title: 'Edit provider',
              prefillName: 'Acme',
              prefillBaseUrl: 'https://acme.example/v1',
              prefillModelId: 'acme-1',
              modelsFetcher: _fetch,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Keychain'), findsOneWidget);
        expect(find.textContaining('never persisted'), findsNothing);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.android,
      }),
    );
  });
}
