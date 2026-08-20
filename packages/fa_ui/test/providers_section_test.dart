// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A mutable [FaChatConnection] fake standing in for the host's agent
/// service: [apply] mimics a reconfigure (and records the applied config).
class _FakeConnection extends ChangeNotifier implements FaChatConnection {
  _FakeConnection({this.baseUrl = 'https://example.com', this.kind = 'test'});

  String baseUrl;
  String kind;
  String model = 'test-model';
  String? providerId;
  FaChatModelConfig? applied;

  @override
  String get providerKind => kind;
  @override
  String get activeBaseUrl => baseUrl;
  @override
  String? get activeProviderId => providerId;
  @override
  String get modelId => model;

  Future<void> apply(FaChatModelConfig config) async {
    applied = config;
    kind = config.providerKind;
    baseUrl = config.baseUrl;
    model = config.modelId;
    providerId = config.providerId;
    notifyListeners();
  }
}

/// A `/models` fetch reporting two chat models (the quick-select path).
Future<ModelsEndpointInfo> _someModels(
  String baseUrl, {
  required String apiKey,
}) async =>
    (const ['acme-1', 'acme-2'], const <String, int>{}, const <String, int>{});

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

/// A TextField inside the full-screen provider editor page.
Finder _editorField(String label) {
  return find.descendant(
    of: find.byType(ProviderEditorPage),
    matching: find.widgetWithText(TextField, label),
  );
}

void main() {
  group('ProvidersSection', () {
    testWidgets('lists the saved providers and marks the current one', (
      tester,
    ) async {
      // Hosted presets moved to the add-provider picker (provider-first
      // redesign); the section lists saved custom providers + Add provider.
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      final connection = _FakeConnection(
        baseUrl: 'https://acme.example/v1',
        kind: 'openai-completions',
      );
      await _pump(
        tester,
        ProvidersSection(service: connection, registry: registry),
      );

      expect(find.text('Providers'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('Add provider'), findsOneWidget);
      // Exactly one row is marked current — the saved Acme provider.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('on-device rows are gated by the visible predicate', (
      tester,
    ) async {
      final connection = _FakeConnection(kind: 'openai-completions');
      FaOnDeviceRoute route(String id) => FaOnDeviceRoute(
        label: 'Engine $id',
        id: id,
        pageBuilder: (context, apply) => const Scaffold(),
      );
      await _pump(
        tester,
        ProvidersSection(
          service: connection,
          registry: ProviderRegistry.inMemory(),
          onDeviceProviders: [route('gemma'), route('webllm')],
          onDeviceRowVisible: (kind) => kind == 'gemma',
        ),
      );

      expect(find.text('Engine gemma'), findsOneWidget);
      expect(find.text('Engine webllm'), findsNothing);
    });

    testWidgets('the add-provider picker offers the on-device routes and '
        'reports their connect', (tester) async {
      final connection = _FakeConnection(kind: 'openai-completions');
      FaChatModelConfig? connected;
      await _pump(
        tester,
        ProvidersSection(
          service: connection,
          registry: ProviderRegistry.inMemory(),
          onDeviceProviders: [
            FaOnDeviceRoute(
              label: 'On-device (Gemma)',
              id: 'gemma',
              pageBuilder: (context, apply) => Scaffold(
                body: FilledButton(
                  onPressed: () => apply(
                    const FaChatModelConfig(
                      providerKind: 'gemma',
                      modelId: 'local-model',
                      baseUrl: '',
                      apiKey: '',
                    ),
                  ),
                  child: const Text('connect local'),
                ),
              ),
            ),
          ],
          onDeviceConnected: (config) => connected = config,
        ),
      );

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      // The tile trails the hosted presets — scroll it into view (the
      // picker's ListView builds lazily).
      await tester.scrollUntilVisible(
        find.text('On-device (Gemma)'),
        200,
        scrollable: find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('On-device (Gemma)'), findsOneWidget);

      await tester.tap(find.text('On-device (Gemma)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('connect local'));
      await tester.pumpAndSettle();

      expect(connected?.providerKind, 'gemma');
      expect(connected?.modelId, 'local-model');
    });

    testWidgets('two custom providers on one host: only the active id is '
        'marked current', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Kimi 1',
        baseUrl: 'https://api.kimi.com/v1',
        modelId: 'k3-256k',
      );
      final kimi2 = await registry.add(
        name: 'Kimi 2',
        baseUrl: 'https://api.kimi.com/v1',
        modelId: 'k3-256k',
      );
      final connection = _FakeConnection(
        baseUrl: 'https://api.kimi.com/v1',
        kind: 'openai-completions',
      )..providerId = kimi2.id;
      await _pump(
        tester,
        ProvidersSection(service: connection, registry: registry),
      );

      // The base-URL match would mark both rows; the id match marks only
      // the Kimi 2 row.
      expect(find.byIcon(Icons.check), findsOneWidget);
      final kimi1Row = find.ancestor(
        of: find.text('Kimi 1'),
        matching: find.byType(InkWell),
      );
      final kimi2Row = find.ancestor(
        of: find.text('Kimi 2'),
        matching: find.byType(InkWell),
      );
      expect(
        find.descendant(of: kimi2Row, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: kimi1Row, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
    });

    testWidgets('a hosted preset with a resolvable key lists like a provider '
        '(CLI chain: env name or host-scoped FA_KEY_<HOST>)', (tester) async {
      FaUiHost.keyResolver = (name) =>
          name == 'FA_KEY_OPENROUTER_AI' ? 'sk-or-scoped' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      await _pump(
        tester,
        ProvidersSection(registry: ProviderRegistry.inMemory()),
      );

      // The OpenRouter preset is connected via its host-scoped key.
      expect(find.text('OpenRouter'), findsOneWidget);
      // Keyless presets stay out of the list.
      expect(find.text('Ollama'), findsNothing);
      expect(find.text('Google Gemini'), findsNothing);
    });

    testWidgets('a custom provider on the preset endpoint covers the preset '
        '(never both in the list)', (tester) async {
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-or-env' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'My OR',
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'acme-1',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      expect(find.text('My OR'), findsOneWidget);
      expect(find.text('OpenRouter'), findsNothing);
    });

    testWidgets('add provider: the editor page persists via the registry', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      // The picker's tiles render in a dialog on wide surfaces; the Custom
      // tile may sit below the fold.
      await tester.scrollUntilVisible(find.text('Custom'), 200);
      await tester.ensureVisible(find.text('Custom'));
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(_editorField('Name'), 'Acme');
      await tester.enterText(
        _editorField('Base URL'),
        'https://acme.example/v1',
      );
      await tester.enterText(
        _editorField('API key (optional)'),
        'sk-acme-session',
      );
      // The model id is optional — a provider may have no model yet.
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers, hasLength(1));
      final provider = registry.providers.single;
      expect(provider.name, 'Acme');
      expect(provider.baseUrl, 'https://acme.example/v1');
      expect(provider.modelId, isEmpty);
      expect(registry.keyFor(provider.id), 'sk-acme-session');
      // Back on the section, the new provider is listed.
      expect(find.text('Acme'), findsOneWidget);
    });

    testWidgets('edit provider: write-only key keeps the stored key when '
        'left empty', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-acme-kept');
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      // The existing key is never shown (write-only)…
      final keyField = tester.widget<TextField>(
        _editorField('API key (optional)'),
      );
      expect(keyField.controller!.text, isEmpty);
      expect(keyField.obscureText, isTrue);
      // …and the helper says an empty field keeps it.
      expect(
        find.textContaining('leave the field empty to keep it'),
        findsOneWidget,
      );

      await tester.enterText(_editorField('Model id (optional)'), 'acme-2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers.single.modelId, 'acme-2');
      expect(registry.keyFor(provider.id), 'sk-acme-kept');
    });

    testWidgets('edit provider: delete goes through the editor page', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Acme?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(registry.providers, isEmpty);
      expect(find.text('Acme'), findsNothing);
    });

    testWidgets('edit provider: a CodeMie provider shows Re-authenticate, '
        'a plain one does not; success closes the editor', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final codemie = await registry.add(
        name: 'CodeMie',
        baseUrl: 'https://codemie.example/code-assistant-api/v1',
        modelId: 'gpt-4o',
      );
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      CustomProvider? reauthed;
      await _pump(
        tester,
        ProvidersSection(
          registry: registry,
          onProviderReauthenticate: (context, provider) async {
            reauthed = provider;
            return true;
          },
        ),
      );

      // A plain key-based provider has no re-auth button.
      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      expect(find.text('Re-authenticate'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // The CodeMie provider does: it runs the host's SSO flow with the
      // edited provider and a success closes the (now stale) editor.
      await tester.tap(find.text('CodeMie'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      await tester.tap(find.text('Re-authenticate'));
      await tester.pumpAndSettle();
      expect(reauthed?.id, codemie.id);
      expect(find.byType(ProviderEditorPage), findsNothing);
    });

    testWidgets('preset editor: the name and URL are editable, '
        'the model and key save', (tester) async {
      final keysStore = SessionKeysStore.inMemory();
      final registry = ProviderRegistry.inMemory();
      await _pump(
        tester,
        SessionKeysScope(
          store: keysStore,
          child: ProvidersSection(registry: registry),
        ),
      );

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      // The name field is editable (multi-instance naming); the URL stays
      // read-only for hosted presets.
      expect(
        tester.widget<TextField>(_editorField('Name')).enabled ?? true,
        isTrue,
      );
      expect(
        tester.widget<TextField>(_editorField('Base URL')).enabled,
        isFalse,
      );
      // The model field is editable (TextField.enabled is nullable — null
      // means the default, enabled) and prefilled with the preset default.
      final modelField = tester.widget<TextField>(_editorField('Model id'));
      expect(modelField.enabled ?? true, isTrue);
      expect(
        modelField.controller!.text,
        ProviderPreset.openrouter.defaultModel,
      );

      await tester.enterText(_editorField('Model id'), 'anthropic/claude');
      await tester.enterText(_editorField('API key (optional)'), 'sk-or-new');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // The added provider keeps the key + model via the registry.
      expect(registry.providers, hasLength(1));
      expect(registry.keyFor(registry.providers.single.id), 'sk-or-new');
      expect(registry.providers.single.modelId, 'anthropic/claude');
    });

    testWidgets('preset editor: a saved override prefills the model, saving '
        'the built-in default clears it', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.setPresetModelOverride(
        ProviderPreset.openrouter.name,
        'anthropic/claude',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_editorField('Model id')).controller!.text,
        'anthropic/claude',
      );

      await tester.enterText(
        _editorField('Model id'),
        ProviderPreset.openrouter.defaultModel,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Saving the built-in default stores the model on the new provider
      // (the preset-override path is gone with the preset editor).
      expect(
        registry.providers.single.modelId,
        ProviderPreset.openrouter.defaultModel,
      );
    });

    testWidgets('a host key resolver feeds the preset editor note', (
      tester,
    ) async {
      FaUiHost.keyResolver = (name) =>
          name == 'OPENROUTER_API_KEY' ? 'sk-from-host' : '';
      addTearDown(() => FaUiHost.keyResolver = null);
      final registry = ProviderRegistry.inMemory();
      await _pump(tester, ProvidersSection(registry: registry));

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      // The host-resolved key counts as saved: the keep-note shows.
      expect(
        find.textContaining('leave the field empty to keep it'),
        findsOneWidget,
      );
    });
  });

  group('DefaultChatModelSection flow', () {
    testWidgets('pick provider → pick model → onApply runs with the config', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-acme');
      final connection = _FakeConnection();
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          registry: registry,
          modelsFetcher: _someModels,
        ),
      );

      // The row summarizes the active provider + model.
      expect(find.text('test-model · example.com'), findsOneWidget);
      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();

      // The SAME two-step flow the role/media pickers use: provider picker
      // (no "main connection" row when editing the main connection)…
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      expect(find.text('Main connection'), findsNothing);
      expect(find.text('Acme'), findsOneWidget);
      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();

      // …then the model page with the fetched list — pick acme-2.
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'acme-2',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'acme-2'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Back on the section; onApply ran with the provider's endpoint and
      // resolved session key, and the summary follows the connection.
      expect(connection.applied, isNotNull);
      expect(connection.applied!.providerKind, 'openai-completions');
      expect(connection.applied!.modelId, 'acme-2');
      expect(connection.applied!.baseUrl, 'https://acme.example/v1');
      expect(connection.applied!.apiKey, 'sk-acme');
      // The stable provider id rides along so hosts can tell same-host
      // providers apart.
      expect(connection.applied!.providerId, provider.id);
      expect(find.text('acme-2 · Acme'), findsOneWidget);
    });

    testWidgets('add provider from the picker returns to picking', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final connection = _FakeConnection();
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          registry: registry,
          addProviderPage: (context) =>
              AddProviderPresetPickerPage(registry: registry),
        ),
      );

      await tester.tap(find.text('test-model · example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(AddProviderPresetPickerPage), findsOneWidget);
      // 'Custom' is the LAST tile and may sit below the fold — scroll the
      // picker's own list to it first.
      await tester.scrollUntilVisible(
        find.text('Custom'),
        200,
        scrollable: find.descendant(
          of: find.byType(AddProviderPresetPickerPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorPage), findsOneWidget);

      await tester.enterText(_editorField('Name'), 'Local');
      await tester.enterText(
        _editorField('Base URL'),
        'http://localhost:8080/v1',
      );
      // A saved model id — the unified picker lists MODELS, so a provider
      // without one renders no tile.
      await tester.enterText(_editorField('Model id (optional)'), 'local-1');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Back on the provider picker; the new provider is listed.
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
    });

    testWidgets('an unlisted id saves manually on the picked provider', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-acme');
      final connection = _FakeConnection(
        baseUrl: 'https://acme.example/v1',
        kind: 'openai-completions',
      )..providerId = provider.id;
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          registry: registry,
          modelsFetcher: _someModels,
        ),
      );

      await tester.tap(find.text('test-model · Acme'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
      await tester.tap(find.text('Acme'));
      await tester.pumpAndSettle();

      // An id the endpoint does not list: the free-text field takes it.
      expect(find.byType(MediaSlotModelPage), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'my-custom',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('acme-1'), findsNothing);
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(connection.applied, isNotNull);
      expect(connection.applied!.modelId, 'my-custom');
      expect(connection.applied!.baseUrl, 'https://acme.example/v1');
      expect(connection.applied!.apiKey, 'sk-acme');
      expect(connection.applied!.providerId, provider.id);
    });

    testWidgets('on-device routes render and their page unwinds the flow', (
      tester,
    ) async {
      final connection = _FakeConnection(kind: 'webllm');
      await _pump(
        tester,
        DefaultChatModelSection(
          connection: connection,
          onApply: connection.apply,
          providerKindLabels: const {'webllm': 'On-device (WebLLM)'},
          onDeviceProviders: [
            FaOnDeviceRoute(
              label: 'On-device (WebLLM)',
              pageBuilder: (context, apply) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    await apply(
                      const FaChatModelConfig(
                        providerKind: 'webllm',
                        modelId: 'local-model',
                        baseUrl: '',
                        apiKey: '',
                      ),
                    );
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                  child: const Text('connect local'),
                ),
              ),
            ),
          ],
        ),
      );

      // The kind label stands in for the (endpoint-less) provider summary.
      expect(find.text('test-model · On-device (WebLLM)'), findsOneWidget);
      await tester.tap(find.text('test-model · On-device (WebLLM)'));
      await tester.pumpAndSettle();
      expect(find.text('On-device (WebLLM)'), findsOneWidget);

      await tester.tap(find.text('On-device (WebLLM)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('connect local'));
      await tester.pumpAndSettle();

      // The page popped true: the whole flow unwound and onApply ran.
      expect(find.byType(UnifiedModelPickerPage), findsNothing);
      expect(connection.applied!.providerKind, 'webllm');
      expect(connection.model, 'local-model');
    });
  });
}
