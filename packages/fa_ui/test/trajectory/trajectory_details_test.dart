// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/src/trajectory/trajectory_details.dart';
import 'package:fa_ui/src/trajectory/trajectory_details_tabs.dart';
import 'package:fa_ui/src/trajectory/trajectory_strings.dart';
import 'package:flutter/services.dart';
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

List<String> _tabIds(TrajectoryRecord record, [TrajectorySnapshot? snapshot]) =>
    [
      for (final tab in trajectoryDetailTabs(
        record,
        snapshot,
        const TrajectoryStringsEn(),
      ))
        tab.id,
    ];

String? _clipboardText;

/// Captures Clipboard.setData payloads so copy buttons can be asserted.
void _mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          _clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
}

Future<void> _copy(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.copy));
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetTrajectoryTabHistory);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    _clipboardText = null;
  });

  group('tab truth table', () {
    test('assistant with full data shows every tab in order', () {
      expect(_tabIds(richAssistant, snapshot), [
        'summary',
        'request',
        'diff',
        'preview',
        'raw',
        'timing',
      ]);
    });

    test('assistant without request, diff, or timing data hides them', () {
      expect(_tabIds(emptyAssistant), ['summary', 'preview', 'raw']);
    });

    test('settled tool with snapshot shows schema', () {
      expect(_tabIds(settledTool, snapshot), [
        'summary',
        'payload',
        'result',
        'schema',
        'timing',
      ]);
    });

    test('settled tool without snapshot hides schema', () {
      expect(_tabIds(settledTool), ['summary', 'payload', 'result', 'timing']);
    });

    test('running tool keeps result, hides schema and timing', () {
      expect(_tabIds(runningTool), ['summary', 'payload', 'result']);
    });

    test('failed tool keeps result and timing', () {
      expect(_tabIds(failedTool), ['summary', 'payload', 'result', 'timing']);
    });

    test('system keeps explicit prompt and tools statements', () {
      expect(_tabIds(systemPrompt), ['system-prompt', 'tools']);
    });

    test('compacted hides Raw Output when the summary is empty', () {
      expect(_tabIds(compacted), ['summary', 'raw']);
      expect(
        _tabIds(
          const TrajectoryCompactedRecord(
            index: 99,
            recordId: 'details/compacted-empty',
            text: 'preview',
            summary: '',
          ),
        ),
        ['summary'],
      );
    });

    test('user/context hide Preview when there is no text', () {
      expect(_tabIds(userPrompt), ['summary', 'preview', 'raw']);
      expect(
        _tabIds(
          const TrajectoryContextRecord(
            index: 98,
            recordId: 'details/context-empty',
            text: '',
          ),
        ),
        ['summary', 'raw'],
      );
    });
  });

  testWidgets('message record opens Summary, Request, Diff, Preview, Raw, '
      'Timing', (tester) async {
    await _openRecord(tester, richAssistant, snapshot);

    for (final label in [
      'Summary',
      'Request',
      'Diff',
      'Preview',
      'Raw',
      'Timing',
    ]) {
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

  testWidgets('Request tab shows counts, tools, and per-message summaries', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Request');

    expect(find.text('3'), findsOneWidget);
    expect(find.text('40 chars'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('user · 42 chars'), findsOneWidget);
    expect(find.text('Run the deployment'), findsOneWidget);
    expect(find.text('toolResult · 8 chars'), findsOneWidget);
  });

  testWidgets('assistant without output shows the empty-response state', (
    tester,
  ) async {
    await _openRecord(tester, emptyAssistant);
    await _openTab(tester, 'Preview');

    expect(find.text('Empty response'), findsOneWidget);
    expect(find.text('Not recorded'), findsOneWidget);
    // No timestamps recorded — the Timing tab is hidden.
    expect(find.text('Timing'), findsNothing);
  });

  testWidgets('empty assistant with a tool call reports Tool use', (
    tester,
  ) async {
    const record = TrajectoryAssistantRecord(
      index: 12,
      recordId: 'details/assistant-toolcall',
      messageId: 'm3',
      turn: 2,
      step: 1,
      isError: false,
      sourceBlocks: [
        TrajectorySourceBlock(
          type: 'toolCall',
          content: '',
          callId: 'call9',
          toolName: 'bash',
        ),
      ],
    );
    await _openRecord(tester, record);
    await _openTab(tester, 'Preview');

    expect(find.text('Empty response'), findsOneWidget);
    expect(find.text('Tool use'), findsOneWidget);
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

  testWidgets('user record renders markdown preview and raw record JSON', (
    tester,
  ) async {
    await _openRecord(tester, userPrompt);

    await _openTab(tester, 'Preview');
    expect(find.text('carefully'), findsOneWidget);
    await _openTab(tester, 'Raw');
    expect(find.textContaining('"kind": "user"'), findsOneWidget);
  });

  testWidgets('settled tool shows payload JSON and result', (tester) async {
    await _openRecord(tester, settledTool, snapshot);

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

  testWidgets('schema tab is hidden when no schema was captured', (
    tester,
  ) async {
    await _openRecord(tester, settledTool);

    expect(find.text('Schema'), findsNothing);
  });

  testWidgets('failed tool is Failed with its error as result', (tester) async {
    await _openRecord(tester, failedTool);

    expect(find.text('Failed'), findsOneWidget);
    await _openTab(tester, 'Result');
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('running tool keeps its Result tab with an in-progress state', (
    tester,
  ) async {
    await _openRecord(tester, runningTool);

    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Result'), findsOneWidget);
    expect(find.text('Schema'), findsNothing);
    expect(find.text('Timing'), findsNothing);
    await _openTab(tester, 'Result');
    expect(find.text('Result pending'), findsOneWidget);
    // Nothing recorded yet — no copy affordance.
    expect(find.byIcon(Icons.copy), findsNothing);
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

  testWidgets('raw tab shows the full record JSON', (tester) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Raw');

    expect(find.textContaining('"kind": "message"'), findsOneWidget);
    expect(find.textContaining('"toolCall"'), findsOneWidget);
    expect(find.textContaining('"requestDetail"'), findsOneWidget);
  });

  testWidgets('copy buttons place assistant payloads on the clipboard', (
    tester,
  ) async {
    _mockClipboard();
    await _openRecord(tester, richAssistant, snapshot);

    await _openTab(tester, 'Preview');
    await _copy(tester);
    expect(_clipboardText, '## Deploy plan\n\nAll good');

    await _openTab(tester, 'Request');
    await _copy(tester);
    expect(_clipboardText, contains('Messages: 3'));
    expect(_clipboardText, contains('System prompt: 40 chars'));
    expect(_clipboardText, contains('Tools: 1 (bash)'));
    expect(_clipboardText, contains('user · 42 chars: Run the deployment'));

    await _openTab(tester, 'Raw');
    await _copy(tester);
    expect(_clipboardText, contains('"kind": "message"'));
    expect(_clipboardText, contains('"recordId": "details/assistant"'));
  });

  testWidgets('copy buttons place tool payloads on the clipboard', (
    tester,
  ) async {
    _mockClipboard();
    await _openRecord(tester, settledTool);

    await _openTab(tester, 'Payload');
    await _copy(tester);
    expect(_clipboardText, '{"cmd":"deploy"}');

    await _openTab(tester, 'Result');
    await _copy(tester);
    expect(_clipboardText, 'deployed');
  });

  testWidgets('reopening a record restores the last visited tab', (
    tester,
  ) async {
    await _openRecord(tester, richAssistant, snapshot);
    await _openTab(tester, 'Raw');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    await _openRecord(tester, richAssistant, snapshot);
    expect(_selectedTabIndex(tester), 4);
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
