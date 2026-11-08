@TestOn('vm')
/// Golden coverage for the subagent badge above the composer (subagent
/// sessions owner pass): the running-count badge, the neutral idle state
/// and the anchored picker popover with the parent chip («← poc») and the
/// Active | Done filter. Fixture datetimes sit far in the past, so the
/// relative last-activity labels resolve to fixed absolute dates.
library;

import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/widgets/subagent_chat_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

ChatListEntry _entry(
  String id, {
  String? parentId,
  bool isSubagent = false,
  bool streaming = false,
  int unread = 0,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  title: id,
  createdAt: DateTime.utc(2026, 1, 1),
  lastActivity: DateTime.utc(2026, 1, 2),
  unreadCount: unread,
  isStreaming: streaming,
  parentId: parentId,
  isSubagent: isSubagent,
);

Future<ChatListController> _controller(List<ChatListEntry> entries) async {
  final result = ChatListController(
    localAdapter: StaticChatListAdapter(entries),
  );
  await result.load();
  return result;
}

Widget _host(ChatListController controller, String sessionId) => Column(
  children: [
    const Expanded(child: SizedBox.shrink()),
    Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SubagentChatBadge(
          controller: controller,
          sessionId: sessionId,
          onOpen: (_) async {},
        ),
      ),
    ),
    const SizedBox(height: 48),
  ],
);

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
  });

  group('SubagentChatBadge goldens', () {
    testWidgets('running badge: the count of RUNNING subagents', (
      tester,
    ) async {
      final controller = await _controller([
        _entry('poc'),
        _entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
        _entry('watch', parentId: 'poc', isSubagent: true, streaming: true),
        _entry('done-child', parentId: 'poc', isSubagent: true),
      ]);
      await pumpGolden(tester, _host(controller, 'poc'));
      expect(find.byKey(const ValueKey('chatSubagentBadge')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await expectGolden(tester, 'subagent_chat_badge_running');
    });

    testWidgets('idle badge: no count when nothing runs', (tester) async {
      final controller = await _controller([
        _entry('poc'),
        _entry('scan', parentId: 'poc', isSubagent: true),
        _entry('watch', parentId: 'poc', isSubagent: true),
      ]);
      await pumpGolden(tester, _host(controller, 'poc'));
      expect(find.byKey(const ValueKey('chatSubagentBadge')), findsOneWidget);
      expect(find.text('2'), findsNothing);
      await expectGolden(tester, 'subagent_chat_badge_idle');
    });

    testWidgets('popover: the parent chip first, the Active | Done filter '
        'and the subagent rows', (tester) async {
      final controller = await _controller([
        _entry('poc'),
        _entry('scan', parentId: 'poc', isSubagent: true, streaming: true),
        _entry('watch', parentId: 'poc', isSubagent: true, unread: 3),
      ]);
      await pumpGolden(tester, _host(controller, 'watch'));
      await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatSubagentEntry-poc')), findsOneWidget);
      expect(find.text('←'), findsOneWidget);
      await expectGolden(tester, 'subagent_chat_badge_popover');
    });
  });
}
