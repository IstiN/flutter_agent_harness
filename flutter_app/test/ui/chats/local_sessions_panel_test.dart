@TestOn('vm')
/// Widget tests for the Local section's folder-first navigation panels:
/// the level-1 folder STRIP (Ø50 circles + name labels,
/// avatars on a 70pt pitch, accent capsule + rounded-square selection),
/// the Telegram-style session list beside the strip (name, time, preview,
/// badges, accent selection, hairlines), the folder name in the sidebar
/// header, and the '<' back chevron restoring the strip + header.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

ChatListEntry entry(
  String id, {
  String? folderPath,
  DateTime? lastActivity,
  String? preview,
  int? unread = 0,
  bool isStreaming = false,
  bool isSubagent = false,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  folderPath: folderPath,
  title: id,
  preview: preview ?? 'Preview of $id',
  createdAt: DateTime.utc(2026, 1, 1),
  lastActivity: lastActivity ?? DateTime.utc(2026, 1, 2),
  unreadCount: unread,
  localMessageCount: 3,
  isStreaming: isStreaming,
  isSubagent: isSubagent,
);

Future<ChatListController> controller(List<ChatListEntry> entries) async {
  final c = ChatListController(localAdapter: StaticChatListAdapter(entries));
  await c.load();
  return c;
}

Future<void> pumpPanel(
  WidgetTester tester,
  ChatListController c, {
  String? folderId,
  String? sessionId,
  Future<void> Function(ChatListEntry)? onOpen,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(720, 800);
  addTearDown(tester.view.reset);
  var openFolder = folderId;
  await tester.pumpWidget(
    StatefulBuilder(
      builder: (context, setState) => MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalSessionsPanel(
            controller: c,
            selectedFolderId: openFolder,
            onSelectFolder: (id) => setState(() => openFolder = id),
            selectedSessionId: sessionId,
            onOpenSession: (e) => onOpen?.call(e) ?? Future.value(),
            onNew: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });

  testWidgets('the level-1 list renders standard [logo][name] rows, '
      'newest folder first', (tester) async {
    final c = await controller([
      entry(
        'old',
        folderPath: '/work/fa',
        lastActivity: DateTime.utc(2026, 1, 2),
      ),
      entry(
        'live',
        folderPath: '/work/mono',
        lastActivity: DateTime.utc(2026, 1, 4),
        isStreaming: true,
      ),
      entry('sub', folderPath: '/work/mono', isSubagent: true),
    ]);
    await pumpPanel(tester, c);

    // The list carries every folder (grouped by cwd, newest first) as
    // standard [logo][name] rows with the folder path as meta.
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsNothing);
    expect(find.text('mono'), findsOneWidget);
    expect(find.text('fa'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('localFolderRow-/work/mono')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('localFolderRow-/work/fa')),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('localFolderRow-/work/mono')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('localFolderRow-/work/fa')))
            .dy,
      ),
    );
    expect(find.text('/work/mono'), findsOneWidget);
    expect(find.text('/work/fa'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget, reason: 'the header title');
    expect(find.text('sub'), findsNothing);

    // Geometry: 70pt rows, Ø50 avatars.
    expect(
      tester
          .getSize(find.byKey(const ValueKey('localFolderRow-/work/fa')))
          .height,
      LocalSessionsPanel.stripItemPitch,
    );
    final avatars = find.byType(FolderAvatar);
    expect(avatars, findsNWidgets(2));
    expect(tester.getSize(avatars.first).width, 50);
    expect(tester.getSize(avatars.first).height, 50);
    expect(
      tester
              .getTopLeft(find.byKey(const ValueKey('localFolderRow-/work/fa')))
              .dy -
          tester
              .getTopLeft(
                find.byKey(const ValueKey('localFolderRow-/work/mono')),
              )
              .dy,
      LocalSessionsPanel.stripItemPitch,
    );

    // Long cwds middle-truncate to a ~26-char meta, Personal shows none,
    // and the session-count label is gone entirely.
    final long = await controller([
      entry(
        'a',
        folderPath: '/Users/Uladzimir_Klyshevich/git/flutter_agent',
        lastActivity: DateTime.utc(2026, 1, 4),
      ),
      entry('b', lastActivity: DateTime.utc(2026, 1, 2)),
    ]);
    await pumpPanel(tester, long);
    expect(find.text('/Users/Uladz…flutter_agent'), findsOneWidget);
    expect(find.textContaining('session'), findsNothing);
    expect(
      find.byKey(const ValueKey('localFolderSelectedCapsule')),
      findsNothing,
    );
  });

  testWidgets('selecting a folder opens its session list beside the strip, '
      'paints the capsule, squares the avatar and names the header', (
    tester,
  ) async {
    final c = await controller([
      entry(
        'design',
        folderPath: '/work/fa',
        lastActivity: DateTime.utc(2026, 1, 3, 12),
        unread: 4,
      ),
      entry(
        'docs',
        folderPath: '/work/fa',
        lastActivity: DateTime.utc(2026, 1, 2, 9),
        isStreaming: true,
      ),
      entry('other', folderPath: '/work/mono'),
    ]);
    await pumpPanel(tester, c);

    await tester.tap(find.byKey(const ValueKey('localFolderRow-/work/fa')));
    await tester.pumpAndSettle();

    // The folder's name lands in the sidebar header; the strip shows
    // avatars only (no labels).
    expect(find.text('fa'), findsOneWidget);

    // The session list opens to the RIGHT of the (still visible) strip.
    final strip = tester.getRect(
      find.byKey(const ValueKey('localFoldersStrip')),
    );
    final design = find.byKey(const ValueKey('localSession-design'));
    final docs = find.byKey(const ValueKey('localSession-docs'));
    expect(tester.getTopLeft(design).dy, lessThan(tester.getTopLeft(docs).dy));
    expect(tester.getTopLeft(design).dx, greaterThan(strip.right));
    expect(find.text('design'), findsOneWidget);
    expect(find.text('Preview of design'), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionUnread')), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionRunning')), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    // Telegram pitch: 70pt rows with hairline separators.
    expect(tester.getSize(design).height, LocalSessionsPanel.sessionRowPitch);

    // The selected folder wears the accent capsule flush to the strip's
    // LEFT edge and its avatar re-renders as a rounded square (radius
    // ~25% of the Ø50 avatar); the unselected one stays a circle.
    final capsule = tester.getRect(
      find.byKey(const ValueKey('localFolderSelectedCapsule')),
    );
    expect(capsule.width, LocalSessionsPanel.stripCapsuleWidth);
    expect(capsule.height, LocalSessionsPanel.stripCapsuleHeight);
    expect(capsule.left, strip.left);
    expect(
      capsule.center.dy,
      inInclusiveRange(
        strip.top,
        strip.top + LocalSessionsPanel.stripItemPitch,
      ),
      reason: 'the capsule rides the selected folder row',
    );
    final selectedAvatar = tester.widget<FolderAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('localFolder-/work/fa')),
        matching: find.byType(FolderAvatar),
      ),
    );
    expect(selectedAvatar.circle, isFalse);
    expect(selectedAvatar.radiusFactor, 0.25);
    final unselectedAvatar = tester.widget<FolderAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('localFolder-/work/mono')),
        matching: find.byType(FolderAvatar),
      ),
    );
    expect(unselectedAvatar.circle, isTrue);
  });

  testWidgets('tapping a session row opens it through the shell callback '
      'and the selected row is highlighted', (tester) async {
    final opened = <String>[];
    final c = await controller([entry('design', folderPath: '/work/fa')]);
    await pumpPanel(
      tester,
      c,
      folderId: '/work/fa',
      sessionId: 'design',
      onOpen: (e) async => opened.add(e.id.value),
    );
    await tester.tap(find.byKey(const ValueKey('localSession-design')));
    await tester.pumpAndSettle();
    expect(opened, ['design']);
    // Selected row keeps its key; the badge/preview stay visible.
    expect(find.byKey(const ValueKey('localSession-design')), findsOneWidget);
    expect(find.text('Preview of design'), findsOneWidget);
  });

  testWidgets('drilled session rows have NO leading glyph — title leads '
      '(owner pass)', (tester) async {
    final c = await controller([
      entry('design', folderPath: '/work/fa'),
      entry('docs', folderPath: '/work/fa', isStreaming: true),
    ]);
    await pumpPanel(tester, c, folderId: '/work/fa');

    // Space is tight in the drilled pane: no neutral glyph, no letter
    // avatar — the row is title (+time) over preview (+running dot).
    final sessionList = find.byKey(const ValueKey('localSessionList'));
    expect(
      find.descendant(of: sessionList, matching: find.byType(FolderAvatar)),
      findsNothing,
    );
    expect(
      find.descendant(of: sessionList, matching: find.byType(NeutralGlyphAvatar)),
      findsNothing,
    );
    expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
    // The title starts at the row's leading padding (no avatar offset).
    final titleLeft = tester
        .getTopLeft(find.text('design'))
        .dx;
    final rowLeft = tester
        .getTopLeft(find.byKey(const ValueKey('localSession-design')))
        .dx;
    expect(titleLeft - rowLeft, closeTo(10, .5));
    // Streaming dot still rides the row.
    expect(find.byKey(const ValueKey('localSessionRunning')), findsOneWidget);
  });

  testWidgets('the level swap animates in (200ms easeInOutCubic) and keys '
      'stay stable after settle', (tester) async {
    final c = await controller([
      entry('design', folderPath: '/work/fa'),
      entry('docs', folderPath: '/work/mono'),
    ]);
    await pumpPanel(tester, c);

    final switcher = find.byType(AnimatedSwitcher);
    expect(switcher, findsOneWidget);
    final spec = tester.widget<AnimatedSwitcher>(switcher);
    expect(spec.duration, const Duration(milliseconds: 200));
    expect(spec.switchInCurve, Curves.easeInOutCubic);
    expect(spec.switchOutCurve, Curves.easeInOutCubic);

    // Drill: the incoming level is fading in while the outgoing one fades
    // out (the header never participates).
    await tester.tap(find.byKey(const ValueKey('localFolderRow-/work/fa')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionList')), findsOneWidget);
    await tester.pumpAndSettle();

    // Settled: exactly the level-2 surface, with the stable keys.
    expect(find.byKey(const ValueKey('localFoldersList')), findsNothing);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionList')), findsOneWidget);
    expect(find.byKey(ValueKey('localFolder-/work/fa')), findsOneWidget);
    expect(find.byKey(const ValueKey('localSession-design')), findsOneWidget);

    // Back runs the SAME transition (no special reverse animation).
    await tester.tap(find.byKey(const ValueKey('localFolderBack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionList')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsNothing);
    expect(find.byKey(const ValueKey('localSessionList')), findsNothing);
    expect(
      find.byKey(ValueKey('localFolderRow-/work/mono')),
      findsOneWidget,
      reason: 'level-1 keys survive the round trip',
    );
  });

  testWidgets('back walks the open folder to the level-1 folder list and '
      'restores the Local header title', (tester) async {
    final c = await controller([entry('design', folderPath: '/work/fa')]);
    await pumpPanel(tester, c, folderId: '/work/fa');
    expect(find.text('fa'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('localFolderBack')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsNothing);
    expect(find.byKey(const ValueKey('localSession-design')), findsNothing);
    expect(find.text('fa'), findsOneWidget, reason: 'the list row name');
    expect(find.text('Local'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('localFolderSelectedCapsule')),
      findsNothing,
    );
  });

  testWidgets('the empty folder state and the empty folder list each '
      'render their copy', (tester) async {
    final c = await controller([]);
    await pumpPanel(tester, c);
    expect(find.text('No project folders yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersList')), findsNothing);

    final solo = await controller([entry('only', folderPath: '/work/solo')]);
    await pumpPanel(tester, solo, folderId: '/work/gone');
    // A folder id that is not in the projection falls back to the list.
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.text('No sessions in this folder yet'), findsNothing);
  });

  testWidgets('the folder strip paints NO scrollbar thumb (owner clip) — '
      'wheel and drag scrolling still work', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final c = await controller([
        for (var i = 0; i < 30; i++) entry('s-$i', folderPath: '/work/f$i'),
      ]);
      await pumpPanel(tester, c, folderId: '/work/f3');

      final strip = find.byKey(const ValueKey('localFoldersStrip'));
      // The desktop platform attaches a Material scrollbar thumb to the
      // strip's ListView by default — the owner clip: it must never paint.
      expect(
        find.descendant(of: strip, matching: find.byType(Scrollbar)),
        findsNothing,
      );
      // …and the strip still scrolls (drag fling).
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: strip, matching: find.byType(Scrollable)),
          )
          .position;
      final before = position.pixels;
      await tester.fling(strip, const Offset(0, -160), 600);
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(before), reason: 'drag still scrolls');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
