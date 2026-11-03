@TestOn('vm')
/// Golden frames for the Telegram-style vertical rail (the wide shell's
/// left navigation) and the Local section's folder-first navigation:
///
/// - rail rows unselected / selected (accent tint, no fill) / badge
///   variants (accent + muted overlap circles), dark + light;
/// - the Local folder list (deterministic gradient-letter avatars,
///   session counts, running dots, latest-activity times);
/// - an open folder's Telegram-style session list (name, time, preview,
///   unread/running badges, accent-selected row, hairlines).
library;

import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa_ui/fa_ui.dart'
    show FahColors, FaVisualDirection, buildFaTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'golden_test_helper.dart';

/// Long-dead activity stamps (> 7 days old) so [chatListRelativeTime]
/// renders the stable "Dec 1" form instead of a now-relative count.
final _stamp = DateTime.utc(2025, 12, 1, 9, 30);

MessengerRailDestination _dest(
  IconData icon,
  String label, {
  bool selected = false,
  int? badge,
  bool badgeMuted = false,
}) => MessengerRailDestination(
  rowKey: ValueKey('golden-$label'),
  icon: icon,
  label: label,
  selected: selected,
  badge: badge,
  badgeMuted: badgeMuted,
  onTap: (_) {},
);

List<MessengerRailDestination> _railDestinations({
  required bool selected,
  required bool badges,
}) => [
  _dest(Icons.inbox_outlined, 'All', selected: selected),
  _dest(Icons.chat_bubble_outline_rounded, 'Unread', badge: badges ? 4 : null),
  _dest(Icons.people_outline_rounded, 'Agents'),
  _dest(Icons.tag_rounded, 'Channels'),
  _dest(
    Icons.folder_outlined,
    'Local',
    selected: false,
    badge: badges ? 2 : null,
    badgeMuted: true,
  ),
  _dest(Icons.notifications_none_rounded, 'Activity'),
  _dest(Icons.grid_view_rounded, 'Apps'),
  _dest(Icons.public_outlined, 'Networks'),
];

ChatListEntry _session(
  String id,
  String? cwd, {
  String? preview,
  int unread = 0,
  bool streaming = false,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  folderPath: cwd,
  title: id,
  preview: preview ?? 'Preview of $id',
  createdAt: _stamp,
  lastActivity: _stamp,
  unreadCount: unread,
  localMessageCount: 5,
  isStreaming: streaming,
);

Future<ChatListController> _controller(List<ChatListEntry> entries) async {
  final controller = ChatListController(
    localAdapter: StaticChatListAdapter(entries),
  );
  await controller.load();
  return controller;
}

Future<void> _pumpRail(
  WidgetTester tester, {
  required Brightness brightness,
  required bool selected,
  required bool badges,
  required String name,
}) async {
  await pumpGolden(
    tester,
    MessengerNavRail(
      destinations: _railDestinations(selected: selected, badges: badges),
      settingsLabel: 'Settings',
      onSettingsTap: () {},
    ),
    size: const Size(900, 800),
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: brightness,
    ),
    wrap:
        (child) => Scaffold(
          body: Row(
            children: [
              child,
              Expanded(
                child: Builder(
                  builder:
                      (context) => ColoredBox(
                        color: FahColors.of(context).panel,
                        child: const SizedBox.expand(),
                      ),
                ),
              ),
            ],
          ),
        ),
  );
  await expectGolden(tester, name);
}

Future<void> _pumpLocalPanel(
  WidgetTester tester, {
  required ChatListController controller,
  String? folderId,
  required String name,
  Size size = const Size(500, 640),
}) async {
  await pumpGolden(
    tester,
    Scaffold(
      body: LocalSessionsPanel(
        controller: controller,
        selectedFolderId: folderId,
        onSelectFolder: (_) {},
        selectedSessionId: folderId == null ? null : 'design-session',
        onOpenSession: (_) {},
        onNew: () {},
      ),
    ),
    size: size,
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    ),
    wrap: (child) => child,
  );
  await expectGolden(tester, name);
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });

  testWidgets('rail rows unselected: icon over label, no tint, no badges', (
    tester,
  ) async {
    await _pumpRail(
      tester,
      brightness: Brightness.dark,
      selected: false,
      badges: false,
      name: 'rail_nav_unselected',
    );
  });

  testWidgets('rail selection: accent tint on icon+label, no fill', (
    tester,
  ) async {
    await _pumpRail(
      tester,
      brightness: Brightness.dark,
      selected: true,
      badges: true,
      name: 'rail_nav_selected',
    );
  });

  testWidgets('rail badges: accent and muted overlap circles (light)', (
    tester,
  ) async {
    await _pumpRail(
      tester,
      brightness: Brightness.light,
      selected: true,
      badges: true,
      name: 'rail_nav_selected_light',
    );
  });

  testWidgets('local folder list: gradient avatars, counts, running dots', (
    tester,
  ) async {
    await _pumpLocalPanel(
      tester,
      name: 'local_folders',
      controller: await _controller([
        _session('design-session', '/work/flutter_agent', unread: 3),
        _session('docs-session', '/work/flutter_agent'),
        _session('mono-review', '/work/mono', streaming: true),
        _session('sandbox-chat', null),
      ]),
    );
  });

  testWidgets('local folder sessions: Telegram rows with badges and '
      'selection', (tester) async {
    await _pumpLocalPanel(
      tester,
      name: 'local_folder_sessions',
      folderId: '/work/flutter_agent',
      controller: await _controller([
        _session(
          'design-session',
          '/work/flutter_agent',
          preview: 'Rail pitch locked at 64pt',
          unread: 4,
        ),
        _session(
          'docs-session',
          '/work/flutter_agent',
          preview: 'Regenerated the l10n arb keys',
          streaming: true,
        ),
      ]),
    );
  });
}
