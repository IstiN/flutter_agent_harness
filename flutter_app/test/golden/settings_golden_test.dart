/// Golden (screenshot) tests for `lib/settings.dart` — the BYOK connection
/// form (`AgentSettingsForm`) shared by the setup screen and the in-chat
/// settings dialog. Fakes and pump patterns mirror `test/settings_test.dart`
/// (in-memory `ProviderRegistry`, no engines needed: no test connects, so no
/// network/file/JS backends are touched).
library;

import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Pumps the settings form the way `test/settings_test.dart` does (scaffold +
/// scroll view) but inside the shared golden harness (theme + l10n + fixed
/// surface).
Future<void> _pumpSettingsForm(
  WidgetTester tester, {
  ProviderRegistry? registry,
  Size size = goldenSizeTall,
}) {
  return pumpGolden(
    tester,
    AgentSettingsForm(registry: registry, onConnect: (_) async {}),
    size: size,
    wrap: (child) => Scaffold(body: SingleChildScrollView(child: child)),
  );
}

/// Opens the provider dropdown and picks the entry labelled [label]
/// (verbatim from `test/settings_test.dart`).
Future<void> _selectProvider(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<Object>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('settings goldens', () {
    testWidgets('hosted provider form (OpenRouter)', (tester) async {
      await _pumpSettingsForm(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-or-test-key',
      );
      await tester.pumpAndSettle();

      // Key/model/url fields, the vision checkbox (auto-checked: the default
      // gpt-4o-mini model id suggests vision), and the hosted key note.
      await expectGolden(tester, 'settings_hosted');
    });

    testWidgets('hosted provider form on a wide surface', (tester) async {
      await _pumpSettingsForm(tester, size: goldenSizeWide);
      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-or-test-key',
      );
      await tester.pumpAndSettle();

      await expectGolden(tester, 'settings_hosted_wide');
    });

    testWidgets('custom preset form with editable base URL', (tester) async {
      await _pumpSettingsForm(tester);
      await _selectProvider(tester, 'Custom');
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'http://localhost:8080/v1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'llama3',
      );
      await tester.pumpAndSettle();

      // Optional key + helper, editable URL, and the CORS note.
      await expectGolden(tester, 'settings_custom');
    });

    testWidgets('saved custom provider shows edit/delete actions', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpSettingsForm(tester, registry: registry);
      await _selectProvider(tester, 'Acme');

      // Edit/Delete buttons and the "definition is saved" key note.
      await expectGolden(tester, 'settings_custom_saved');
    });

    testWidgets('on-device WebLLM form', (tester) async {
      await _pumpSettingsForm(tester);
      await _selectProvider(tester, 'On-device (WebLLM)');

      // The key/model/URL fields are replaced by the model picker with the
      // prompt-tools badge plus the offline/WebGPU notes.
      await expectGolden(tester, 'settings_webllm');
    });

    testWidgets('hosted connect without a key shows the validation error', (
      tester,
    ) async {
      await _pumpSettingsForm(tester);

      await tester.ensureVisible(find.text('Start chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start chat'));
      await tester.pumpAndSettle();

      expect(find.text('API key is required'), findsOneWidget);
      await expectGolden(tester, 'settings_validation');
    });
  });
}
