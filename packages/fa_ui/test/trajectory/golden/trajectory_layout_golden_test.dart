// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden baselines for the trajectory surface's adaptive layouts: the
/// full-screen master-detail page (dark + light) and the narrow single-pane
/// page (the switcher swaps it in as the chat screen's body). Driven through
/// the real [TrajectoryScreen] over a pre-populated [FakeChatService] feed.
/// Settled with fixed-duration pumps — never `pumpAndSettle`, which can
/// never settle while route animations and the controller's debounce timers
/// interleave. See `golden_test_setup.dart` for the font and determinism
/// conventions.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_chat_service.dart';
import 'golden_test_setup.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

/// A realistic two-turn session (prompt → tool call → result → reply),
/// appended into [feed] before the controller subscribes.
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

/// Pumps [TrajectoryScreen] fed from a pre-populated feed so the controller
/// holds real derived state (no loading spinner), then settles the debounce.
Future<void> _pumpScreen(
  WidgetTester tester,
  FakeChatService service,
  Size size,
  ThemeData theme,
) async {
  final controller = TrajectoryController();
  service.feed.stream.listen(controller.updateSnapshot);
  await pumpGolden(
    tester,
    TrajectoryScreen(controller: controller, onClose: () {}),
    size: size,
    theme: theme,
  );
  // The throttled search index re-arms a 3s window per flush; pump past it.
  await tester.pump(const Duration(seconds: 7));
}

void main() {
  for (final (name, size, theme) in [
    ('layout/wide_fullscreen_dark', goldenSizeDesktop, buildFahTheme()),
    ('layout/wide_fullscreen_light', goldenSizeDesktop, buildFahThemeLight()),
    ('layout/narrow_page', goldenSizePhone, buildFahTheme()),
  ]) {
    testWidgets(name, (tester) async {
      final service = FakeChatService();
      _populate(service.feed);
      addTearDown(service.feed.dispose);
      await _pumpScreen(tester, service, size, theme);
      await expectGolden(tester, '$name.png');
    });
  }
}
