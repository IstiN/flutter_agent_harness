// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Widget tests for the Settings provider-queue section (issue #418):
/// scope resolution display (env wins / project / user / unset), the
/// add/remove/reorder round-trips through the writer seam, and the
/// refused-write surface. The section is the app half of the queue
/// editor; the CLI half lives in `agent_cli_commands.dart`.
library;

import 'package:fa/l10n/app_localizations.dart';
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
    // Rows render, but every mutating action is disabled.
    expect(find.textContaining('openai-completions · a'), findsOneWidget);
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

  testWidgets('add appends a parser-validated entry', (tester) async {
    final writes = <List<ProviderQueueEntry>>[];
    await _pump(
      tester,
      resolve: ({projectDir, homeDir}) =>
          _res(ProviderQueueScope.project, [_entry('a')]),
      write: (entries, {required layer, projectDir, homeDir}) async {
        writes.add(entries);
        return 'x';
      },
    );
    await tester.tap(find.text('Add entry'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Provider type (e.g. openai-completions)'),
      'anthropic',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Model (e.g. moonshotai/Kimi-K2.6)'),
      'claude-x',
    );
    await tester.tap(find.text('Add').last);
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.last.providerType, 'anthropic');
    expect(writes.single.last.model, 'claude-x');
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
