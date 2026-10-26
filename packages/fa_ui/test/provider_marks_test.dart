// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ProviderMark renders a branded tile for every preset key', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final preset in defaultAddProviderPresets)
                ProviderMark(preset.key),
              const ProviderMark('unknown-fallback'),
            ],
          ),
        ),
      ),
    );
    expect(
      find.byType(ProviderMark),
      findsNWidgets(defaultAddProviderPresets.length + 1),
    );
    expect(tester.takeException(), isNull);
  });

  test('the AIIN mark resolves from the api and auth hosts', () {
    expect(providerMarkKeyForBaseUrl('https://api.aiin.by/v1'), 'aiin');
    expect(providerMarkKeyForBaseUrl('https://auth.aiin.by'), 'aiin');
    expect(
      providerMarkKeyForBaseUrl('https://openrouter.ai/api/v1'),
      isNot('aiin'),
    );
  });

  test('providerMarkKey maps every hosted preset to its branded mark', () {
    expect(providerMarkKey(ProviderPreset.aiin), 'aiin');
    expect(providerMarkKey(ProviderPreset.openrouter), 'openrouter');
    expect(providerMarkKey(ProviderPreset.ollamaCloud), 'ollama');
    expect(providerMarkKey(ProviderPreset.gemini), 'google');
    expect(providerMarkKey(ProviderPreset.dial), 'dial');
    // Keyless/on-device presets render the generic stack.
    expect(providerMarkKey(ProviderPreset.minimax), 'custom');
    expect(providerMarkKey(ProviderPreset.custom), 'custom');
    expect(providerMarkKey(ProviderPreset.webllm), 'custom');
  });

  test('saved entries and raw URLs infer the mark from the endpoint', () {
    const entry = CustomProvider(
      id: 'p1',
      name: 'OR',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'z-ai/glm-5.2',
    );
    expect(providerMarkKey(entry), 'openrouter');
    expect(providerMarkKey('https://api.openai.com/v1'), 'openai');
    expect(providerMarkKey(42), 'custom');
  });
}
