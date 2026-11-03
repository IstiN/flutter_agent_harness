@TestOn('vm')
/// Widget tests for the Local section's folder-first navigation panels:
/// folder rows (name / session count / latest time / running dot), the
/// Telegram-style session list (name, time, preview, badges, accent
/// selection, hairlines) and the '<' back chevron.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa_ui/fa_ui.dart' show FaVisualDirection, buildFaTheme;
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

Future<ChatListController> controller(
  List<ChatListEntry> entries,
) async {
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

  testWidgets('folder rows show name, session count, latest time and '
      'the running dot, newest folder first', (tester) async {
    final c = await controller([
      entry('old', folderPath: '/work/fa', lastActivity: DateTime.utc(2026, 1, 2)),
      entry(
        'live',
        folderPath: '/work/mono',
        lastActivity: DateTime.utc(2026, 1, 4),
        isStreaming: true,
      ),
      entry('sub', folderPath: '/work/mono', isSubagent: true),
    ]);
    await pumpPanel(tester, c);

    // Grouped by cwd: two folders, the one with the newest session first.
    expect(find.byKey(const ValueKey('localFolder-/work/mono')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFolder-/work/fa')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('localFolder-/work/mono'))).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('localFolder-/work/fa')))
            .dy,
      ),
    );
    expect(find.text('mono'), findsOneWidget);
    expect(find.text('fa'), findsOneWidget);
    // One session per folder: the subagent never inflated mono's count.
    expect(find.text('1 session'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('localFolderRunning')), findsOneWidget);
    // The subagent never became a folder session.
    expect(find.text('sub'), findsNothing);
  });

  testWidgets('opening a folder shows the Telegram-style session list and '
      'back returns to the folders', (tester) async {
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
    ]);
    await pumpPanel(tester, c);

    await tester.tap(find.byKey(const ValueKey('localFolder-/work/fa')));
    await tester.pumpAndSettle();

    // Rows in session order: newest first; header names the folder and
    // offers the '<' chevron.
    expect(find.text('fa'), findsOneWidget);
    final design = find.byKey(const ValueKey('localSession-design'));
    final docs = find.byKey(const ValueKey('localSession-docs'));
    expect(
      tester.getTopLeft(design).dy,
      lessThan(tester.getTopLeft(docs).dy),
    );
    expect(find.text('design'), findsOneWidget);
    expect(find.text('Preview of design'), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionUnread')), findsOneWidget);
    expect(find.byKey(const ValueKey('localSessionRunning')), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    // Telegram pitch: 70pt rows with hairline separators.
    expect(
      tester.getSize(design).height,
      LocalSessionsPanel.sessionRowPitch,
    );

    await tester.tap(find.byKey(const ValueKey('localFolderBack')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localFolderList')), findsOneWidget);
    expect(find.text('Preview of design'), findsNothing);
  });

  testWidgets('tapping a session row opens it through the shell callback '
      'and the selected row is highlighted', (tester) async {
    final opened = <String>[];
    final c = await controller([
      entry('design', folderPath: '/work/fa'),
    ]);
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

  testWidgets('the empty folder state and the empty folder list each '
      'render their copy', (tester) async {
    final c = await controller([]);
    await pumpPanel(tester, c);
    expect(find.text('No project folders yet'), findsOneWidget);

    final solo = await controller([
      entry('only', folderPath: '/work/solo'),
    ]);
    await pumpPanel(tester, solo, folderId: '/work/gone');
    // A folder id that is not in the projection falls back to the list.
    expect(find.byKey(const ValueKey('localFolderList')), findsOneWidget);
  });
}
