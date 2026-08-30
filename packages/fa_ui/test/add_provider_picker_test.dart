// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('addProviderPresetEnabled follows the catalog visibility rules', () {
    // ChatGPT Codex is visible:false in the catalog (WebSocket adapter
    // pending) — it must never be offered, even though a preset exists.
    final chatgpt = defaultAddProviderPresets.firstWhere(
      (p) => p.key == 'chatgpt',
    );
    expect(addProviderPresetEnabled(chatgpt), isFalse);

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

  testWidgets('the Add-provider picker never lists hidden catalog providers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AddProviderPresetPickerPage(
          // Even with an OAuth callback wired the ChatGPT tile stays
          // hidden — the catalog marks the provider not visible.
          onChatGptOAuth: _noop,
        ),
      ),
    );
    expect(find.text('ChatGPT (Codex)'), findsNothing);
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
