// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Edge-path coverage for the details sheet: the record/request shapes the
/// happy-path tests miss — context injections, failed and pending
/// statuses, empty error results, invalid payload JSON, flat-token usage
/// fallbacks, and the running-request timing branch.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture_details.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

TrajectoryAssistantRecord _assistant({
  String? errorCode,
  String? errorMessage,
  DateTime? stepStartTime,
  DateTime? firstTokenTime,
  int? inputTokens,
  int? outputTokens,
}) => TrajectoryAssistantRecord(
  index: 1,
  recordId: 'edge/assistant',
  messageId: 'm1',
  turn: 1,
  step: 1,
  isError: errorCode != null || errorMessage != null,
  errorCode: errorCode,
  errorMessage: errorMessage,
  stepStartTime: stepStartTime,
  firstTokenTime: firstTokenTime,
  inputTokens: inputTokens,
  outputTokens: outputTokens,
);

Future<void> _open(WidgetTester tester, TrajectoryRecord record) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showTrajectoryDetails(context, record: record),
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

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetTrajectoryTabHistory);

  testWidgets('context record shows Summary, Preview, and empty Raw', (
    tester,
  ) async {
    const record = TrajectoryContextRecord(
      index: 1,
      recordId: 'edge/context',
      text: 'Working directory: ~/work/api',
      previewMarkdown: 'Working directory: ~/work/api',
    );
    await _open(tester, record);

    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    await _openTab(tester, 'Preview');
    expect(find.text('Working directory: ~/work/api'), findsOneWidget);
    await _openTab(tester, 'Raw');
    expect(find.text('No content'), findsOneWidget);
  });

  testWidgets('failed assistant shows the error row and pending timings', (
    tester,
  ) async {
    await _open(
      tester,
      _assistant(
        errorCode: 'overloaded',
        errorMessage: 'Provider overloaded',
        stepStartTime: _base,
      ),
    );

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('overloaded: Provider overloaded'), findsOneWidget);
    await _openTab(tester, 'Timing');
    expect(find.text('Pending'), findsWidgets);
    expect(find.text('Not available'), findsWidgets);
  });

  testWidgets('tool error with an empty result shows the No output state', (
    tester,
  ) async {
    const record = TrajectoryToolRecord(
      index: 2,
      recordId: 'edge/tool-empty-error',
      callId: 'c1',
      parentCallId: null,
      name: 'bash',
      argsRaw: '{}',
      isError: true,
    );
    await _open(tester, record);

    expect(find.text('Failed'), findsOneWidget);
    await _openTab(tester, 'Result');
    expect(find.text('No output'), findsOneWidget);
  });

  testWidgets('system change without detail shows the missing-prompt state', (
    tester,
  ) async {
    // System sheets have no Summary tab: [System Prompt, Tools] only.
    const record = TrajectorySystemRecord(
      index: 3,
      recordId: 'edge/system-error',
      text: 'Turn failed',
      change: TrajectorySystemChange.initial,
      errorCode: 'EPIPE',
      errorMessage: 'Broken pipe',
    );
    await _open(tester, record);

    expect(find.text('System Prompt'), findsOneWidget);
    expect(find.text('No system prompt in this request'), findsOneWidget);
    await _openTab(tester, 'Tools');
    expect(find.text('No tools in this request'), findsOneWidget);
  });

  testWidgets('interrupted compaction counts as failed', (tester) async {
    const record = TrajectoryCompactedRecord(
      index: 4,
      recordId: 'edge/compacted-interrupted',
      text: 'interrupted',
      summary: '',
      interrupted: true,
    );
    await _open(tester, record);

    expect(find.text('Failed'), findsOneWidget);
  });

  testWidgets('payload tab falls back to the raw text for invalid JSON', (
    tester,
  ) async {
    const record = TrajectoryToolRecord(
      index: 5,
      recordId: 'edge/tool-bad-json',
      callId: 'c2',
      parentCallId: null,
      name: 'bash',
      argsRaw: 'not json {',
      result: 'ok',
    );
    await _open(tester, record);
    await _openTab(tester, 'Payload');

    expect(find.text('not json {'), findsOneWidget);
  });

  testWidgets('flat token fields feed the Summary usage when usage is null', (
    tester,
  ) async {
    await _open(tester, _assistant(inputTokens: 10, outputTokens: 5));

    // The Summary ladder shows Output (and Reasoning/Content when set);
    // input only feeds _usageFromFlat's construction.
    expect(find.text('5 tok'), findsOneWidget);
    expect(find.text('Usage not reported'), findsNothing);
  });

  testWidgets('running request pends and reports live timestamps', (
    tester,
  ) async {
    final running = TrajectoryRequestNumber(
      seq: 9,
      turn: 1,
      step: 1,
      purpose: TrajectoryRequestPurpose.assistant,
      provider: 'anthropic',
      model: 'claude-test',
      status: TrajectoryRequestStatus.running,
      startedAt: _base,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showTrajectoryRequestDetails(
                  context,
                  request: running,
                  snapshot: snapshot,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _openTab(tester, 'Timing');
    expect(find.text('Session timestamps (running)'), findsOneWidget);
  });
}
