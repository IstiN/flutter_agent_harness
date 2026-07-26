import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  group('ThemeModeSection', () {
    testWidgets('hides when no controller is available', (tester) async {
      await _pump(tester, const ThemeModeSection());
      expect(find.text('Theme'), findsNothing);
    });

    testWidgets('dropdown reflects and switches the controller mode', (
      tester,
    ) async {
      final controller = ThemeController.inMemory();
      await _pump(tester, ThemeModeSection(controller: controller));

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<FahThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();
      expect(controller.mode, FahThemeMode.light);
      expect(find.text('Light'), findsOneWidget);
    });

    testWidgets('reads the controller from FahThemeScope', (tester) async {
      final controller = ThemeController.inMemory(FahThemeMode.dark);
      await _pump(
        tester,
        FahThemeScope(controller: controller, child: const ThemeModeSection()),
      );
      expect(find.text('Dark'), findsOneWidget);
    });
  });

  group('KeysSection', () {
    testWidgets('hides when neither store nor registry is available', (
      tester,
    ) async {
      await _pump(tester, const KeysSection());
      expect(find.text('Keys'), findsNothing);
    });

    testWidgets('lists known names with their sources, never values', (
      tester,
    ) async {
      final store = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-secret-value',
      });
      await _pump(tester, KeysSection(store: store));

      expect(find.text('Keys'), findsOneWidget);
      expect(find.text('OPENROUTER_API_KEY'), findsOneWidget);
      expect(find.text('HUGGINGFACE_TOKEN'), findsOneWidget);
      expect(find.text('saved'), findsOneWidget);
      expect(find.text('not set'), findsOneWidget);
      // Values are never displayed.
      expect(find.textContaining('sk-or-secret'), findsNothing);
    });

    testWidgets('set flow saves a value through the dialog', (tester) async {
      final store = SessionKeysStore.inMemory();
      await _pump(tester, KeysSection(store: store));

      // The first Set button belongs to OPENROUTER_API_KEY.
      await tester.tap(find.text('Set').first);
      await tester.pumpAndSettle();
      expect(find.byType(KeyEditorDialog), findsOneWidget);
      expect(find.text('Set OPENROUTER_API_KEY'), findsOneWidget);

      // Save stays disabled while the value is empty.
      final saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveButton.onPressed, isNull);

      await tester.enterText(find.byType(TextField), '  sk-or-new  ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.valueOf('OPENROUTER_API_KEY'), 'sk-or-new');
      expect(find.text('saved'), findsOneWidget);
      expect(find.textContaining('sk-or-new'), findsNothing);
    });

    testWidgets('delete flow asks for confirmation and removes the value', (
      tester,
    ) async {
      final store = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-secret',
      });
      await _pump(tester, KeysSection(store: store));

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete OPENROUTER_API_KEY?'), findsOneWidget);

      // Cancel keeps the value.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.has('OPENROUTER_API_KEY'), isTrue);

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(store.has('OPENROUTER_API_KEY'), isFalse);
      // Both known names are unset now.
      expect(find.text('not set'), findsNWidgets(2));
    });

    testWidgets('provider session keys are listed with set/delete actions', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'acme-secret');
      final store = SessionKeysStore.inMemory();
      await _pump(tester, KeysSection(store: store, registry: registry));

      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('provider key · this session'), findsOneWidget);
      expect(find.textContaining('acme-secret'), findsNothing);

      // Delete forgets the session key and the row disappears.
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(registry.keyFor(provider.id), isNull);
      expect(find.text('Acme'), findsNothing);
    });

    testWidgets('add-key dialog validates, normalizes, and saves', (
      tester,
    ) async {
      final store = SessionKeysStore.inMemory({'GITHUB_TOKEN': 'ghp_existing'});
      await _pump(tester, KeysSection(store: store));

      await tester.tap(find.text('Add key'));
      await tester.pumpAndSettle();
      expect(find.byType(AddKeyDialog), findsOneWidget);

      final nameField = find.byType(TextField).first;
      final valueField = find.byType(TextField).last;

      // Save stays disabled while either field is empty.
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );

      // An invalid name shape is rejected inline, nothing is saved.
      await tester.enterText(nameField, '1bad name');
      await tester.enterText(valueField, 'secret');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('starting with a letter'), findsOneWidget);
      expect(store.names, ['GITHUB_TOKEN']);

      // A duplicate (case-insensitive) is rejected inline.
      await tester.enterText(nameField, 'github_token');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('A key with this name already exists.'), findsOneWidget);
      expect(store.names, ['GITHUB_TOKEN']);

      // A valid name is uppercase-normalized, saved, and listed.
      await tester.enterText(nameField, 'gitlab_token');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(store.valueOf('GITLAB_TOKEN'), 'secret');
      expect(find.text('GITLAB_TOKEN'), findsOneWidget);
      // The value is never displayed.
      expect(find.textContaining('secret'), findsNothing);
    });

    testWidgets('add-key dialog rejects duplicates of the known names', (
      tester,
    ) async {
      final store = SessionKeysStore.inMemory();
      await _pump(tester, KeysSection(store: store));

      await tester.tap(find.text('Add key'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'openrouter_api_key',
      );
      await tester.enterText(find.byType(TextField).last, 'secret');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('A key with this name already exists.'), findsOneWidget);
      expect(store.names, isEmpty);
    });
  });

  group('AgentSettingsForm key prefill', () {
    testWidgets('prefills the API key from the saved-keys store', (
      tester,
    ) async {
      final store = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-saved',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentSettingsForm(keysStore: store, onConnect: (_) async {}),
          ),
        ),
      );
      final keyField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'API key'),
      );
      expect(keyField.controller?.text, 'sk-or-saved');
    });

    testWidgets('a dart-define-free empty store keeps the key field empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentSettingsForm(
              keysStore: SessionKeysStore.inMemory(),
              onConnect: (_) async {},
            ),
          ),
        ),
      );
      final keyField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'API key'),
      );
      expect(keyField.controller?.text, isEmpty);
    });
  });
}
