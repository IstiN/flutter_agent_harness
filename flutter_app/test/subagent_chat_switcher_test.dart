@TestOn('vm')
/// The subagent switcher docked above the composer (subagent sessions
/// owner pass): a parent chat shows one chip per subagent session; a
/// subagent chat shows its siblings plus the parent chip FIRST, the
/// CURRENT session's chip highlighted with the accent tint. Every chip is
/// a tap target that opens its session through the host's open flow.
library;

import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show ChatRunningDot;
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/widgets/subagent_chat_switcher.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaDesignTokens, FaVisualDirection, buildFaTheme;
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

Future<void> pumpSwitcher(
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
            SubagentChatSwitcher(
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
  test('chips for a parent chat: one per subagent, none for the parent',
      () async {
    final c = await controller([
      entry('poc', unread: 0),
      entry('scan', parentId: 'poc', isSubagent: true),
      entry('watch', parentId: 'poc', isSubagent: true, unread: 3),
    ]);
    final chips = subagentChipsFor(c, 'poc');
    expect(chips, hasLength(2));
    expect(chips.map((chip) => chip.entry.id.value), ['scan', 'watch']);
    expect(chips.any((chip) => chip.current), isFalse);
  });

  test('chips for a subagent chat: parent chip FIRST, then siblings, '
      'the current chip flagged', () async {
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true),
      entry('watch', parentId: 'poc', isSubagent: true),
      entry('other-family-child', parentId: 'other', isSubagent: true),
    ]);
    final chips = subagentChipsFor(c, 'watch');
    expect(chips.first.entry.id.value, 'poc');
    expect(chips.first.label, '← poc');
    expect(chips.first.current, isFalse);
    expect(chips.map((chip) => chip.entry.id.value), ['poc', 'scan', 'watch']);
    expect(chips.where((chip) => chip.current).single.entry.id.value, 'watch');
  });

  test('a chat without a subagent family has no chips (no row)', () async {
    final c = await controller([entry('solo')]);
    expect(subagentChipsFor(c, 'solo'), isEmpty);
    final orphaned = await controller([
      entry('ghost-child', parentId: 'ghost', isSubagent: true),
    ]);
    expect(subagentChipsFor(orphaned, 'ghost-child'), isEmpty);
  });

  testWidgets('the row renders the chips with the running dot and unread '
      'count, and a chip tap opens that session', (tester) async {
    final opened = <ChatListEntry>[];
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
      entry('watch', parentId: 'poc', isSubagent: true, unread: 3),
    ]);
    await pumpSwitcher(
      tester,
      controller: c,
      sessionId: 'poc',
      onOpen: (e) async => opened.add(e),
    );

    expect(find.byKey(const ValueKey('chatSubagentChip-scan')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatSubagentChip-watch')), findsOneWidget);
    // The running dot rides the streaming chip (the chat list's token).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatSubagentChip-scan')),
        matching: find.byType(ChatRunningDot),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatSubagentChip-watch')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('chatSubagentChip-scan')));
    await tester.pumpAndSettle();
    expect(opened.single.id.value, 'scan');
  });

  testWidgets('the current session chip carries the accent tint; the '
      'parent chip renders first with its name', (tester) async {
    final c = await controller([
      entry('poc'),
      entry('scan', parentId: 'poc', isSubagent: true),
      entry('watch', parentId: 'poc', isSubagent: true),
    ]);
    await pumpSwitcher(tester, controller: c, sessionId: 'watch');

    final tokens = FaDesignTokens.of(
      tester.element(find.byKey(const ValueKey('chatSubagentChip-watch'))),
    );
    expect(
      tester
          .widget<Material>(
            find.byKey(const ValueKey('chatSubagentChip-watch')),
          )
          .color,
      tokens.accentSoft,
      reason: 'the CURRENT session chip is accent-tinted',
    );
    expect(
      tester
          .widget<Material>(
            find.byKey(const ValueKey('chatSubagentChip-scan')),
          )
          .color,
      isNot(tokens.accentSoft),
    );

    // The parent chip sits LEFT of every sibling chip (first in the row).
    expect(
      tester.getRect(find.text('← poc')).left,
      lessThan(tester.getRect(find.text('scan')).left),
    );
  });

  testWidgets('a session without a subagent family renders no row', (
    tester,
  ) async {
    final c = await controller([entry('solo')]);
    await pumpSwitcher(tester, controller: c, sessionId: 'solo');
    expect(find.byType(SubagentChatSwitcher), findsOneWidget);
    expect(find.byKey(const ValueKey('chatSubagentChip-solo')), findsNothing);
  });
}
