import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/provider_registry.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/ui/screens/settings_key_dialogs.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:archive/archive.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/services/upload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

/// A minimal valid theme pack zip (same shape as the store-level tests).
Uint8List _packZip() {
  final archive = Archive()
    ..add(
      ArchiveFile.bytes(
        'theme.json',
        utf8.encode(
          jsonEncode({
            'name': 'Forest Walk',
            'version': '1.0.0',
            'colors': {
              'dark': {'accent': '#2E7D32'},
            },
            'wallpaper': {'asset': 'bg.png', 'fit': 'cover'},
          }),
        ),
      ),
    )
    ..add(ArchiveFile.bytes('bg.png', _tinyPng));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 1×1 transparent PNG (a real decodable header, per the store tests).
final Uint8List _tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x0A, //
  0x5B, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Fake [UploadPicker] returning canned files without a platform dialog.
final class _FakePicker implements UploadPicker {
  _FakePicker(this.files);

  List<UploadFile> files;

  @override
  Future<List<UploadFile>> pick() async => files;
}

UploadFile _uploadFile(String name, Uint8List bytes) =>
    (name: name, bytes: bytes);
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
            body: SingleChildScrollView(
              child: AgentSettingsForm(
                keysStore: store,
                onConnect: (_) async {},
              ),
            ),
          ),
        ),
      );
      // Provider-first: select OpenRouter to reveal the key field (its
      // named key prefills from the store).
      await tester.ensureVisible(find.text('OpenRouter'));
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
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
            body: SingleChildScrollView(
              child: AgentSettingsForm(
                keysStore: SessionKeysStore.inMemory(),
                onConnect: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('OpenRouter'));
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      final keyField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'API key'),
      );
      expect(keyField.controller?.text, isEmpty);
    });
  });

  group('CliOnlySettingsSection (issue #288 AC4)', () {
    testWidgets('lists every registry CLI-only setting with its reason',
        (tester) async {
      await _pump(tester, const CliOnlySettingsSection());

      expect(find.text('CLI-only settings'), findsOneWidget);
      // One row per registry entry — the app renders the registry, it
      // cannot drift from it.
      expect(
        find.byIcon(Icons.terminal),
        findsNWidgets(cliOnlySettings.length),
      );
      for (final setting in cliOnlySettings) {
        expect(
          find.text(cliOnlyJustifications[setting]!),
          findsOneWidget,
          reason: 'the WHY for ${setting.name} must be user-visible',
        );
      }
    });

    testWidgets('never renders an empty reason row (silent absence guard)',
        (tester) async {
      await _pump(tester, const CliOnlySettingsSection());
      final reasons = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .where((text) => text.isNotEmpty);
      expect(reasons, isNotEmpty);
      expect(find.text(''), findsNothing);
    });
  });
  group('ThemePacksSection', () {
    testWidgets('hides when no store scope is available', (tester) async {
      await _pump(tester, const ThemePacksSection());
      expect(find.text('Theme packs'), findsNothing);
    });

    testWidgets('lists installed packs with their notes and removals '
        'revert the active choice', (tester) async {
      final env = MemoryExecutionEnv();
      final store = await ThemePackStore.load(env);
      final controller = ThemeController.inMemory();
      final install = await store.installFromZip(_packZip());
      expect(install.spec, isNotNull, reason: install.reasons.join('; '));
      await _pump(
        tester,
        ThemePackScope(
          store: store,
          child: FahThemeScope(
            controller: controller,
            child: ThemePacksSection(picker: _FakePicker(const [])),
          ),
        ),
      );

      expect(find.text('Theme packs'), findsOneWidget);
      expect(find.text('Default Fa look'), findsOneWidget);
      expect(find.text('Forest Walk'), findsOneWidget);
      // A pack with a wallpaper always shows its note (the warning list
      // is empty here, so only the wallpaper chip renders).
      expect(find.text('wallpaper'), findsOneWidget);

      // Selecting the pack drives the controller; removing it reverts.
      await tester.tap(find.text('Forest Walk'));
      await tester.pumpAndSettle();
      expect(controller.packId, 'forest-walk');

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(store.packs, isEmpty);
      // The active choice reverts with the pack (never a dangling id).
      expect(controller.packId, isNull);
      expect(find.text('Forest Walk'), findsNothing);
    });

    testWidgets('import through the picker installs the pack and reports '
        'the result', (tester) async {
      final store = await ThemePackStore.load(MemoryExecutionEnv());
      final controller = ThemeController.inMemory();
      final picker = _FakePicker([_uploadFile('forest.zip', _packZip())]);
      await _pump(
        tester,
        ThemePackScope(
          store: store,
          child: FahThemeScope(
            controller: controller,
            child: ThemePacksSection(
              picker: picker,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Import theme pack'));
      await tester.pumpAndSettle();

      expect(store.packs.single.name, 'Forest Walk');
      picker.files = [_uploadFile('bad.zip', Uint8List.fromList([1, 2, 3]))];
      expect(find.textContaining('installed'), findsOneWidget);
      // SnackBars queue: let the install report retire before tapping
      // again, or the rejection report waits out its 6s slot.
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import theme pack'));
      await tester.pumpAndSettle();
      expect(find.textContaining('rejected'), findsOneWidget);
    });
  });
}
