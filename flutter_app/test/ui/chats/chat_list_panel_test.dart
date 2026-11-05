import 'dart:convert';

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
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa/ui/widgets/subagent_mark.dart';
import 'package:fa_ui/fa_ui.dart' show FaLogo, FaVisualDirection, buildFaTheme;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../network/fakes.dart';

final _tinyPng = Uint8List.fromList(
  base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

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
  bool isStreaming = false,
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
  isStreaming: isStreaming,
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
  FolderIconResolver? iconResolver,
  ChatEntryId? selectedEntryId,
  bool showFilterToolbar = true,
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
            onOpen: onOpen ?? (_) async {},
            onNew: onNew ?? () {},
            networkManager: networkManager,
            iconResolver: iconResolver,
            showFilterToolbar: showFilterToolbar,
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

  testWidgets(
    'wide macOS chrome starts at the top without titlebar clearance',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final controller = await makeController([entry('Design')]);
      await pumpPanel(tester, controller, showFilterToolbar: false);

      final search = tester.getRect(
        find.byKey(const ValueKey('messengerSearchField')),
      );
      final newButton = find.byKey(const ValueKey('messengerNewButton'));
      expect(search.top, 10);
      expect(tester.getRect(newButton).top, 10);
      expect(search.center.dy, 26);
      expect(
        search.center.dy,
        closeTo(tester.getRect(newButton).center.dy, .001),
      );
      final firstRow = tester.getRect(
        find.byKey(ValueKey('chatRow-${ChatEntryId.local('Design')}')),
      );
      expect(
        firstRow.top - search.bottom,
        14,
        reason: 'the first row clears the search border before its glass fade',
      );
      final button = tester.widget<IconButton>(newButton);
      expect(button.color, Colors.white);
      expect(
        button.style?.backgroundColor?.resolve(const <WidgetState>{}),
        const Color(0xFF3F8FF7),
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'selected rows use the accent and hover reveals desktop actions',
    (tester) async {
      final controller = await makeController([
        entry('Design', folderName: 'project', folderPath: '/work/project'),
      ]);
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
      FolderAvatar folderAvatar() => tester.widget<FolderAvatar>(
        find.descendant(of: avatar, matching: find.byType(FolderAvatar)),
      );
      final avatarBefore = folderAvatar();
      expect(avatarBefore.seed, '/work/project');
      expect(avatarBefore.label, 'project');
      expect(avatarBefore.size, 42);
      expect(avatarBefore.circle, isTrue);
      expect(find.descendant(of: avatar, matching: find.text('P')), findsOne);
      final badge = find.descendant(
        of: avatar,
        matching: find.byKey(const ValueKey('chatAvatarFolderBadge')),
      );
      expect(badge, findsOneWidget);
      expect(tester.getSize(badge), const Size.square(18));
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: badge, matching: find.byType(Icon)),
            )
            .icon,
        Icons.chat_bubble_outline,
      );
      expect(pin, findsNothing);
      expect(
        tester.widget<Material>(row).color,
        Colors.transparent,
        reason: 'unselected All rows share the Local/Networks hover base',
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      expect(pin, findsOneWidget);
      expect(
        tester.widget<Material>(row).color,
        Colors.transparent,
        reason: 'hover rides the same InkWell treatment as Local/Networks',
      );

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
      final avatarAfter = folderAvatar();
      expect(avatarAfter.seed, avatarBefore.seed);
      expect(avatarAfter.label, avatarBefore.label);
      expect(avatarAfter.circle, avatarBefore.circle);
      expect(badge, findsOneWidget);
      expect(pin, findsNothing);
    },
  );

  testWidgets('network channel rows use the wallet network avatar and badge', (
    tester,
  ) async {
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.addNetwork(networkId: 'remote', name: 'Wallet team');
    final manager = NetworkSessionManager(
      baseUrl: Uri.parse('https://example.test'),
      wallet: wallet,
      httpClient: FakeHttpClient(),
    );
    addTearDown(manager.dispose);
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
    await pumpPanel(tester, controller, networkManager: manager);
    final avatar = find.byKey(
      ValueKey(
        'chatAvatar-${ChatEntryId.network(ChatListEntryKind.networkChannel, networkId: 'remote', id: 'general')}',
      ),
    );
    expect(avatar, findsOneWidget);
    expect(tester.getSize(avatar), const Size.square(42));
    final networkAvatar = tester.widget<FolderAvatar>(
      find.descendant(of: avatar, matching: find.byType(FolderAvatar)),
    );
    expect(networkAvatar.seed, 'remote');
    expect(networkAvatar.label, 'Wallet team');
    expect(networkAvatar.circle, isTrue);
    expect(find.descendant(of: avatar, matching: find.text('W')), findsOne);
    final badge = find.descendant(
      of: avatar,
      matching: find.byKey(const ValueKey('chatAvatarChannelBadge')),
    );
    expect(badge, findsOneWidget);
    expect(tester.getSize(badge), const Size.square(18));
    final badgeIcon = tester.widget<Icon>(
      find.descendant(of: badge, matching: find.byType(Icon)),
    );
    expect(badgeIcon.icon, Icons.tag_rounded);
    expect(badgeIcon.size, 12);
  });

  testWidgets('folder icon resolution is shared with Local folder rows', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile('/project/icon.png', _tinyPng);
    final resolver = FolderIconResolver(
      env,
      hostToMountPath: (folderId) =>
          folderId == '/work/project' ? '/project' : null,
    );
    final controller = await makeController([
      entry('Design', folderName: 'project', folderPath: '/work/project'),
    ]);

    await pumpPanel(tester, controller, iconResolver: resolver);

    final avatar = find.byKey(
      ValueKey('chatAvatar-${ChatEntryId.local('Design')}'),
    );
    final folderAvatar = tester.widget<FolderAvatar>(
      find.descendant(of: avatar, matching: find.byType(FolderAvatar)),
    );
    expect(folderAvatar.image, isA<MemoryImage>());
    expect((folderAvatar.image! as MemoryImage).bytes, _tinyPng);
    expect(
      find.descendant(of: avatar, matching: find.byType(Image)),
      findsOneWidget,
    );
  });

  testWidgets('narrow rows keep semantic avatars, badges, and running state', (
    tester,
  ) async {
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.addNetwork(networkId: 'remote', name: 'Remote team');
    final manager = NetworkSessionManager(
      baseUrl: Uri.parse('https://example.test'),
      wallet: wallet,
      httpClient: FakeHttpClient(),
    );
    addTearDown(manager.dispose);
    final controller = await makeController(
      [
        entry(
          'Design',
          folderName: 'project',
          folderPath: '/work/project',
          isStreaming: true,
        ),
      ],
      network: FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'general',
            title: 'General',
          ),
        ],
      ),
    );

    await pumpPanel(tester, controller, compact: true, networkManager: manager);

    final localAvatar = find.byKey(
      ValueKey('chatAvatar-${ChatEntryId.local('Design')}'),
    );
    final channelAvatar = find.byKey(
      ValueKey(
        'chatAvatar-${ChatEntryId.network(ChatListEntryKind.networkChannel, networkId: 'remote', id: 'general')}',
      ),
    );
    expect(tester.getSize(localAvatar), const Size.square(42));
    expect(tester.getSize(channelAvatar), const Size.square(42));
    expect(
      find.descendant(of: localAvatar, matching: find.byType(FolderAvatar)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: channelAvatar, matching: find.byType(FolderAvatar)),
      findsOneWidget,
    );
    final folderBadge = find.byKey(const ValueKey('chatAvatarFolderBadge'));
    final channelBadge = find.byKey(const ValueKey('chatAvatarChannelBadge'));
    expect(folderBadge, findsOneWidget);
    expect(channelBadge, findsOneWidget);
    final running = find.descendant(
      of: localAvatar,
      matching: find.byType(ChatRunningDot),
    );
    expect(running, findsOneWidget);
    expect(
      tester.getRect(running).overlaps(tester.getRect(folderBadge)),
      isFalse,
      reason:
          'the type badge and running indicator must not obscure each other',
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

  testWidgets('the All home is ONE flat active list — sessions and channels by '
      'last activity, no folder grouping, no sections, no tree', (
    tester,
  ) async {
    final reads = ChatReadCursorStore.inMemory(accountId: 'a');
    final controller = await makeController(
      [
        entry('Oldest session', folderName: 'project', folderPath: '/work'),
        entry('Middle session'),
        entry('Child agent', parentId: 'Middle session', isSubagent: true),
      ],
      network: FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'channel',
            title: 'Network channel',
            lastActivity: DateTime.utc(2026, 1, 3),
            unreadCount: 2,
          ),
        ],
      ),
      reads: reads,
    );
    await pumpPanel(tester, controller);

    // One flat list: newest activity first, channels and sessions
    // interleaved by time (the channel carries Jan 3; local entries pin
    // Jan 2 — the channel leads, ties break by id). Subagent sessions
    // never render as flat rows: the projection is PARENTS ONLY, and a
    // parent with subagents carries the count chip instead.
    Rect rowOf(String title) => tester.getRect(find.text(title));
    final channel = rowOf('Network channel');
    final middle = rowOf('Middle session');
    final oldest = rowOf('Oldest session');
    expect(channel.top, lessThan(middle.top), reason: 'activity desc');
    expect(middle.top, lessThan(oldest.top));
    expect(
      find.text('Child agent'),
      findsNothing,
      reason: 'parents only — the subagent rides the parent chip',
    );
    expect(middle.left, oldest.left, reason: 'flat — same indent');

    // The parent row's chip counts its subagent sessions.
    final chip = find.byKey(const ValueKey('chatSubagentChip'));
    expect(chip, findsOneWidget);
    expect(find.descendant(of: chip, matching: find.text('1')), findsOneWidget);

    // NO folder grouping leaked into All.
    expect(
      find.byKey(const ValueKey('chatFolder-folder::/work')),
      findsNothing,
    );
    // NO pinned/recent multi-level sections.
    expect(find.text('Pinned'), findsNothing);
    expect(find.text('Recent'), findsNothing);
    // NO tree affordances.
    expect(
      find.byKey(const ValueKey('chatTreeToggle-local:Middle session')),
      findsNothing,
    );

    // Unread is the unread subset of the SAME flat list.
    await tester.tap(find.byKey(const ValueKey('chatFilter-unread')));
    await tester.pumpAndSettle();
    expect(find.text('Network channel'), findsOneWidget);
    expect(find.text('Oldest session'), findsNothing);
    expect(find.text('Middle session'), findsNothing);
    expect(find.text('Child agent'), findsNothing);
  });

  testWidgets(
    'Local network facet shows flat local agent rows and excludes network rows',
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
      // Same-cwd agents do NOT collapse into a folder destination on the
      // facet home — the flat list just shows the local rows.
      expect(
        find.byKey(const ValueKey('chatFolder-folder::/work/project')),
        findsNothing,
      );
      expect(find.text('Agent one'), findsOneWidget);
      expect(find.text('Agent two'), findsOneWidget);
      expect(find.text('Remote agent'), findsNothing);
    },
  );

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

  testWidgets('the All home renders parents only; the subagent stays on '
      'the parent chip, never as a flat row', (tester) async {
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
    // Parents only: the subagent never renders a flat row and carries no
    // inline mark on this surface — it lives behind the parent's chip.
    expect(find.text('Parent agent'), findsOneWidget);
    expect(find.text('Child agent'), findsNothing);
    expect(find.byType(SubagentMark), findsNothing);
    expect(
      find.byKey(const ValueKey('chatFolder-folder::/work/project')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('chatTreeToggle-local:Parent agent')),
      findsNothing,
    );
    // The parent row carries the neutral count chip.
    expect(find.byKey(const ValueKey('chatSubagentChip')), findsOneWidget);
  });

  testWidgets('the count chip is informational: tapping it opens the '
      'PARENT chat, never a subagent', (tester) async {
    final opened = <ChatListEntry>[];
    final controller = await makeController([
      entry('Parent agent', folderName: 'project', folderPath: '/work/project'),
      entry(
        'Child agent',
        folderName: 'project',
        folderPath: '/work/project',
        parentId: 'Parent agent',
        isSubagent: true,
        unread: 2,
      ),
    ]);

    await pumpPanel(tester, controller, onOpen: (e) async => opened.add(e));
    // The chip sits inside the row's own tap target: a tap on the chip is
    // a tap on the row — the parent chat opens.
    await tester.tap(find.byKey(const ValueKey('chatSubagentChip')));
    await tester.pumpAndSettle();
    expect(opened.single.id.value, 'Parent agent');
    expect(opened.single.isSubagent, isFalse);
    // No anchored picker appears — the switcher lives above the composer.
    expect(
      find.byKey(const ValueKey('chatSubagentEntry-Child agent')),
      findsNothing,
    );
  });

  testWidgets('compact (narrow) rows carry the same count chip', (
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
        unread: 2,
      ),
    ]);

    await pumpPanel(tester, controller, compact: true, width: 390);
    expect(find.text('Child agent'), findsNothing);
    expect(find.byKey(const ValueKey('chatSubagentChip')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatSubagentChip')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    // Rows without subagents carry no chip.
    expect(find.text('Parent agent'), findsOneWidget);
  });

  testWidgets('wide desktop brand keeps its size and top padding on macOS', (
    tester,
  ) async {
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
    expect(tester.getRect(brand).top, 11);
    debugDefaultTargetPlatformOverride = null;
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
