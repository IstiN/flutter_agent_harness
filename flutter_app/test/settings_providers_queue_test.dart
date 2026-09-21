// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Widget tests for the Settings provider-queue section (issue #418,
/// picker flow #693): scope resolution display (env wins / project / user
/// / unset), the add/edit round-trips through the shared two-step
/// provider→model picker and the writer seam, and the refused-write
/// surface. The section is the app half of the queue editor; the CLI half
/// lives in `agent_cli_commands.dart`.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/media_slot_picker_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderQueueEntry _entry(String model, {String kind = 'openai-completions'}) =>
    ProviderQueueEntry(providerType: kind, model: model, apiKeyEnv: 'K_$model');

ProviderQueueResolution _res(
  ProviderQueueScope? scope,
  List<ProviderQueueEntry> entries,
) => ProviderQueueResolution(
  scope: scope ?? ProviderQueueScope.user,
  entries: entries,
  notices: const [],
);

/// A `/models` fetch returning a fixed list (no network).
Future<ModelsEndpointInfo> _someModels(
  String baseUrl, {
  required String apiKey,
}) async => (const ['m-1', 'm-2'], const <String, int>{}, const <String, int>{});

/// Drives the two-step flow opened by [open]: provider list → model list →
/// Save with [model].
Future<void> _pickModel(
  WidgetTester tester,
  WidgetTesterCallback open, {
  required String provider,
  required String model,
}) async {
  await open(tester);
  await tester.pumpAndSettle();
  expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
  await tester.tap(find.text(provider));
  await tester.pumpAndSettle();
  expect(find.byType(MediaSlotModelPage), findsOneWidget);
  await tester.enterText(
    find.widgetWithText(TextField, 'Model id'),
    model,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Save'));
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester, {
  required ProviderQueueResolution Function({
    String? projectDir,
    String? homeDir,
  })?
  resolve,
  Future<String> Function(
    List<ProviderQueueEntry> entries, {
    required ProviderQueueScope layer,
    String? projectDir,
    String? homeDir,
  })?
  write,
  bool supported = true,
  String? projectDir = '/tmp/proj',
  ProviderRegistry? registry,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ProviderQueueSection(
          projectDir: projectDir,
          resolve: resolve,
          write: write,
          supported: supported,
          registry: registry,
          modelsFetcher: _someModels,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unset queue renders the empty note and the add button', (
    tester,
  ) async {
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) => _res(null, const []),
    );
    expect(find.textContaining('No provider queue'), findsOneWidget);
    expect(find.text('Add entry'), findsOneWidget);
  });

  testWidgets('env-wins queue renders read-only with the env caption', (
    tester,
  ) async {
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) =>
          _res(ProviderQueueScope.env, [_entry('a'), _entry('b')]),
    );
    expect(find.textContaining('FA_PROVIDERS_QUEUE'), findsOneWidget);
    // Rows render (model over the provider summary), but every mutating
    // action is disabled.
    expect(find.text('a'), findsOneWidget);
    expect(find.text('openai-completions · \$K_a'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNWidgets(2));
    final remove = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.delete_outline).first,
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(remove.onPressed, isNull);
    expect(find.text('Add entry'), findsNothing);
  });

  testWidgets('remove drops the entry and persists through the seam', (
    tester,
  ) async {
    final writes = <List<ProviderQueueEntry>>[];
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) =>
          _res(ProviderQueueScope.project, [_entry('a'), _entry('b')]),
      write: (entries, {required layer, projectDir, homeDir}) async {
        writes.add(entries);
        return '/tmp/proj/.fah/config.yaml';
      },
    );
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.map((e) => e.model), ['b']);
  });

  testWidgets('move up swaps the entry with its predecessor', (tester) async {
    final writes = <List<ProviderQueueEntry>>[];
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) =>
          _res(ProviderQueueScope.project, [_entry('a'), _entry('b')]),
      write: (entries, {required layer, projectDir, homeDir}) async {
        writes.add(entries);
        return 'x';
      },
    );
    await tester.tap(find.byTooltip('Move up').last);
    await tester.pumpAndSettle();
    expect(writes.single.map((e) => e.model), ['b', 'a']);
  });

  testWidgets('add runs the two-step provider→model picker and appends', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'acme-1',
    );
    final writes = <List<ProviderQueueEntry>>[];
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) => _res(null, const []),
      write: (entries, {required layer, projectDir, homeDir}) async {
        writes.add(entries);
        return 'x';
      },
      registry: registry,
    );
    await _pickModel(
      tester,
      (tester) async => tester.tap(find.text('Add entry')),
      provider: 'Acme',
      model: 'claude-x',
    );
    expect(writes, hasLength(1));
    final added = writes.single.single;
    expect(added.providerType, 'openai-completions');
    expect(added.model, 'claude-x');
    expect(added.baseUrl, 'https://acme.example/v1');
    // The key indirection is the registry's host-scoped NAME (never a
    // value) — the same name the queue boot resolves.
    expect(added.apiKeyEnv, ProviderRegistry.keyNameFor(registry.providers
        .single.baseUrl));
  });

  testWidgets('tapping a row re-picks its provider/model in place', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'acme-1',
    );
    final writes = <List<ProviderQueueEntry>>[];
    // A stateful fake: resolve mirrors the last write, like the real
    // config file does — the section reloads after every save.
    final stored = <ProviderQueueEntry>[
      _entry('a'),
      ProviderQueueEntry(
        providerType: 'openai-completions',
        model: 'acme-1',
        baseUrl: 'https://acme.example/v1',
        apiKeyEnv: ProviderRegistry.keyNameFor('https://acme.example/v1'),
        contextWindow: 123456,
      ),
    ];
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) => ProviderQueueResolution(
        scope: ProviderQueueScope.project,
        entries: List.of(stored),
        notices: const [],
      ),
      write: (entries, {required layer, projectDir, homeDir}) async {
        stored
          ..clear()
          ..addAll(entries);
        writes.add(entries);
        return 'x';
      },
      registry: registry,
    );
    await _pickModel(
      tester,
      (tester) async => tester.tap(find.text('acme-1')),
      provider: 'Acme',
      model: 'acme-2',
    );
    expect(writes, hasLength(1));
    expect(writes.single, hasLength(2));
    final edited = writes.single[1];
    expect(edited.model, 'acme-2');
    expect(edited.baseUrl, 'https://acme.example/v1');
    // Overrides the picker does not touch ride along.
    expect(edited.contextWindow, 123456);
    // The row shows the new value.
    expect(find.text('acme-2'), findsOneWidget);
  });

  testWidgets('backing out of the picker writes nothing', (tester) async {
    final writes = <List<ProviderQueueEntry>>[];
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) => _res(null, const []),
      write: (entries, {required layer, projectDir, homeDir}) async {
        writes.add(entries);
        return 'x';
      },
      registry: ProviderRegistry.inMemory(),
    );
    await tester.tap(find.text('Add entry'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
  });

  testWidgets('a refused write surfaces the error verbatim', (tester) async {
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) =>
          _res(ProviderQueueScope.project, [_entry('a')]),
      write: (entries, {required layer, projectDir, homeDir}) =>
          throw StateError('env wins'),
    );
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('env wins'), findsOneWidget);
  });

  testWidgets('unsupported platforms show the web note only', (tester) async {
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) => _res(null, const []),
      supported: false,
    );
    expect(find.textContaining('Not configurable on the web'), findsOneWidget);
    expect(find.text('Add entry'), findsNothing);
  });
}
