// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('addProviderPresetEnabled follows the catalog visibility rules', () {
    // ChatGPT Codex shipped (b6b85c66 unhid it): the catalog marks it
    // visible, so the preset is enabled — the TILE is gated on the host's
    // OAuth callback instead (see the picker tests below).
    final chatgpt = defaultAddProviderPresets.firstWhere(
      (p) => p.key == 'chatgpt',
    );
    expect(addProviderPresetEnabled(chatgpt), isTrue);

    // Visible catalog providers stay enabled without a build filter.
    final dial = defaultAddProviderPresets.firstWhere((p) => p.key == 'dial');
    expect(addProviderPresetEnabled(dial), isTrue);

    // App-only presets (no catalog entry) are always enabled.
    final kimi = defaultAddProviderPresets.firstWhere((p) => p.key == 'kimi');
    expect(addProviderPresetEnabled(kimi), isTrue);
    final custom = defaultAddProviderPresets.firstWhere(
      (p) => p.key == 'custom',
    );
    expect(addProviderPresetEnabled(custom), isTrue);
  });

  test('the Copilot preset follows the visible catalog spec', () {
    final copilot = defaultAddProviderPresets.firstWhere(
      (p) => p.key == 'copilot',
    );
    expect(addProviderPresetEnabled(copilot), isTrue);
  });

  test('the AIIN preset is listed first and follows the catalog', () {
    // aiin.by is the flagship hosted provider — first in the picker.
    expect(defaultAddProviderPresets.first.key, 'aiin');
    final aiin = defaultAddProviderPresets.first;
    expect(addProviderPresetEnabled(aiin), isTrue);
  });

  testWidgets('the AIIN tile hides without the host callback and routes '
      'with one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AddProviderPresetPickerPage()),
    );
    expect(find.text('AIIN'), findsNothing);

    var called = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AddProviderPresetPickerPage(
          onAiinConnect: () {
            called++;
          },
        ),
      ),
    );
    expect(find.text('AIIN'), findsOneWidget);
    await tester.tap(find.text('AIIN'));
    await tester.pumpAndSettle();
    expect(called, 1);
  });

  testWidgets('the Copilot tile hides without the host callback and routes '
      'with one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AddProviderPresetPickerPage()),
    );
    expect(find.text('GitHub Copilot'), findsNothing);

    var called = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AddProviderPresetPickerPage(
          onCopilotConnect: () {
            called++;
          },
        ),
      ),
    );
    expect(find.text('GitHub Copilot'), findsOneWidget);
    await tester.tap(find.text('GitHub Copilot'));
    await tester.pumpAndSettle();
    expect(called, 1);
    // The picker popped before the host flow took over (the chatgpt
    // routing precedent).
    expect(find.byType(AddProviderPresetPickerPage), findsNothing);
  });

  test('addProviderPresetEnabled honors the FA_PROVIDERS runtime filter', () {
    final dial = defaultAddProviderPresets.firstWhere((p) => p.key == 'dial');
    final ollama = defaultAddProviderPresets.firstWhere(
      (p) => p.key == 'ollama',
    );
    providerFilterEnvOverride = 'dial';
    try {
      expect(addProviderPresetEnabled(dial), isTrue);
      // App-only presets are not in the catalog: the filter cannot
      // reference them, so they stay enabled.
      expect(addProviderPresetEnabled(ollama), isTrue);
      final openai = defaultAddProviderPresets.firstWhere(
        (p) => p.key == 'openai',
      );
      expect(addProviderPresetEnabled(openai), isFalse);
    } finally {
      providerFilterEnvOverride = null;
    }
  });

  testWidgets('the ChatGPT tile hides without the OAuth callback and shows '
      'with one', (tester) async {
    // The catalog marks chatgpt visible — the tile gating is the host's
    // OAuth callback (same pattern as the Copilot tile).
    await tester.pumpWidget(
      const MaterialApp(home: AddProviderPresetPickerPage()),
    );
    expect(find.text('ChatGPT (Codex)'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: AddProviderPresetPickerPage(onChatGptOAuth: _noop),
      ),
    );
    expect(find.text('ChatGPT (Codex)'), findsOneWidget);
    expect(find.text('DIAL'), findsOneWidget);
    // Off-screen tiles are lazy-built by the ListView — include offstage.
    expect(find.text('Ollama Cloud', skipOffstage: false), findsOneWidget);
  });

  testWidgets('ProviderEditorPage keeps the base URL editable in preset mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ProviderEditorPage(title: 'DIAL', preset: ProviderPreset.dial),
      ),
    );
    await tester.pumpAndSettle();
    final urlField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'https://ai-proxy.lab.epam.com'),
    );
    // TextField.enabled is nullable: null means enabled.
    expect(urlField.enabled ?? true, isTrue);
  });
}

void _noop() {}
