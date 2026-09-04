// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the trajectory ledger's two adaptive layouts,
/// driven through the real [openTrajectoryPanel] over a pre-populated
/// [FakeChatService] feed (no loading spinner): wide canvases open the
/// centered dialog page, narrow ones the full-height bottom sheet.
/// Settled with fixed-duration pumps — never `pumpAndSettle`, which can
/// never settle while route animations and the controller's debounce
/// timers interleave. See `golden_test_setup.dart` for the font and
/// determinism conventions.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_chat_service.dart';
import 'golden_test_setup.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

/// A realistic two-turn session (prompt → tool call → result → reply),
/// appended into [feed] before the panel subscribes.
void _populate(TrajectoryServiceFeed feed) {
  AssistantMessage assistant(String text, DateTime at) => AssistantMessage(
    content: [TextContent(text: text)],
    api: 'anthropic-messages',
    provider: 'anthropic',
    model: 'claude-opus-4-6',
    usage: const Usage(
      input: 1832,
      output: 96,
      cacheRead: 4096,
      cacheWrite: 0,
      reasoning: 0,
      totalTokens: 1928,
      cost: UsageCost(),
    ),
    stopReason: StopReason.stop,
    timestamp: at,
  );

  feed
    ..append(
      MessageRecord(
        id: 'u1',
        parentId: null,
        timestamp: _base,
        message: UserMessage.text('Run the deployment'),
      ),
    )
    ..append(
      MessageRecord(
        id: 'a1',
        parentId: 'u1',
        timestamp: _base.add(const Duration(seconds: 1)),
        message: AssistantMessage(
          content: [
            const TextContent(text: 'Deploying now'),
            const ToolCall(
              id: 'call1',
              name: 'bash',
              arguments: {'cmd': 'deploy'},
            ),
          ],
          api: 'anthropic-messages',
          provider: 'anthropic',
          model: 'claude-opus-4-6',
          usage: const Usage(
            input: 1832,
            output: 20,
            cacheRead: 4096,
            cacheWrite: 0,
            reasoning: 0,
            totalTokens: 1852,
            cost: UsageCost(),
          ),
          stopReason: StopReason.toolUse,
          timestamp: _base.add(const Duration(seconds: 1)),
        ),
      ),
    )
    ..append(
      MessageRecord(
        id: 'r1',
        parentId: 'a1',
        timestamp: _base.add(const Duration(seconds: 2)),
        message: ToolResultMessage(
          toolCallId: 'call1',
          toolName: 'bash',
          content: [const TextContent(text: 'deployed')],
          isError: false,
          timestamp: _base.add(const Duration(seconds: 2)),
        ),
      ),
    )
    ..append(
      MessageRecord(
        id: 'a2',
        parentId: 'r1',
        timestamp: _base.add(const Duration(seconds: 3)),
        message: assistant(
          'Deploy finished',
          _base.add(const Duration(seconds: 3)),
        ),
      ),
    )
    ..append(
      MessageRecord(
        id: 'u2',
        parentId: 'a2',
        timestamp: _base.add(const Duration(seconds: 10)),
        message: UserMessage.text('Check the logs'),
      ),
    )
    ..append(
      MessageRecord(
        id: 'a3',
        parentId: 'u2',
        timestamp: _base.add(const Duration(seconds: 11)),
        message: assistant('All clean', _base.add(const Duration(seconds: 11))),
      ),
    );
}

/// Pumps the launch harness, taps OPEN, and settles the route animation
/// and the panel controller's debounce timers with fixed pumps.
Future<void> _openPanel(
  WidgetTester tester,
  FakeChatService service,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildFahTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => openTrajectoryPanel(context, service: service),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('OPEN'));
  await tester.pump(); // start the route animation
  await tester.pump(const Duration(milliseconds: 400)); // finish it
  await tester.pump(const Duration(seconds: 4)); // flush debounce timers
}

void main() {
  for (final (name, size) in [
    ('layout/wide_dialog_page', goldenSizeDesktop),
    ('layout/narrow_bottom_sheet', goldenSizePhone),
  ]) {
    testWidgets(name, (tester) async {
      final service = FakeChatService();
      _populate(service.feed);
      addTearDown(service.feed.dispose);
      await _openPanel(tester, service, size);
      await expectGolden(tester, '$name.png');
    });
  }
}
