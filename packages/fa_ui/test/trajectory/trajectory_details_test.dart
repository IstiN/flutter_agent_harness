// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/src/trajectory/trajectory_details.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture_details.dart';

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext) opener,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => opener(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openRecord(
  WidgetTester tester,
  TrajectoryRecord record, [
  TrajectorySnapshot? snapshot,
]) => _open(
  tester,
  (context) =>
      showTrajectoryDetails(context, record: record, snapshot: snapshot),
);

int _selectedTabIndex(WidgetTester tester) =>
    DefaultTabController.of(tester.element(find.byType(TabBar))).index;

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetTrajectoryTabHistory);

  testWidgets('message record opens Summary, Diff, Preview, Raw, Timing', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);

    for (final label in ['Summary', 'Diff', 'Preview', 'Raw', 'Timing']) {
      expect(find.text(label), findsOneWidget);
    }
    // Default tab is Summary.
    expect(_selectedTabIndex(tester), 0);
  });

  testWidgets('message Summary shows status, provider, tokens, hierarchy', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);

    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('anthropic'), findsOneWidget);
    expect(find.text('claude-test'), findsOneWidget);
    expect(find.text('Request #3'), findsOneWidget);
    // Output / Reasoning / Content = output - reasoning.
    expect(find.text('50 tok'), findsOneWidget);
    expect(find.text('20 tok'), findsOneWidget);
    expect(find.text('30 tok'), findsOneWidget);
  });

  testWidgets('message Timing shows the assistant metric ladder', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Timing');

    expect(find.text('Total duration'), findsOneWidget);
    // completed - stepStart = 2500 ms.
    expect(find.text('2,500'), findsOneWidget);
    // TTFT = 300 ms.
    expect(find.text('300'), findsOneWidget);
    // Generation = 2200 ms.
    expect(find.text('2,200'), findsOneWidget);
    // Throughput = 50 tokens / 2.2 s.
    expect(find.text('22.7 tok/s'), findsOneWidget);
  });

  testWidgets('message Diff marks removed and added lines', (tester) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Diff');

    expect(find.text('- line6'), findsOneWidget);
    expect(find.text('+ old tail'), findsOneWidget);
  });

  testWidgets('assistant without output shows the No output empty state', (
    tester,
  ) async {
    await _openRecord(tester, emptyAssistant);
    await _openTab(tester, 'Preview');

    expect(find.text('No output'), findsOneWidget);
  });

  testWidgets('system record shows System Prompt and Tools tabs', (
    tester,
  ) async {
    await _openRecord(tester, systemPrompt);

    expect(find.text('System Prompt'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('You are a helpful agent.'), findsOneWidget);
    await _openTab(tester, 'Tools');
    expect(find.text('No tools in this request'), findsOneWidget);
  });

  testWidgets('compacted record shows Summary and Raw Output', (tester) async {
    await _openRecord(tester, compacted);

    expect(find.text('Raw Output'), findsOneWidget);
    await _openTab(tester, 'Raw Output');
    expect(find.text('Full compaction summary.'), findsOneWidget);
  });

  testWidgets('user record renders markdown preview and raw fallback', (
    tester,
  ) async {
    await _openRecord(tester, userPrompt);

    await _openTab(tester, 'Preview');
    expect(find.text('carefully'), findsOneWidget);
    await _openTab(tester, 'Raw');
    expect(find.text('No content'), findsOneWidget);
  });

  testWidgets('settled tool shows payload JSON and result', (tester) async {
    await _openRecord(tester, settledTool);

    expect(find.text('Payload'), findsOneWidget);
    expect(find.text('Result'), findsOneWidget);
    expect(find.text('Schema'), findsOneWidget);
    expect(find.text('Timing'), findsOneWidget);

    await _openTab(tester, 'Payload');
    expect(find.textContaining('"cmd": "deploy"'), findsOneWidget);
    await _openTab(tester, 'Result');
    expect(find.text('deployed'), findsOneWidget);
  });

  testWidgets('settled tool Timing uses generic rows', (tester) async {
    await _openRecord(tester, settledTool);
    await _openTab(tester, 'Timing');

    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('1,200'), findsOneWidget);
    expect(find.text('Session timestamps'), findsOneWidget);
  });

  testWidgets('schema tab parses the captured schema JSON', (tester) async {
    await _openRecord(tester, settledTool, snapshot);
    await _openTab(tester, 'Schema');

    expect(find.text('Run a shell command'), findsOneWidget);
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.textContaining('"cmd"'), findsOneWidget);
  });

  testWidgets('schema tab shows the unavailable empty state', (tester) async {
    await _openRecord(tester, settledTool);
    await _openTab(tester, 'Schema');

    expect(find.text('Schema unavailable'), findsOneWidget);
  });

  testWidgets('failed tool is Failed with its error as result', (tester) async {
    await _openRecord(tester, failedTool);

    expect(find.text('Failed'), findsOneWidget);
    await _openTab(tester, 'Result');
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('running tool has no Result tab and pends', (tester) async {
    await _openRecord(tester, runningTool);

    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Result'), findsNothing);
    await _openTab(tester, 'Timing');
    expect(find.text('Not available'), findsOneWidget);
  });

  testWidgets('request opens Summary, Usage, Timing with its number', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showTrajectoryRequestDetails(
        context,
        request: request,
        snapshot: snapshot,
      ),
    );

    expect(find.text('Request #3'), findsOneWidget);
    for (final label in ['Summary', 'Usage', 'Timing']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Completed'), findsOneWidget);

    await _openTab(tester, 'Usage');
    // This request: input total 10 = 10 + 0 + 0.
    expect(find.text('10 tok'), findsWidgets);
    expect(find.text('0 tok'), findsWidgets);
    expect(find.text('5 tok'), findsOneWidget);
    // Session cumulative: input total 150 = 100 + 40 + 10; content 30 = 50 - 20.
    expect(find.text('150 tok'), findsOneWidget);
    expect(find.text('40 tok'), findsOneWidget);
    expect(find.text('30 tok'), findsOneWidget);
    expect(find.text('This request'), findsOneWidget);
    expect(find.text('Session cumulative'), findsOneWidget);

    await _openTab(tester, 'Timing');
    expect(find.text('500'), findsOneWidget);
    expect(find.text('Session timestamps'), findsOneWidget);
  });

  testWidgets('raw tab lists source blocks and tool-call chips', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Raw');

    expect(find.text('Block #1 text'), findsOneWidget);
    expect(find.text('Block #2 thinking'), findsOneWidget);
    expect(find.text('Block #3 toolCall'), findsOneWidget);
    expect(find.byType(Chip), findsOneWidget);
  });

  testWidgets('reopening a record restores the last visited tab', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Raw');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    await _openRecord(tester, richAssistant, snapshot);
    expect(_selectedTabIndex(tester), 3);
  });

  testWidgets('tab history falls back to the first unavailable tab', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Raw');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // The tool record has no Raw tab — open on Summary instead.
    await _openRecord(tester, settledTool);
    expect(_selectedTabIndex(tester), 0);
  });
}
