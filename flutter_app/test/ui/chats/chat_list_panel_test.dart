import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/widgets/messenger_navigation_controls.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:fa_ui/fa_ui.dart' show FaLogo, FaVisualDirection, buildFaTheme;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../network/fakes.dart';

ChatListEntry entry(
  String id, {
  ChatListEntryKind kind = ChatListEntryKind.localAgent,
  String? networkId,
  int? unread = 0,
  int messageCount = 1,
  String? folderName,
  String? folderPath,
  String? parentId,
  bool isSubagent = false,
}) => ChatListEntry(
  id: kind == ChatListEntryKind.localAgent
      ? ChatEntryId.local(id)
      : ChatEntryId.network(kind, networkId: networkId!, id: id),
  kind: kind,
  networkId: networkId,
  networkName: networkId == null ? null : 'Remote team',
  folderName: folderName,
  folderPath: folderPath,
  title: id,
  preview: 'Preview for $id',
  createdAt: DateTime.utc(2025, 12, 31),
  lastActivity: DateTime.utc(2026, 1, 2),
  unreadCount: unread,
  localMessageCount: kind == ChatListEntryKind.localAgent ? messageCount : null,
  parentId: parentId,
  isSubagent: isSubagent,
);

Future<ChatListController> makeController(
  List<ChatListEntry> entries, {
  NetworkInboxAdapter? network,
  ChatReadCursorStore? reads,
}) async {
  final controller = ChatListController(
    localAdapter: StaticChatListAdapter(
      entries.where((e) => e.kind == ChatListEntryKind.localAgent).toList(),
    ),
    networkAdapter: network,
    networkNames: const {'remote': 'Remote team'},
    readCursorStore: reads,
  );
  await controller.load();
  return controller;
}

Future<void> pumpPanel(
  WidgetTester tester,
  ChatListController controller, {
  bool compact = false,
  double? width,
  FaVisualDirection direction = FaVisualDirection.glass,
  Brightness brightness = Brightness.dark,
  Future<void> Function(ChatListEntry entry)? onOpen,
  VoidCallback? onNew,
  NetworkSessionManager? networkManager,
  ChatEntryId? selectedEntryId,
  Set<String> expandedParents = const {},
  Set<String> collapsedParents = const {},
  void Function(String parentId, bool expanded)? onToggleParent,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFaTheme(direction: direction, brightness: brightness),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: width ?? (compact ? 390 : 360),
          child: ChatListPanel(
            controller: controller,
            compact: compact,
            selectedEntryId: selectedEntryId,
            expandedParents: expandedParents,
            collapsedParents: collapsedParents,
            onToggleParent: onToggleParent,
            onOpen: onOpen ?? (_) async {},
            onNew: onNew ?? () {},
            networkManager: networkManager,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('folder display paths abbreviate only the real home prefix', () {
    expect(compactChatFolderPath('/Users/me', homePath: '/Users/me'), '~');
    expect(
      compactChatFolderPath('/Users/me/git/fa_network', homePath: '/Users/me'),
      '~/git/fa_network',
    );
    expect(
      compactChatFolderPath('/Users/me-other/project', homePath: '/Users/me'),
      '/Users/me-other/project',
    );
    expect(
      compactChatFolderPath('relative/project', homePath: '/Users/me'),
      'relative/project',
    );
    expect(compactChatFolderPath('/', homePath: '/'), '~');
    expect(compactChatFolderPath('/work', homePath: '/'), '~/work');
  });

  testWidgets('filters, pin, and successful open work through the list', (
    tester,
  ) async {
    final reads = ChatReadCursorStore.inMemory(accountId: 'a');
    final controller = await makeController(
      [entry('Design'), entry('General')],
      network: FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'channel',
            title: 'Network channel',
            unreadCount: 2,
          ),
        ],
      ),
      reads: reads,
    );
    var opened = 0;
    await pumpPanel(
      tester,
      controller,
      selectedEntryId: ChatEntryId.local('Design'),
      onOpen: (_) async => opened++,
    );

    expect(find.text('Design'), findsOneWidget);
    expect(find.text('Network channel'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatFilter-agents')));
    await tester.pumpAndSettle();
    expect(find.text('Design'), findsOneWidget);
    expect(find.text('Network channel'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(ValueKey('chatRow-${ChatEntryId.local('Design')}')),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('chatPin-${ChatEntryId.local('Design')}')),
    );
    await tester.pumpAndSettle();
    expect(controller.pinnedEntries.single.title, 'Design');

    await tester.tap(find.text('Design'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(reads.cursorFor(ChatEntryId.local('Design')), 1);
  });

  testWidgets('wide categories and network share one horizontal control', (
    tester,
  ) async {
    final controller = await makeController([entry('Design')]);
    await pumpPanel(tester, controller);

    expect(find.text('All').hitTestable(), findsOneWidget);
    for (final label in ['Unread', 'Agents', 'Channels']) {
      expect(find.text(label), findsNothing);
    }
    final group = tester.getRect(
      find.byKey(const ValueKey('chatCategoryChips')),
    );
    final networks = tester.getRect(
      find.byKey(const ValueKey('chatNetworkFilter')),
    );
    final all = tester.getRect(find.byKey(const ValueKey('chatFilter-all')));
    expect(group.height, 44);
    expect(networks.center.dy, closeTo(all.center.dy, .001));
    expect(networks.right, lessThanOrEqualTo(group.right));
    expect(find.text('All networks'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
    await tester.pumpAndSettle();
    expect(find.text('All networks'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
  });

  testWidgets('icon-only filter glyphs keep symmetric insets and hit targets', (
    tester,
  ) async {
    final controller = await makeController([entry('Design')]);
    for (final direction in FaVisualDirection.values) {
      for (final brightness in Brightness.values) {
        for (final width in [280.0, 360.0, 390.0]) {
          await pumpPanel(
            tester,
            controller,
            width: width,
            direction: direction,
            brightness: brightness,
          );
          await tester.tap(find.byKey(const ValueKey('chatFilter-unread')));
          await tester.pumpAndSettle();
          final reason = '$direction/$brightness/$width';
          final group = tester.getRect(
            find.byKey(const ValueKey('chatCategoryChips')),
          );
          final all = find.byKey(const ValueKey('chatFilter-all'));
          final network = find.byKey(const ValueKey('chatNetworkFilter'));
          final allRect = tester.getRect(all);
          final networkRect = tester.getRect(network);
          final allIcon = tester.getRect(
            find.descendant(of: all, matching: find.byType(Icon)),
          );
          final networkIcon = tester.getRect(
            find.descendant(of: network, matching: find.byType(Icon)),
          );
          expect(group.height, 44, reason: reason);
          expect(allRect.size, const Size(36, 32), reason: reason);
          expect(networkRect.size, const Size(36, 32), reason: reason);
          // The group has 10px exterior padding and 3px border/padding.
          expect(
            allIcon.center.dx - (group.left + 13),
            closeTo(18, .001),
            reason: reason,
          );
          expect(
            (group.right - 13) - networkIcon.center.dx,
            closeTo(18, .001),
            reason: reason,
          );
          expect(all.hitTestable(), findsOneWidget, reason: reason);
          expect(network.hitTestable(), findsOneWidget, reason: reason);
          await tester.tap(all);
          await tester.pumpAndSettle();
          expect(controller.filter, ChatListFilter.all, reason: reason);
          await tester.tap(network);
          await tester.pumpAndSettle();
          expect(find.text('All networks'), findsOneWidget, reason: reason);
          await tester.tap(find.text('All networks').last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: reason);
        }
      }
    }
  });

  testWidgets('macOS desktop places search and compose below the titlebar', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = await makeController([entry('Design')]);
    await pumpPanel(tester, controller);

    final search = tester.getRect(
      find.byKey(const ValueKey('messengerSearchField')),
    );
    final newButton = find.byKey(const ValueKey('messengerNewButton'));
    expect(search.top, greaterThanOrEqualTo(46));
    expect(tester.getRect(newButton).top, greaterThanOrEqualTo(46));
    final button = tester.widget<IconButton>(newButton);
    expect(button.color, Colors.white);
    expect(
      button.style?.backgroundColor?.resolve(const <WidgetState>{}),
      const Color(0xFF3F8FF7),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'selected rows use the accent and hover reveals desktop actions',
    (tester) async {
      final controller = await makeController([entry('Design')]);
      await pumpPanel(tester, controller);
      final row = find.byKey(
        ValueKey('chatRow-${ChatEntryId.local('Design')}'),
      );
      final pin = find.byKey(
        ValueKey('chatPin-${ChatEntryId.local('Design')}'),
      );
      final avatar = find.byKey(
        ValueKey('chatAvatar-${ChatEntryId.local('Design')}'),
      );
      Container avatarContainer() => tester.widget<Container>(
        find.descendant(of: avatar, matching: find.byType(Container)),
      );
      final avatarColorBefore =
          (avatarContainer().decoration! as BoxDecoration).color;
      // The NEUTRAL glyph (owner pass): a surface2 rounded square with the
      // ink3 chat bubble — no letter, no hue, on every selection state.
      expect(
        find.descendant(of: avatar, matching: find.byType(Text)),
        findsNothing,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: avatar, matching: find.byType(Icon)),
            )
            .icon,
        Icons.chat_bubble_outline,
      );
      expect(pin, findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      expect(pin, findsOneWidget);

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await pumpPanel(
        tester,
        controller,
        selectedEntryId: ChatEntryId.local('Design'),
      );
      final context = tester.element(row);
      final material = tester.widget<Material>(row);
      expect(material.color, Theme.of(context).colorScheme.primary);
      expect(material.color, const Color(0xFF3F8FF7));
      final avatarAfter = avatarContainer();
      expect(
        (avatarAfter.decoration! as BoxDecoration).color,
        avatarColorBefore,
      );
      // Still the glyph — the selection never paints letters back in.
      expect(
        find.descendant(of: avatar, matching: find.byType(Text)),
        findsNothing,
      );
      expect(pin, findsNothing);
    },
  );

  testWidgets('network channel rows carry the neutral tag glyph', (
    tester,
  ) async {
    final controller = await makeController(
      const [],
      network: FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'general',
            title: 'General',
            unreadCount: 3,
          ),
        ],
      ),
    );
    await pumpPanel(tester, controller);
    final avatar = find.byKey(
      ValueKey(
        'chatAvatar-${ChatEntryId.network(ChatListEntryKind.networkChannel, networkId: 'remote', id: 'general')}',
      ),
    );
    expect(avatar, findsOneWidget);
    expect(tester.getSize(avatar), const Size.square(42));
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: avatar, matching: find.byType(Icon)),
          )
          .icon,
      Icons.tag_rounded,
    );
    expect(
      find.descendant(of: avatar, matching: find.byType(Text)),
      findsNothing,
      reason: 'no letters, no hue on channel rows',
    );
  });

  testWidgets('network filter is independent and does not open a chat', (
    tester,
  ) async {
    final controller = await makeController(
      [entry('Local')],
      network: FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'remote',
            title: 'Remote',
            unreadCount: 0,
          ),
        ],
      ),
    );
    var opened = 0;
    await pumpPanel(tester, controller, onOpen: (_) async => opened++);
    await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote team').last);
    await tester.pumpAndSettle();
    expect(controller.networkFilter, const ChatNetworkFilter.network('remote'));
    expect(find.text('Local'), findsNothing);
    expect(find.text('Remote'), findsOneWidget);
    expect(opened, 0);
  });

  testWidgets(
    'Local destination shows local folders and excludes network rows',
    (tester) async {
      final controller = await makeController(
        [
          entry(
            'Agent one',
            folderName: 'project',
            folderPath: '/work/project',
          ),
          entry(
            'Agent two',
            folderName: 'project',
            folderPath: '/work/project',
          ),
        ],
        network: FixtureNetworkInboxAdapter(
          items: [
            NetworkInboxItem(
              kind: ChatListEntryKind.networkAgent,
              networkId: 'remote',
              id: 'remote-agent',
              title: 'Remote agent',
            ),
          ],
        ),
      );
      await pumpPanel(tester, controller);

      await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local').last);
      await tester.pumpAndSettle();

      expect(controller.networkFilter, const ChatNetworkFilter.my());
      expect(
        find.byKey(const ValueKey('chatFolder-folder::/work/project')),
        findsOneWidget,
      );
      expect(find.text('Agent one'), findsNothing);
      expect(find.text('Agent two'), findsNothing);
      expect(find.text('Remote agent'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('chatFolder-folder::/work/project')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Agent one'), findsOneWidget);
      expect(find.text('Agent two'), findsOneWidget);
    },
  );

  testWidgets('folder root row shares conversation metrics and avatar badge', (
    tester,
  ) async {
    for (final compact in [false, true]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final agent = entry(
        'Agent one',
        folderName: 'project',
        folderPath: '/work/project',
      );
      final conversation = entry('General');
      final controller = await makeController([agent, conversation]);
      await pumpPanel(tester, controller, compact: compact);
      await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local').last);
      await tester.pumpAndSettle();
      final folder = find.byKey(
        const ValueKey('chatFolder-folder::/work/project'),
      );
      final channel = find.byKey(ValueKey('chatRow-${conversation.id}'));
      expect(folder, findsOneWidget);
      expect(channel, findsOneWidget);
      expect(tester.getSize(folder), tester.getSize(channel));
      final folderAvatar = find.descendant(
        of: folder,
        matching: find.byKey(ValueKey('chatFolderAvatar-${agent.id}')),
      );
      final channelAvatar = find.descendant(
        of: channel,
        matching: find.byKey(ValueKey('chatAvatar-${conversation.id}')),
      );
      expect(tester.getSize(folderAvatar), const Size.square(42));
      expect(tester.getSize(channelAvatar), const Size.square(42));
      // Folder destinations keep their letter identity; conversation rows
      // carry the neutral glyph instead.
      expect(
        find.descendant(of: folderAvatar, matching: find.byType(Text)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: channelAvatar, matching: find.byType(Icon)),
            )
            .icon,
        Icons.chat_bubble_outline,
      );
      final badge = find.descendant(
        of: folder,
        matching: find.byKey(ValueKey('chatFolderBadge-${agent.id}')),
      );
      expect(badge, findsOneWidget);
      expect(tester.getSize(badge), const Size.square(17));
      expect(
        tester.getTopLeft(badge).dx,
        lessThan(tester.getRect(folderAvatar).right),
      );
      expect(
        tester.getRect(badge).bottom,
        greaterThan(tester.getRect(folderAvatar).bottom - 2),
      );
      expect(
        find.descendant(of: folder, matching: find.byIcon(Icons.chevron_right)),
        findsNothing,
      );
      expect(find.text('/work/project'), findsOneWidget);
      // The row already shows the full path; a hover tooltip would only
      // duplicate that visible text.
      expect(
        find.ancestor(of: folder, matching: find.byType(Tooltip)),
        findsNothing,
      );
      await tester.tap(folder);
      await tester.pumpAndSettle();
      final currentFolder = find.byKey(const ValueKey('chatCurrentFolder'));
      expect(currentFolder, findsOneWidget);
      expect(
        find.ancestor(of: currentFolder, matching: find.byType(Tooltip)),
        findsNothing,
      );
      expect(find.text('Agent one'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'compact=$compact');
    }
  });

  testWidgets('empty conversation, filter, and search states are distinct', (
    tester,
  ) async {
    final empty = await makeController(const []);
    await pumpPanel(tester, empty);
    expect(find.text('No chats yet'), findsOneWidget);

    final controller = await makeController([entry('Design')]);
    await pumpPanel(tester, controller);
    await tester.tap(find.byKey(const ValueKey('chatFilter-channels')));
    await tester.pumpAndSettle();
    expect(find.text('No channels match this filter.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    // The ONE search field is the kit's GlassTextField — type through its
    // CupertinoTextField (an EditableText descendant, so enterText works).
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'not-present',
    );
    // The ONE shared search field applies the query after its 150ms
    // debounce — advance past it.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('No chats match your search.'), findsOneWidget);
  });

  testWidgets('logged-out network menu exposes the real sign-in dialog', (
    tester,
  ) async {
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.addNetwork(networkId: 'remote', name: 'Remote team');
    final manager = NetworkSessionManager(
      baseUrl: Uri.parse('https://example.test'),
      wallet: wallet,
      httpClient: FakeHttpClient(),
    );
    final controller = await makeController(const []);
    await pumpPanel(tester, controller, networkManager: manager);

    await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
    await tester.pumpAndSettle();
    expect(find.text('Manage networks'), findsOneWidget);
    await tester.tap(find.text('Sign in to Fa Network'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SignInDialog), findsOneWidget);
    manager.dispose();
  });

  testWidgets('Cmd/Ctrl+F focuses search and Q respects typing and modals', (
    tester,
  ) async {
    final controller = await makeController([entry('Design')]);
    var newCount = 0;
    await pumpPanel(tester, controller, onNew: () => newCount++);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.binding.focusManager.primaryFocus?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    expect(newCount, 0);
    await tester.tap(find.text('Design'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    expect(newCount, 1);

    showDialog<void>(
      context: tester.element(find.byType(ChatListPanel)),
      builder: (_) => const AlertDialog(title: Text('Modal')), // l10n:ignore
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    expect(newCount, 1);
  });

  testWidgets(
    'local folders drill into full paths without old expand behavior',
    (tester) async {
      final network = FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'remote',
            title: 'Network row',
            unreadCount: 0,
          ),
        ],
      );
      final controller = await makeController([
        entry('One agent', folderName: 'project', folderPath: '/one/project'),
        entry('One helper', folderName: 'project', folderPath: '/one/project'),
        entry('Two agent', folderName: 'project', folderPath: '/two/project'),
      ], network: network);
      var parentToggles = 0;
      var opened = 0;
      await pumpPanel(
        tester,
        controller,
        onOpen: (_) async => opened++,
        onToggleParent: (_, _) => parentToggles++,
      );

      const oneFolder = ValueKey('chatFolder-folder::/one/project');
      const twoFolder = ValueKey('chatFolder-folder::/two/project');
      expect(find.byKey(oneFolder), findsOneWidget);
      expect(find.byKey(twoFolder), findsOneWidget);
      expect(find.text('One agent'), findsNothing);
      expect(find.text('One helper'), findsNothing);
      expect(find.text('Two agent'), findsNothing);
      expect(find.text('Network row'), findsOneWidget);

      await tester.tap(find.byKey(oneFolder));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatCurrentFolder')), findsOneWidget);
      // Telegram-style drill-down: the '<' header names the FOLDER (the
      // full path is visible on the destination row at root).
      expect(find.text('project'), findsOneWidget);
      expect(find.text('/one/project'), findsNothing);
      expect(
        find.byKey(const ValueKey('chatSidebarLocalBack')),
        findsOneWidget,
      );
      // The folder's Telegram session rows: newest first, flat — the old
      // expand affordances are gone from the drill-down.
      final oneAgent = tester.getRect(find.text('One agent'));
      final oneHelper = tester.getRect(find.text('One helper'));
      expect(oneAgent.top, lessThan(oneHelper.top));
      expect(oneAgent.left, oneHelper.left);
      expect(
        find.byKey(const ValueKey('chatTreeToggle-local:One agent')),
        findsNothing,
      );
      expect(find.text('Two agent'), findsNothing);
      expect(find.text('Network row'), findsNothing);
      expect(parentToggles, 0);

      await tester.tap(find.text('One agent'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.byKey(const ValueKey('chatCurrentFolder')), findsOneWidget);
      expect(find.text('project'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chatSidebarLocalBack')));
      await tester.pumpAndSettle();
      expect(find.byKey(oneFolder), findsOneWidget);
      expect(find.byKey(twoFolder), findsOneWidget);
      expect(find.text('Network row'), findsOneWidget);
      expect(network.fetchCount, 1);
    },
  );

  testWidgets('folder retains the offline agent to subagent tree', (
    tester,
  ) async {
    final controller = await makeController([
      entry('Parent agent', folderName: 'project', folderPath: '/work/project'),
      entry(
        'Child agent',
        folderName: 'project',
        folderPath: '/work/project',
        parentId: 'Parent agent',
        isSubagent: true,
      ),
    ]);

    await pumpPanel(tester, controller);
    expect(controller.networkStatus, ChatLoadState.empty);
    await tester.tap(
      find.byKey(const ValueKey('chatFolder-folder::/work/project')),
    );
    await tester.pumpAndSettle();
    // The Telegram drill-down lists the folder's own sessions; the
    // subagent is not a folder session.
    expect(find.text('Parent agent'), findsOneWidget);
    expect(find.text('Child agent'), findsNothing);

    // Back to the normal list: the folder destination survives (both rows
    // stay in the projection — nothing was dropped), grouped as one
    // destination with the parent on top.
    expect(
      controller.visibleEntries.map((e) => e.id.value),
      containsAll(['Parent agent', 'Child agent']),
    );
    await tester.tap(find.byKey(const ValueKey('chatSidebarLocalBack')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chatFolder-folder::/work/project')),
      findsOneWidget,
    );
  });

  testWidgets('desktop brand matches the native profile button and clears '
      'the macOS titlebar vertically', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = await makeController([entry('Design')]);
    await pumpPanel(tester, controller);

    // The canonical 30px vector identity, not a hand-drawn text circle.
    final brand = find.byKey(const ValueKey('wideShellFaBrand'));
    expect(
      find.descendant(of: brand, matching: find.byType(FaLogo)),
      findsOneWidget,
    );
    expect(find.text('Fa'), findsNothing);
    expect(tester.getSize(brand), const Size(30, 30));
    expect(tester.getRect(brand).top, greaterThanOrEqualTo(46));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('expanded child is visually indented and folder label is not '
      'repeated in every row', (tester) async {
    final controller = await makeController([
      entry('Parent agent', folderName: 'project', folderPath: '/work/project'),
      entry(
        'Child agent',
        folderName: 'project',
        folderPath: '/work/project',
        parentId: 'Parent agent',
        isSubagent: true,
      ),
    ]);
    await pumpPanel(
      tester,
      controller,
      expandedParents: const {'Parent agent'},
      selectedEntryId: ChatEntryId.local('Parent agent'),
    );
    await tester.tap(
      find.byKey(const ValueKey('chatFolder-folder::/work/project')),
    );
    await tester.pumpAndSettle();

    // The Telegram-style drill-down is FLAT: the folder name lives in the
    // '<' header only, and the subagent is not a folder session (it stays
    // under its parent in the root tree).
    expect(find.text('project'), findsOneWidget);
    expect(find.text('Parent agent'), findsOneWidget);
    expect(find.text('Child agent'), findsNothing);
    expect(
      find.byKey(
        ValueKey('chatTreeToggle-${ChatEntryId.local('Parent agent')}'),
      ),
      findsNothing,
      reason: 'no tree affordances inside the Telegram drill-down',
    );
    final row = tester.getRect(
      find.byKey(ValueKey('localSession-Parent agent')),
    );
    expect(row.height, 70);
  });

  testWidgets('compact scaffold uses text-led navigation hooks and FAB host', (
    tester,
  ) async {
    final controller = await makeController([entry('Design')]);
    await pumpPanel(tester, controller, compact: true);
    expect(find.byType(FaLogo), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkFilter')), findsOneWidget);
    expect(find.text('Design'), findsOneWidget);
  });

  testWidgets(
    'filter pill animates both directions without duplicate actions',
    (tester) async {
      const labels = ['All', 'Unread', 'Agents', 'Channels'];
      for (final compact in [false, true]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        final controller = await makeController([entry('Design')]);
        await pumpPanel(tester, controller, compact: compact);

        Future<void> verify(ChatListFilter from, ChatListFilter to) async {
          final pill = find.byKey(const ValueKey('chatFilterSelectionPill'));
          final start = tester.getRect(pill);
          var notifications = 0;
          void listener() => notifications++;
          controller.addListener(listener);
          await tester.tap(find.byKey(ValueKey('chatFilter-${to.name}')));
          await tester.pump();
          expect(controller.filter, to);
          expect(notifications, 1);
          final forward = to.index > from.index;
          var previous = start;
          for (final milliseconds in [0, 50, 100, 200]) {
            if (milliseconds > 0) {
              await tester.pump(
                Duration(milliseconds: milliseconds == 200 ? 100 : 50),
              );
            }
            final current = tester.getRect(pill);
            expect(
              current.height,
              32,
              reason: 'compact=$compact $milliseconds',
            );
            expect(current.width, closeTo(start.width, .001));
            expect(
              forward
                  ? current.left >= previous.left
                  : current.left <= previous.left,
              isTrue,
              reason: 'compact=$compact $from->$to $milliseconds',
            );
            expect(tester.takeException(), isNull);
            if (milliseconds == 50) {
              final opacities = tester.widgetList<Opacity>(
                find.descendant(
                  of: find.byType(MessengerFilterControl),
                  matching: find.byType(Opacity),
                ),
              );
              expect(
                opacities
                    .where(
                      (opacity) => opacity.opacity > 0 && opacity.opacity < 1,
                    )
                    .length,
                greaterThanOrEqualTo(2),
              );
            }
            previous = current;
          }
          controller.removeListener(listener);
          for (var index = 0; index < labels.length; index++) {
            expect(
              find.text(labels[index]),
              index == to.index ? findsOneWidget : findsNothing,
            );
          }
        }

        await verify(ChatListFilter.all, ChatListFilter.channels);
        await verify(ChatListFilter.channels, ChatListFilter.all);
        await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
        await tester.pumpAndSettle();
        expect(controller.filter, ChatListFilter.all);
        expect(find.text('All networks'), findsOneWidget);
        expect(find.text('Local'), findsOneWidget);
      }
    },
  );
}
