// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gives OpenRouter a resolvable host key so its preset row lists like a
/// connected provider (the section's `_editPreset` entry point).
void _connectOpenRouter() {
  FaUiHost.keyResolver = (name) =>
      name == 'OPENROUTER_API_KEY' ? 'sk-or-host' : '';
}

/// A TextField inside the full-screen provider editor page.
Finder _editorField(String label) {
  return find.descendant(
    of: find.byType(ProviderEditorPage),
    matching: find.widgetWithText(TextField, label),
  );
}

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

/// Opens the connected OpenRouter preset row's editor.
Future<void> _openPresetEditor(WidgetTester tester) async {
  await tester.tap(find.text('OpenRouter'));
  await tester.pumpAndSettle();
  expect(find.byType(ProviderEditorPage), findsOneWidget);
}

void main() {
  testWidgets('cancelling the preset editor lands nothing', (tester) async {
    _connectOpenRouter();
    addTearDown(() => FaUiHost.keyResolver = null);
    final registry = ProviderRegistry.inMemory();
    await _pump(tester, ProvidersSection(registry: registry));

    await _openPresetEditor(tester);
    // Back without saving: the editor pops with a null result and the
    // section adds nothing.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(registry.providers, isEmpty);
    expect(find.byType(ProviderEditorPage), findsNothing);
  });

  testWidgets('saving the preset editor lands a new entry on the preset '
      'endpoint with the typed key', (tester) async {
    _connectOpenRouter();
    addTearDown(() => FaUiHost.keyResolver = null);
    final registry = ProviderRegistry.inMemory();
    await _pump(tester, ProvidersSection(registry: registry));

    await _openPresetEditor(tester);
    await tester.enterText(_editorField('API key (optional)'), 'sk-or-new');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(registry.providers, hasLength(1));
    final provider = registry.providers.single;
    expect(provider.name, 'OpenRouter');
    expect(provider.baseUrl, 'https://openrouter.ai/api/v1');
    expect(provider.modelId, ProviderPreset.openrouter.defaultModel);
    expect(registry.keyFor(provider.id), 'sk-or-new');
  });

  testWidgets('a landing on the preset endpoint while the editor is open '
      'flips the save into an in-place update', (tester) async {
    _connectOpenRouter();
    addTearDown(() => FaUiHost.keyResolver = null);
    final registry = ProviderRegistry.inMemory();
    await _pump(tester, ProvidersSection(registry: registry));

    await _openPresetEditor(tester);
    // The race `_editPreset` guards: another flow (an SSO landing) adds an
    // entry on the same endpoint while the editor is up.
    final existing = await registry.add(
      name: 'My OR',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'acme-1',
    );
    // No key typed this time — the update keeps the stored key untouched.
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(registry.providers, hasLength(1));
    final updated = registry.providers.single;
    expect(updated.id, existing.id);
    expect(updated.name, 'OpenRouter');
    expect(updated.baseUrl, 'https://openrouter.ai/api/v1');
    expect(updated.modelId, ProviderPreset.openrouter.defaultModel);
    expect(registry.keyFor(existing.id), isNull);
  });
}
