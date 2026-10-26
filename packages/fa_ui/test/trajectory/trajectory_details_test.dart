// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:collection';

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

  testWidgets('gh-1745: a spilled request names its blob; the stub '
      'messages carry no dangling colon', (tester) async {
    _mockClipboard();
    await _openRecord(tester, spilledAssistant);

    await _openTab(tester, 'Request');
    // The spill pointer is surfaced — the same blob `/trajectory inspect`
    // names on the CLI side (review: the app host spilled but its UI
    // could not reach the blob).
    expect(find.text('Request blob'), findsOneWidget);
    expect(
      find.textContaining('.fah/trajectories/s1/requests/1.json'),
      findsOneWidget,
    );
    // The copy text keeps the role+chars stubs, without a dangling `: `
    // (the preview lives in the blob, not this record).
    await _copy(tester);
    expect(_clipboardText, contains('user · 9 chars'));
    expect(_clipboardText, contains('assistant · 30 chars'));
    expect(_clipboardText, isNot(contains('chars: ')));
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

  group('prompt diff lines', () {
    List<(TrajectoryPromptDiffLineKind, String)> kindsOf(
      List<TrajectoryPromptDiffLine> lines,
    ) => [for (final line in lines) (line.kind, line.text)];

    test('identical texts diff to nothing', () {
      expect(trajectoryPromptDiffLines('a\nb', 'a\nb'), isEmpty);
    });

    test('short edits render removed and added without context', () {
      expect(kindsOf(trajectoryPromptDiffLines('old', 'new')), [
        (TrajectoryPromptDiffLineKind.removed, '- old'),
        (TrajectoryPromptDiffLineKind.added, '+ new'),
      ]);
    });

    test('a long common suffix collapses behind an ellipsis', () {
      expect(
        kindsOf(
          trajectoryPromptDiffLines('x\nb\nc\nd\ne\nf', 'y\nb\nc\nd\ne\nf'),
        ),
        [
          (TrajectoryPromptDiffLineKind.removed, '- x'),
          (TrajectoryPromptDiffLineKind.added, '+ y'),
          (TrajectoryPromptDiffLineKind.ellipsis, '⋯'),
          (TrajectoryPromptDiffLineKind.context, 'b'),
          (TrajectoryPromptDiffLineKind.context, 'c'),
          (TrajectoryPromptDiffLineKind.context, 'd'),
        ],
      );
    });
  });

  group('status ladder', () {
    testWidgets('failed assistant reports the code and message', (
      tester,
    ) async {
      await _openRecord(
        tester,
        TrajectoryAssistantRecord(
          index: 20,
          recordId: 'details/assistant-failed',
          messageId: 'mf1',
          turn: 4,
          step: 1,
          provider: 'anthropic',
          model: 'claude-test',
          isError: true,
          errorCode: 'RATE',
          errorMessage: 'slow down',
        ),
      );
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('RATE: slow down'), findsOneWidget);
    });

    testWidgets('an AUTH failure renders the localized auth statement', (
      tester,
    ) async {
      await _openRecord(
        tester,
        TrajectoryAssistantRecord(
          index: 21,
          recordId: 'details/assistant-auth',
          messageId: 'mf2',
          turn: 4,
          step: 2,
          isError: true,
          errorCode: 'AUTH',
          errorMessage: 'ignored',
        ),
      );
      expect(find.text('API key is invalid'), findsOneWidget);
    });

    testWidgets('a started-but-unfinished step is Pending', (tester) async {
      await _openRecord(
        tester,
        TrajectoryAssistantRecord(
          index: 22,
          recordId: 'details/assistant-running',
          messageId: 'mr1',
          turn: 5,
          step: 1,
          stepStartTime: DateTime.utc(2026, 1, 1, 12),
          isError: false,
        ),
      );
      expect(find.text('Pending'), findsOneWidget);
    });

    testWidgets('flat token counts render the usage rows without usage', (
      tester,
    ) async {
      await _openRecord(
        tester,
        const TrajectoryAssistantRecord(
          index: 23,
          recordId: 'details/assistant-flat',
          messageId: 'mu1',
          turn: 6,
          step: 1,
          isError: false,
          inputTokens: 100,
          outputTokens: 40,
          cacheReadTokens: 10,
          cacheWriteTokens: 5,
        ),
      );
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('40 tok'), findsOneWidget);
      // No reasoning tokens — the split rows stay hidden.
      expect(find.text('Reasoning'), findsNothing);
    });

    testWidgets('interrupted compaction is Failed', (tester) async {
      await _openRecord(
        tester,
        const TrajectoryCompactedRecord(
          index: 24,
          recordId: 'details/compacted-interrupted',
          text: 'preview',
          summary: 'Cut short.',
          interrupted: true,
        ),
      );
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('compaction without a duration is Pending', (tester) async {
      await _openRecord(
        tester,
        const TrajectoryCompactedRecord(
          index: 25,
          recordId: 'details/compacted-running',
          text: 'preview',
          summary: 'Still going.',
        ),
      );
      expect(find.text('Pending'), findsOneWidget);
    });
  });

  group('captured blobs', () {
    final blobSnapshot = TrajectorySnapshot(
      records: UnmodifiableListView(const []),
      requests: UnmodifiableListView(const []),
      callSchemas: const {},
      partial: null,
      runningCalls: UnmodifiableListView(const []),
      recordLocations: const {},
      blobs: const TrajectoryBlobTable(
        systemPrompts: {
          'p1': TrajectoryPromptBlob(hash: 'p1', text: 'old prompt'),
          'p2': TrajectoryPromptBlob(hash: 'p2', text: 'new prompt'),
        },
        toolManifests: {
          'm1': TrajectoryToolManifestBlob(
            hash: 'm1',
            tools: [
              TrajectoryToolManifestEntry(
                name: 'bash',
                description: 'Run shell commands',
                schemaJson: '{\n  "type": "object"\n}',
                schemaChars: 22,
                schemaTruncated: false,
              ),
              TrajectoryToolManifestEntry(
                name: 'bare',
                description: '',
                schemaJson: '',
                schemaChars: 0,
                schemaTruncated: false,
              ),
            ],
          ),
          'm2': TrajectoryToolManifestBlob(
            hash: 'm2',
            tools: [
              TrajectoryToolManifestEntry(
                name: 'bash',
                description: 'Run shell commands',
                schemaJson: '{\n  "type": "object"\n}',
                schemaChars: 22,
                schemaTruncated: false,
              ),
              TrajectoryToolManifestEntry(
                name: 'read',
                description: 'Read a file',
                schemaJson: '{\n  "type": "object"\n}',
                schemaChars: 22,
                schemaTruncated: false,
              ),
            ],
          ),
        },
      ),
      revision: 1,
    );

    TrajectorySystemRecord systemWith({
      required String recordId,
      String? promptHash,
      String? previousPromptHash,
      String? manifestHash,
      String? previousManifestHash,
    }) => TrajectorySystemRecord(
      index: 30,
      recordId: recordId,
      text: 'System',
      change: TrajectorySystemChange.toolsChange,
      systemPromptHash: promptHash,
      previousSystemPromptHash: previousPromptHash,
      toolManifestHash: manifestHash,
      previousToolManifestHash: previousManifestHash,
    );

    testWidgets('tools tab renders the manifest with a changed-count head', (
      tester,
    ) async {
      await _openRecord(
        tester,
        systemWith(
          recordId: 'details/system-manifest-changed',
          manifestHash: 'm2',
          previousManifestHash: 'm1',
        ),
        blobSnapshot,
      );
      await _openTab(tester, 'Tools');

      expect(
        find.text('Changed vs previous version: +1 −1 tools'),
        findsOneWidget,
      );
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('Run shell commands'), findsOneWidget);
      expect(find.text('read'), findsOneWidget);
      // Schema sections render only for tools carrying one.
      expect(find.text('Parameters'), findsNWidgets(2));
      expect(find.textContaining('"type"'), findsNWidgets(2));
    });

    testWidgets('tools tab skips the head without a previous version', (
      tester,
    ) async {
      await _openRecord(
        tester,
        systemWith(
          recordId: 'details/system-manifest-first',
          manifestHash: 'm1',
        ),
        blobSnapshot,
      );
      await _openTab(tester, 'Tools');

      expect(find.textContaining('Changed vs previous'), findsNothing);
      expect(find.text('bash'), findsOneWidget);
      // The bare tool renders its name only — no empty stubs.
      expect(find.text('bare'), findsOneWidget);
      expect(find.text('Parameters'), findsOneWidget);
    });

    testWidgets('tools tab skips the head for an identical manifest', (
      tester,
    ) async {
      await _openRecord(
        tester,
        systemWith(
          recordId: 'details/system-manifest-same',
          manifestHash: 'm1',
          previousManifestHash: 'm1',
        ),
        blobSnapshot,
      );
      await _openTab(tester, 'Tools');

      expect(find.textContaining('Changed vs previous'), findsNothing);
    });

    testWidgets('system prompt tab diffs two captured versions', (
      tester,
    ) async {
      await _openRecord(
        tester,
        systemWith(
          recordId: 'details/system-prompt-diff',
          promptHash: 'p2',
          previousPromptHash: 'p1',
        ),
        blobSnapshot,
      );
      await _openTab(tester, 'System Prompt');

      expect(find.text('- old prompt'), findsOneWidget);
      expect(find.text('+ new prompt'), findsOneWidget);
    });

    testWidgets('system prompt tab renders a lone captured version', (
      tester,
    ) async {
      await _openRecord(
        tester,
        systemWith(recordId: 'details/system-prompt-blob', promptHash: 'p2'),
        blobSnapshot,
      );
      await _openTab(tester, 'System Prompt');

      expect(find.text('new prompt'), findsOneWidget);
    });
  });

  testWidgets('hidden-range drill-in resolves covered records', (tester) async {
    await _open(
      tester,
      (context) => showTrajectoryDetails(
        context,
        record: const TrajectoryCompactedRecord(
          index: 26,
          recordId: 'details/compacted-hidden',
          text: 'preview',
          summary: 'Compacted.',
          hiddenRecordIds: ['h1', 'h2'],
        ),
        resolveHiddenRecords: (record) async => const [
          TrajectoryHiddenRecordPreview(
            id: 'h1',
            type: 'message',
            preview: 'hidden text one',
          ),
        ],
      ),
    );
    await _openTab(tester, 'Hidden Records');
    await tester.pumpAndSettle();

    expect(find.text('1 hidden records'), findsOneWidget);
    expect(find.text('message · h1'), findsOneWidget);
    expect(find.text('hidden text one'), findsOneWidget);
  });
}
