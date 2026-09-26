// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Issue #977: the app's add-provider flow must behave like the CLI's
// (`_askConnectProviderName` + `_entryForBaseUrl`): several same-type
// providers coexist under their own names, a name belonging to another
// endpoint is rejected, and a re-add of an existing endpoint updates
// instead of duplicating.
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

/// A TextField inside the full-screen provider editor page.
Finder _editorField(String label) {
  return find.descendant(
    of: find.byType(ProviderEditorPage),
    matching: find.widgetWithText(TextField, label),
  );
}

/// The editor's Save row sits below the fold inside the page's scroll
/// view — bring it on-screen or the tap misses.
Future<void> _scrollToSave(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Save'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    '(a) two same-type providers with different names coexist in the list '
    'and pickers',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'OpenRouter Work',
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'a',
      );
      await registry.add(
        name: 'OpenRouter Personal',
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'b',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      expect(find.text('OpenRouter Work'), findsOneWidget);
      expect(find.text('OpenRouter Personal'), findsOneWidget);
    },
  );

  testWidgets(
    '(b) a name already used by a DIFFERENT endpoint is rejected by the '
    'editor save',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Work',
        baseUrl: 'https://other.example.com/v1',
        modelId: 'm1',
      );
      await _pump(tester, AddProviderPresetPickerPage(registry: registry));
      // Custom is the last tile — below the fold in the test viewport.
      await tester.scrollUntilVisible(
        find.text('Custom'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      await tester.enterText(_editorField('Name'), 'Work');
      await tester.enterText(
        _editorField('Base URL'),
        'https://mine.example.com/v1',
      );
      await tester.enterText(_editorField('API key (optional)'), 'k-mine');
      await _scrollToSave(tester);
      await tester.tap(find.text('Save'));
      await tester.pump();

      // The CLI's `_askConnectProviderName` contract, surfaced inline: the
      // clash names the endpoint that owns the name, and the editor stays
      // up with nothing saved.
      expect(
        find.textContaining(
          'already used by a provider on https://other.example.com/v1',
        ),
        findsOneWidget,
      );
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      expect(registry.providers, hasLength(1));

      // A usable name lands.
      await tester.enterText(_editorField('Name'), 'Mine');
      await _scrollToSave(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final mine = registry.byName('Mine');
      expect(mine?.baseUrl, 'https://mine.example.com/v1');
      expect(registry.keyFor(mine!.id), 'k-mine');
    },
  );

  testWidgets(
    '(c) reconnect-by-URL updates instead of duplicating: the same name '
    'and endpoint lands as an update (id kept, key refreshed)',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      final first = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'old-model',
      );
      registry.rememberKey(first.id, 'stale');
      await _pump(tester, AddProviderPresetPickerPage(registry: registry));
      // Custom is the last tile — below the fold in the test viewport.
      await tester.scrollUntilVisible(
        find.text('Custom'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      await tester.enterText(_editorField('Name'), 'Acme');
      await tester.enterText(
        _editorField('Base URL'),
        'https://acme.example/v1',
      );
      await tester.enterText(_editorField('API key (optional)'), 'k-new');
      await _scrollToSave(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // The landing ran: still ONE entry, SAME id, key refreshed on it —
      // and the model the editor left empty was preserved, not wiped.
      expect(registry.providers, hasLength(1));
      expect(registry.providers.single.id, first.id);
      expect(registry.providers.single.name, 'Acme');
      expect(registry.providers.single.modelId, 'old-model');
      expect(registry.keyFor(first.id), 'k-new');
    },
  );

  testWidgets('a renamed entry re-adds through its endpoint: the preset editor '
      'prefills the existing entry name (the `_entryForBaseUrl` contract)', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    final renamed = await registry.add(
      name: 'Renamed Router',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'm1',
    );
    await _pump(tester, AddProviderPresetPickerPage(registry: registry));
    await tester.tap(find.text('OpenRouter'));
    await tester.pumpAndSettle();

    // The editor prefill carries the RENAMED entry, not the preset label.
    expect(
      tester.widget<TextField>(_editorField('Name')).controller!.text,
      'Renamed Router',
    );
    await tester.enterText(_editorField('API key (optional)'), 'rk-1');
    await _scrollToSave(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The re-add landed on the existing entry — no duplicate, key lands
    // on the SAME id (the landing provably ran).
    expect(registry.providers, hasLength(1));
    expect(registry.providers.single.id, renamed.id);
    expect(registry.providers.single.name, 'Renamed Router');
    expect(registry.keyFor(renamed.id), 'rk-1');
  });

  testWidgets(
    '(round-1 T1) EDIT mode rejects renaming onto a sibling name on the '
    'SAME endpoint — create-only is the same-endpoint takeover',
    (tester) async {
      final registry = ProviderRegistry.inMemory();
      final work = await registry.add(
        name: 'OpenRouter Work',
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'a',
      );
      final personal = await registry.add(
        name: 'OpenRouter Personal',
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'b',
      );
      await _pump(tester, ProvidersSection(registry: registry));

      // Edit the Personal entry through its section row.
      await tester.tap(find.text('OpenRouter Personal'));
      await tester.pumpAndSettle();

      // Rename it onto the Work entry's name — rejected inline, nothing
      // saved: two same-name entries would break every by-name landing.
      await tester.enterText(_editorField('Name'), 'OpenRouter Work');
      await _scrollToSave(tester);
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(
        find.textContaining(
          'already used by a provider on https://openrouter.ai/api/v1',
        ),
        findsOneWidget,
      );
      expect(find.byType(ProviderEditorPage), findsOneWidget);
      expect(registry.providers, hasLength(2));
      expect(registry.byName('OpenRouter Work')!.id, work.id);
      expect(registry.byName('OpenRouter Personal')!.id, personal.id);
    },
  );
}
