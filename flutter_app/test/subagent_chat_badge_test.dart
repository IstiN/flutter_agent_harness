@TestOn('vm')
/// The subagent badge above the composer (subagent sessions owner pass):
/// one compact account-tree icon with the count of RUNNING subagents;
/// tapping it opens the anchored picker popover — the parent chip first
/// when the open chat is a subagent, an Active | Done filter (default
/// Active) and one row per subagent. Rows run the host's open flow.
library;

import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show ChatRunningDot;
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/widgets/subagent_chat_badge.dart';
import 'package:fa_ui/fa_ui.dart' show FaVisualDirection, buildFaTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatListEntry entry(
  String id, {
  String? parentId,
  bool isSubagent = false,
  int unread = 0,
  bool streaming = false,
  ChatPresence? presence,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  title: id,
  createdAt: DateTime.utc(2026, 1, 1),
  lastActivity: DateTime.utc(2026, 1, 2),
  unreadCount: unread,
  isStreaming: streaming,
  presence: presence,
  parentId: parentId,
  isSubagent: isSubagent,
);

Future<ChatListController> controller(List<ChatListEntry> entries) async {
  final result = ChatListController(
    localAdapter: StaticChatListAdapter(entries),
  );
  await result.load();
  return result;
}

Future<void> pumpBadge(
  WidgetTester tester, {
  required ChatListController controller,
  required String? sessionId,
  Future<void> Function(ChatListEntry entry)? onOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox.shrink()),
            SubagentChatBadge(
              controller: controller,
              sessionId: sessionId,
              onOpen: onOpen ?? (_) async {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('family for a parent chat: children only, running counted', () async {
    final c = await controller([
      entry('poc', unread: 0),
      entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
      entry('watch', parentId: 'poc', isSubagent: true),
    ]);
    final family = subagentFamilyFor(c, 'poc')!;
    expect(family.parentId, 'poc');
    expect(family.parent, isNull, reason: 'a parent chat has no parent row');
    expect(family.children.map((e) => e.id.value), ['scan', 'watch']);
    expect(family.running.map((e) => e.id.value), ['scan']);
  });

  test(
    'family for a subagent chat: the parent row + the sibling children',
    () async {
      final c = await controller([
        entry('poc'),
        entry('scan', parentId: 'poc', isSubagent: true),
        entry('watch', parentId: 'poc', isSubagent: true),
        entry('other-family-child', parentId: 'other', isSubagent: true),
      ]);
      final family = subagentFamilyFor(c, 'watch')!;
      expect(family.parent!.id.value, 'poc');
      expect(family.children.map((e) => e.id.value), ['scan', 'watch']);
    },
  );

  test('a chat without a subagent family has none (no badge)', () async {
    final c = await controller([entry('solo')]);
    expect(subagentFamilyFor(c, 'solo'), isNull);
    // A lone orphan (its parent chat is gone) hides too.
    final orphaned = await controller([
      entry('ghost-child', parentId: 'ghost', isSubagent: true),
    ]);
    expect(subagentFamilyFor(orphaned, 'ghost-child'), isNull);
  });

  testWidgets('a session without a subagent family renders no badge', (
    tester,
  ) async {
    final c = await controller([entry('solo')]);
    await pumpBadge(tester, controller: c, sessionId: 'solo');
    expect(find.byKey(const ValueKey('chatSubagentBadge')), findsNothing);
  });

  testWidgets('the badge shows the running count; none when idle', (
    tester,
  ) async {
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
      entry('watch', parentId: 'poc', isSubagent: true, streaming: true),
      entry('done-child', parentId: 'poc', isSubagent: true),
    ]);
    await pumpBadge(tester, controller: c, sessionId: 'poc');
    expect(find.byKey(const ValueKey('chatSubagentBadge')), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'two RUNNING subagents');
  });

  testWidgets('the badge and its popover are anchored on the right', (
    tester,
  ) async {
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
    ]);
    await pumpBadge(tester, controller: c, sessionId: 'poc');
    final badge = find.byKey(const ValueKey('chatSubagentBadge'));
    expect(tester.getRect(badge).right, greaterThan(760));

    await tester.tap(badge);
    await tester.pumpAndSettle();

    final row = tester.getRect(
      find.byKey(const ValueKey('chatSubagentEntry-scan')),
    );
    expect(row.right, closeTo(tester.getRect(badge).right, 1));
  });

  testWidgets('the badge popover lists the family with the Active|Done '
      'filter and opens a row through the host flow', (tester) async {
    final opened = <ChatListEntry>[];
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
      entry('watch', parentId: 'poc', isSubagent: true, unread: 3),
    ]);
    await pumpBadge(
      tester,
      controller: c,
      sessionId: 'poc',
      onOpen: (e) async => opened.add(e),
    );

    await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
    await tester.pumpAndSettle();

    // Default filter = Active: the streaming row is visible…
    expect(
      find.byKey(const ValueKey('chatSubagentEntry-scan')),
      findsOneWidget,
    );
    // …and the finished row hides behind the Done toggle.
    expect(find.byKey(const ValueKey('chatSubagentEntry-watch')), findsNothing);
    // The running dot rides the active row (the chat list's token).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatSubagentEntry-scan')),
        matching: find.byType(ChatRunningDot),
      ),
      findsOneWidget,
    );

    // Filter = Done: the finished row surfaces with its unread count.
    await tester.tap(find.byKey(const ValueKey('chatSubagentToggleDone')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chatSubagentEntry-watch')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatSubagentEntry-watch')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chatSubagentEntry-scan')), findsNothing);

    // A row tap opens that subagent's chat and closes the popover.
    await tester.tap(find.byKey(const ValueKey('chatSubagentEntry-watch')));
    await tester.pumpAndSettle();
    expect(opened.single.id.value, 'watch');
    expect(find.byKey(const ValueKey('chatSubagentEntry-watch')), findsNothing);
  });

  testWidgets('a subagent chat\'s popover lists the parent chip FIRST; '
      'tapping it opens the parent', (tester) async {
    final opened = <ChatListEntry>[];
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true),
      entry('watch', parentId: 'poc', isSubagent: true),
    ]);
    await pumpBadge(
      tester,
      controller: c,
      sessionId: 'watch',
      onOpen: (e) async => opened.add(e),
    );

    await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
    await tester.pumpAndSettle();

    final parentRow = find.byKey(const ValueKey('chatSubagentEntry-poc'));
    expect(parentRow, findsOneWidget);
    expect(find.text('←'), findsOneWidget);
    expect(find.text('poc'), findsOneWidget);
    // The parent chip sits ABOVE every sibling row.
    expect(
      tester.getRect(find.text('←')).top,
      lessThan(tester.getRect(find.text('scan')).top),
    );

    await tester.tap(parentRow);
    await tester.pumpAndSettle();
    expect(opened.single.id.value, 'poc');
  });

  testWidgets('an outside tap closes the popover without opening anything', (
    tester,
  ) async {
    final opened = <ChatListEntry>[];
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true),
    ]);
    await pumpBadge(
      tester,
      controller: c,
      sessionId: 'poc',
      onOpen: (e) async => opened.add(e),
    );

    await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chatSubagentEntry-scan')),
      findsOneWidget,
    );

    // Dismiss via the barrier: the popover closes, nothing opens.
    await tester.tapAt(const Offset(600, 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSubagentEntry-scan')), findsNothing);
    expect(opened, isEmpty);
  });
}
