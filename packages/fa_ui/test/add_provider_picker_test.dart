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

  testWidgets('the AIIN tile disables without any flow (option C) and '
      'routes with one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AddProviderPresetPickerPage()),
    );
    // Issue #1321 option C: an unwired sign-in tile is visible but
    // disabled under a tooltip — never silently hidden.
    expect(find.text('AIIN'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('AIIN'), matching: find.byType(ListTile)),
    );
    expect(tile.enabled, isFalse);
    expect(
      find.byTooltip('Sign-in flow not available in this app'),
      findsWidgets,
    );

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

  testWidgets('the Copilot tile disables without any flow and routes with '
      'one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AddProviderPresetPickerPage()),
    );
    expect(find.text('GitHub Copilot'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('GitHub Copilot'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.enabled, isFalse);

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

  testWidgets('the ChatGPT tile disables without any flow and shows with '
      'one', (tester) async {
    // The catalog marks chatgpt visible — the tile gating is the sign-in
    // flow (same pattern as the Copilot tile).
    await tester.pumpWidget(
      const MaterialApp(home: AddProviderPresetPickerPage()),
    );
    expect(find.text('ChatGPT (Codex)'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('ChatGPT (Codex)'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.enabled, isFalse);

    await tester.pumpWidget(
      const MaterialApp(
        home: AddProviderPresetPickerPage(onChatGptOAuth: _noop),
      ),
    );
    expect(find.text('ChatGPT (Codex)'), findsOneWidget);
    // The four extra disabled tiles push DIAL below the lazy-build window.
    expect(find.text('DIAL', skipOffstage: false), findsOneWidget);
  });

  testWidgets('the sso bundle enables all four sign-in tiles without any '
      'host callbacks', (tester) async {
    final registry = ProviderRegistry.inMemory();
    await tester.pumpWidget(
      MaterialApp(
        home: AddProviderPresetPickerPage(
          registry: registry,
          sso: FaUiSso(registry: registry),
        ),
      ),
    );
    for (final tileName in [
      'AIIN',
      'ChatGPT (Codex)',
      'GitHub Copilot',
      'CodeMie',
    ]) {
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text(tileName), matching: find.byType(ListTile)),
      );
      expect(tile.enabled, isTrue, reason: tileName);
      expect(
        find.byTooltip('Sign-in flow not available in this app'),
        findsNothing,
        reason: tileName,
      );
    }
  });

  testWidgets('a preset dropped by the FA_PROVIDERS filter stays hidden and '
      'is logged', (tester) async {
    // AC3's log half: the filter drop must name every hidden tile.
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    // Restore INSIDE the body: the binding's foundation-var invariant
    // (debugPrint must equal debugPrintThrottled) runs before addTearDown.
    try {
      providerFilterEnvOverride = 'dial';
      await tester.pumpWidget(
        const MaterialApp(home: AddProviderPresetPickerPage()),
      );
      // A build-intentional catalog filter HIDES (unlike the flow gating).
      expect(find.text('OpenAI'), findsNothing);
      expect(find.text('DIAL'), findsOneWidget);
      expect(
        logs.any(
          (line) =>
              line.contains('openai (OpenAI)') && line.contains('FA_PROVIDERS'),
        ),
        isTrue,
      );
    } finally {
      debugPrint = originalDebugPrint;
      providerFilterEnvOverride = null;
    }
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

  testWidgets('gh-1378 AC3: a manual add on a quota-marked endpoint runs '
      'the endpoint-confirmation probe at add time', (tester) async {
    // The manual-code path (Custom tile → editor → save) lands the entry
    // with a stored key — the row's gauge must be confirmed by a live
    // fetch NOW, not at the next pull-to-refresh.
    final codemie = _CountingQuotaAdapter();
    final registry = ProviderRegistry.inMemory();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddProviderPresetPickerPage(
            registry: registry,
            quotas: ProviderQuotaService(adapters: {'codemie': codemie}),
          ),
        ),
      ),
    );
    // Custom is the last tile — below the fold in the test viewport.
    await tester.scrollUntilVisible(
      find.text('Custom'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(ProviderEditorPage),
        matching: find.widgetWithText(TextField, 'Name'),
      ),
      'CodeMie Lab',
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(ProviderEditorPage),
        matching: find.widgetWithText(TextField, 'Base URL'),
      ),
      'https://codemie.lab.example/code-assistant-api/v1',
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(ProviderEditorPage),
        matching: find.widgetWithText(TextField, 'API key (optional)'),
      ),
      'k-codemie',
    );
    await tester.scrollUntilVisible(
      find.text('Save'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // The probe is unawaited — pump once so its microtask chain drains,
    // then hold the contract.
    await tester.pump();
    expect(
      codemie.fetches,
      1,
      reason: 'the manual add must schedule the confirmation probe',
    );
    expect(registry.providers, hasLength(1));
  });
}

/// A quota adapter that counts its fetches (the probe contract).
class _CountingQuotaAdapter implements QuotaAdapter {
  var fetches = 0;

  @override
  Future<QuotaFetchResult> fetch() async {
    fetches++;
    return const QuotaFetchResult.unknown('probe');
  }
}

void _noop() {}
