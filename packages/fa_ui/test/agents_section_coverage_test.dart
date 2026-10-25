// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A manager with one registered child (status/usage applied via [tweak]).
Future<SubagentHandle> _child(
  SubagentManager manager, {
  String id = 'child-1',
  void Function(SubagentHandle handle)? tweak,
}) async {
  final handle = await manager.register(
    id: id,
    name: id,
    agentType: 'task',
    task: 'fix the login bug',
  );
  tweak?.call(handle);
  return handle;
}

Future<void> _pumpSection(WidgetTester tester, SubagentManager manager) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentsSection(
          manager: manager,
          mainDescription: 'gpt-5 · 12.3k',
          observe: (id, {tail = 20}) async => const [],
          send: (id, message) async {},
        ),
      ),
    ),
  );
}

void main() {
  test('agentStatusEmoji maps every subagent status', () {
    expect(agentStatusEmoji(SubagentStatus.queued), '⏳');
    expect(agentStatusEmoji(SubagentStatus.running), '🔄');
    expect(agentStatusEmoji(SubagentStatus.idle), '⏸');
    expect(agentStatusEmoji(SubagentStatus.completed), '✅');
    expect(agentStatusEmoji(SubagentStatus.failed), '❌');
    expect(agentStatusEmoji(SubagentStatus.aborted), '🛑');
  });

  testWidgets('AgentsSection with no children shows the empty hint', (
    tester,
  ) async {
    await _pumpSection(tester, SubagentManager(parentSessionId: 's'));

    expect(find.text('main (orchestrator)'), findsOneWidget);
    expect(find.text('gpt-5 · 12.3k'), findsOneWidget);
    expect(
      find.text('No subagents yet — the task tool spawns them'),
      findsOneWidget,
    );
  });

  testWidgets('AgentsSection renders one row per retained child with its '
      'status emoji and task preview', (tester) async {
    final manager = SubagentManager(parentSessionId: 's');
    await _child(
      manager,
      id: 'child-1',
      tweak: (handle) {
        handle.status = SubagentStatus.running;
        handle.tokens = 42;
        handle.modelId = 'gpt-5';
      },
    );
    await _child(
      manager,
      id: 'child-2',
      tweak: (handle) {
        handle.status = SubagentStatus.failed;
      },
    );
    await _pumpSection(tester, manager);

    expect(find.text('task:child-1'), findsOneWidget);
    // description: status · task · tokens · model.
    expect(
      find.text('running · fix the login bug · 42t · gpt-5'),
      findsOneWidget,
    );
    expect(find.text('⏳'), findsNothing); // queued emoji — child-1 is running
    expect(find.text('🔄'), findsOneWidget);
    expect(find.text('❌'), findsOneWidget);
    expect(find.text('failed · fix the login bug'), findsOneWidget);
  });

  testWidgets('AgentDetailPage send with an empty field is an early-out', (
    tester,
  ) async {
    final manager = SubagentManager(parentSessionId: 's');
    final handle = await _child(
      manager,
      tweak: (handle) => handle.status = SubagentStatus.running,
    );
    final sent = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AgentDetailPage(
          handle: handle,
          observe: (id, {tail = 20}) async => const [],
          send: (id, message) async => sent.add((id, message)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The button is enabled (non-terminal child) but the field is empty.
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(sent, isEmpty);
    expect(find.text('Message sent — agent resumed'), findsNothing);
  });

  testWidgets('AgentDetailPage sends the follow-up, clears the field and '
      'reloads the transcript', (tester) async {
    final manager = SubagentManager(parentSessionId: 's');
    final handle = await _child(
      manager,
      tweak: (handle) => handle.status = SubagentStatus.running,
    );
    final sent = <(String, String)>[];
    var observeCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AgentDetailPage(
          handle: handle,
          observe: (id, {tail = 20}) async {
            observeCalls++;
            return [('user', 'hi'), ('assistant', 'lo')];
          },
          send: (id, message) async => sent.add((id, message)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(observeCalls, 1); // the initial tail load
    expect(find.text('assistant'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'resume the task');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(sent, hasLength(1));
    expect(sent.single, (handle.id, 'resume the task'));
    // The field cleared after the send…
    expect(find.text('resume the task'), findsNothing);
    // …the transcript reloaded…
    expect(observeCalls, 2);
    // …and the confirmation snack surfaced.
    expect(find.text('Message sent — agent resumed'), findsOneWidget);
  });

  testWidgets('AgentDetailPage surfaces a failed send as an error snack and '
      'keeps the draft', (tester) async {
    final manager = SubagentManager(parentSessionId: 's');
    final handle = await _child(
      manager,
      tweak: (handle) => handle.status = SubagentStatus.running,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AgentDetailPage(
          handle: handle,
          observe: (id, {tail = 20}) async => const [],
          send: (id, message) async => throw StateError('child is gone'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'still here?');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('error: Bad state: child is gone'),
      findsOneWidget,
    );
    // The draft survives a failed send — the user can retry.
    expect(find.text('still here?'), findsOneWidget);
    expect(find.text('Message sent — agent resumed'), findsNothing);
  });
}
