import 'dart:async';

import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

ChatListEntry local(
  String id, {
  required DateTime activity,
  int? unread = 0,
  int? messageCount,
  String? parentId,
  bool isSubagent = false,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  title: id,
  createdAt: activity.subtract(const Duration(days: 1)),
  lastActivity: activity,
  unreadCount: unread,
  localMessageCount: messageCount,
  parentId: parentId,
  isSubagent: isSubagent,
);

NetworkInboxItem remote(
  String id, {
  ChatListEntryKind kind = ChatListEntryKind.networkChannel,
  String networkId = 'remote',
  int? unreadCount,
  DateTime? activity,
}) => NetworkInboxItem(
  kind: kind,
  networkId: networkId,
  id: id,
  title: id,
  lastActivity: activity,
  unreadCount: unreadCount,
);

Future<ChatListController> controller(
  List<ChatListEntry> locals, {
  NetworkInboxAdapter? network,
  ChatPinStore? pins,
  ChatReadCursorStore? reads,
}) async {
  final result = ChatListController(
    localAdapter: StaticChatListAdapter(locals),
    networkAdapter: network,
    pinStore: pins,
    readCursorStore: reads,
    networkNames: const {'remote': 'Remote team', 'other': 'Other'},
  );
  await result.load();
  return result;
}

void main() {
  final t1 = DateTime.utc(2026, 1, 1, 10);
  final t2 = DateTime.utc(2026, 1, 2, 10);
  final t3 = DateTime.utc(2026, 1, 3, 10);

  test('networkChannelEntries lists every channel projection regardless '
      'of filters, scoped per network for the drill-down', () async {
    final c = await controller(
      [local('Local design', activity: t1)],
      network: FixtureNetworkInboxAdapter(
        items: [
          remote('Release channel', unreadCount: 2, activity: t3),
          remote(
            'Research agent',
            kind: ChatListEntryKind.networkAgent,
            activity: t2,
          ),
          remote('Other channel', networkId: 'other', unreadCount: 1),
        ],
      ),
    );
    // Filters never hide the projection's rows.
    c.setFilter(ChatListFilter.agents);
    c.setSearch('release');
    expect(
      c.networkChannelEntries.map((e) => e.title),
      ['Release channel', 'Other channel'],
    );
    expect(
      c.networkChannelEntries.where((e) => e.networkId == 'remote').map(
        (e) => e.title,
      ),
      ['Release channel'],
    );
    c.setSearch('');
    c.setFilter(ChatListFilter.all);
    expect(c.networkChannelEntries.length, 2);
  });

  test('kind, network, and search filters compose independently', () async {
    final c = await controller(
      [local('Local design', activity: t1)],
      network: FixtureNetworkInboxAdapter(
        items: [
          remote('Release channel', unreadCount: 2, activity: t3),
          remote(
            'Research agent',
            kind: ChatListEntryKind.networkAgent,
            activity: t2,
          ),
          remote('Other channel', networkId: 'other', unreadCount: 1),
        ],
      ),
    );

    expect(c.visibleEntries.map((e) => e.title), [
      'Release channel',
      'Research agent',
      'Local design',
      'Other channel',
    ]);
    c.setFilter(ChatListFilter.agents);
    expect(c.visibleEntries.map((e) => e.title), [
      'Research agent',
      'Local design',
    ]);
    c.setNetworkFilter(const ChatNetworkFilter.network('remote'));
    expect(c.visibleEntries.single.title, 'Research agent');
    c.setSearch('missing');
    expect(c.visibleEntries, isEmpty);
    c.setSearch('research');
    expect(c.visibleEntries.single.title, 'Research agent');
    c.setSearch('');
    c.setFilter(ChatListFilter.channels);
    expect(c.visibleEntries.single.title, 'Release channel');
    expect(c.networkFilter, const ChatNetworkFilter.network('remote'));
  });

  test(
    'Local filter keeps only local agents and their folder groups',
    () async {
      final c = await controller(
        [local('Local project agent', activity: t1)],
        network: FixtureNetworkInboxAdapter(
          items: [
            remote('Remote agent', kind: ChatListEntryKind.networkAgent),
            remote('My network agent', networkId: 'my'),
          ],
        ),
      );

      c.setNetworkFilter(const ChatNetworkFilter.my());

      expect(c.networkFilter, const ChatNetworkFilter.my());
      expect(c.visibleEntries.map((entry) => entry.title), [
        'Local project agent',
      ]);
    },
  );

  test('My filter retains local provider-only chats without auth', () async {
    final c = await controller(
      [local('Local only', activity: t1)],
      network: FixtureNetworkInboxAdapter(
        items: [remote('Remote', unreadCount: 1)],
      ),
    );
    c.setNetworkFilter(const ChatNetworkFilter.my());
    expect(c.visibleEntries.single.title, 'Local only');
  });

  test(
    'unread filter does not invent zero for unknown network agents',
    () async {
      final c = await controller(
        const [],
        network: FixtureNetworkInboxAdapter(
          items: [
            remote('Agent unknown', kind: ChatListEntryKind.networkAgent),
            remote('Channel read', unreadCount: 0),
            remote('Channel unread', unreadCount: 4),
          ],
        ),
      );
      expect(c.visibleEntries.first.unreadCount, isNull);
      c.setFilter(ChatListFilter.unread);
      expect(c.visibleEntries.single.title, 'Channel unread');
    },
  );

  test('Pinned then Recent, each ordered by activity', () async {
    final pins = ChatPinStore.inMemory(accountId: 'a');
    final c = await controller([
      local('old', activity: t1),
      local('new', activity: t3),
      local('middle', activity: t2),
    ], pins: pins);
    await c.togglePin(c.visibleEntries.firstWhere((e) => e.title == 'old'));
    expect(c.pinnedEntries.single.title, 'old');
    expect(c.recentEntries.map((e) => e.title), ['new', 'middle']);
    await c.togglePin(c.pinnedEntries.single);
    expect(c.pinnedEntries, isEmpty);
    expect(c.recentEntries.map((e) => e.title), ['new', 'middle', 'old']);
  });

  test(
    'successful local open advances read cursor and clears unread',
    () async {
      final reads = ChatReadCursorStore.inMemory(accountId: 'a');
      final entry = local('local', activity: t1, messageCount: 3);
      final c = await controller([entry], reads: reads);
      await c.markOpened(c.visibleEntries.single);
      expect(c.visibleEntries.single.unreadCount, 0);
      expect(reads.cursorFor(entry.id), 3);

      await c.replaceLocalEntries([
        local('local', activity: t2, messageCount: 6),
      ]);
      expect(c.visibleEntries.single.unreadCount, 3);
      await c.markOpened(c.visibleEntries.single);
      await c.markOpened(c.visibleEntries.single);
      expect(reads.cursorFor(entry.id), 6);
      expect(c.visibleEntries.single.unreadCount, 0);
    },
  );

  test(
    'network channel open uses aggregate read seam before clearing',
    () async {
      final fixture = FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'c1',
            title: 'Channel',
            unreadCount: 5,
            lastEnvelope: const NetworkEnvelopeRef(
              id: 'env-9',
              createdAt: '2026-01-01T00:00:00Z',
              senderId: 's',
              senderName: 'Sender',
              senderKey: 'key',
              payload: {'ciphertext': 'opaque'},
              mentions: [],
            ),
          ),
        ],
      );
      final c = await controller(const [], network: fixture);
      await c.markOpened(c.visibleEntries.single);
      expect(fixture.readCalls.single.envelopeId, 'env-9');
      expect(c.visibleEntries.single.unreadCount, 0);
    },
  );

  test(
    'unavailable network is an error with retry, never fake empty',
    () async {
      final fixture = FixtureNetworkInboxAdapter(
        error: const NetworkInboxUnavailableException('not connected'),
      );
      final c = await controller(const [], network: fixture);
      expect(c.networkStatus, ChatLoadState.error);
      expect(c.status, ChatLoadState.error);
      expect(c.visibleEntries, isEmpty);
      expect(c.networkError, contains('not connected'));

      fixture.error = null;
      fixture.items = [remote('Loaded', unreadCount: 0)];
      await c.retryNetwork();
      expect(c.networkStatus, ChatLoadState.data);
      expect(c.visibleEntries.single.title, 'Loaded');
      expect(fixture.fetchCount, 2);
    },
  );

  test('network adapter follows auth enable and disable', () async {
    final c = await controller([local('Local', activity: t1)]);
    expect(c.networkStatus, ChatLoadState.empty);

    await c.replaceNetworkAdapter(
      FixtureNetworkInboxAdapter(items: [remote('Remote', activity: t2)]),
    );
    expect(c.networkStatus, ChatLoadState.data);
    expect(c.visibleEntries.map((e) => e.title), ['Remote', 'Local']);

    await c.replaceNetworkAdapter(null);
    expect(c.networkStatus, ChatLoadState.empty);
    expect(c.visibleEntries.single.title, 'Local');
  });

  test('disabling network invalidates an in-flight inbox response', () async {
    final adapter = _GatedNetworkAdapter();
    final c = await controller([local('Local', activity: t1)]);
    final pending = c.replaceNetworkAdapter(adapter);
    await c.replaceNetworkAdapter(null);
    adapter.response.complete(
      NetworkInboxPage(items: [remote('Stale remote', activity: t2)]),
    );
    await pending;

    expect(c.networkStatus, ChatLoadState.empty);
    expect(c.visibleEntries.single.title, 'Local');
  });

  test(
    'manager deletion refreshes search, filters, and network composition',
    () async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        includeSharedSessionRoots: false,
      );
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      for (final (id, cwd) in const [
        ('deleted', '/work/project'),
        ('survivor', '/work/project'),
        ('other', '/elsewhere'),
      ]) {
        await repo.create(JsonlSessionCreateOptions(id: id, cwd: cwd));
      }
      final network = FixtureNetworkInboxAdapter(
        items: [remote('Network stays', unreadCount: 1)],
      );
      final c = ChatListController(
        localAdapter: LocalChatListAdapter(
          manager: manager,
          titleBuilder: (id, createdAt, isSubagent) => id,
        ),
        networkAdapter: network,
      );
      await c.load();
      c.setNetworkFilter(const ChatNetworkFilter.my());
      c.setFilter(ChatListFilter.agents);
      c.setSearch('deleted');
      expect(c.visibleEntries.map((entry) => entry.id.value), ['deleted']);
      await c.togglePin(c.visibleEntries.single);
      expect(c.pinnedEntries.map((entry) => entry.id.value), ['deleted']);

      await manager.deleteSession('deleted');
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(c.visibleEntries, isEmpty);
      expect(c.pinnedEntries, isEmpty);
      c.setSearch('');
      expect(c.visibleEntries, hasLength(2));
      expect(
        c.visibleEntries.map((entry) => entry.id.value),
        containsAll(<String>['other', 'survivor']),
      );
      c.setNetworkFilter(const ChatNetworkFilter.all());
      c.setFilter(ChatListFilter.all);
      expect(
        c.visibleEntries.map((entry) => entry.id.value),
        contains('Network stays'),
      );
      expect(
        c.visibleEntries.map((entry) => entry.id.value),
        isNot(contains('deleted')),
      );
    },
  );

  test('a manager notify mid-load coalesces into one queued reload — '
      'the in-flight emission is never dropped', () async {
    final entry = local('parent', activity: DateTime.utc(2026, 1, 2));
    final gate = Completer<void>();
    final source = _ManualChangeSource([entry], gate);
    final c = ChatListController(localAdapter: source);
    final loading = c.load();
    await _until(() => source.started >= 1);

    // The runtime race: the manager's lazy name/preview fills notify
    // WHILE the projection load is in flight. It must queue exactly one
    // reload, not supersede (drop) the in-flight pass.
    source.notify();
    gate.complete();
    await loading;

    expect(
      c.localEntries.map((e) => e.id.value),
      contains('parent'),
      reason: 'load() settles with rows even though a notify landed mid-air',
    );
    await _until(() => source.started >= 2);
    source.release();
    await _until(() => source.completed >= 2);
    expect(
      source.started,
      2,
      reason: 'exactly ONE coalesced reload follows — no duplicate passes',
    );
    expect(c.localEntries, isNotEmpty);
  });

  test('the first local emission logs the listing stopwatch (AppLog)',
      () async {
    AppLog.reset();
    addTearDown(AppLog.reset);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    );
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await repo.create(
      const JsonlSessionCreateOptions(id: 'parent', cwd: '/work'),
    );
    final c = ChatListController(
      localAdapter: LocalChatListAdapter(
        manager: manager,
        titleBuilder: (id, createdAt, isSubagent) => id,
      ),
    );
    await c.load();

    expect(AppLog.dump(), contains('[chats]'));
    expect(AppLog.dump(), contains('first emission'));
  });

  group('subagent projection (subagent sessions owner pass)', () {
    ChatListEntry entryOf(ChatListController c, String title) =>
        c.facetEntries.firstWhere((e) => e.title == title);

    test('subagentsByParent groups subagent rows by their parent id', () async {
      final c = await controller([
        local('Main session', activity: t3, messageCount: 2),
        local(
          'child-a',
          activity: t2,
          parentId: 'Main session',
          isSubagent: true,
        ),
        local(
          'child-b',
          activity: t1,
          parentId: 'Main session',
          isSubagent: true,
        ),
        local(
          'other-child',
          activity: t1,
          parentId: 'Other parent',
          isSubagent: true,
        ),
      ]);
      expect(c.subagentsByParent.keys.toSet(), {
        'Main session',
        'Other parent',
      });
      // Per-parent rows keep the activity-descending projection order.
      expect(c.subagentEntriesFor('Main session').map((e) => e.title), [
        'child-a',
        'child-b',
      ]);
      expect(c.subagentEntriesFor('Other parent').map((e) => e.title), [
        'other-child',
      ]);
      expect(c.subagentEntriesFor('unknown'), isEmpty);
      // The parent row carries the count; non-parents carry none.
      expect(c.subagentCountFor(entryOf(c, 'Main session')), 2);
      expect(c.subagentCountFor(entryOf(c, 'child-a')), 0);
    });

    test('rows without a parent id never join the grouping', () async {
      final c = await controller([
        local('Main session', activity: t3),
        local('orphan', activity: t2, isSubagent: true),
      ]);
      expect(c.subagentsByParent, isEmpty);
      expect(c.subagentEntriesFor('Main session'), isEmpty);
      expect(c.subagentCountFor(entryOf(c, 'Main session')), 0);
    });

    test('network rows never join the grouping', () async {
      final c = await controller(
        [local('Local design', activity: t1)],
        network: FixtureNetworkInboxAdapter(
          items: [remote('Release channel', unreadCount: 2, activity: t3)],
        ),
      );
      expect(c.subagentsByParent, isEmpty);
    });

    test('subagent rows ride the read-cursor projection (picker unread)',
        () async {
      final reads = ChatReadCursorStore.inMemory(accountId: 'a');
      final c = await controller(
        [
          local('Main session', activity: t3, messageCount: 1),
          local(
            'child-a',
            activity: t2,
            parentId: 'Main session',
            isSubagent: true,
            messageCount: 5,
          ),
        ],
        reads: reads,
      );
      await reads.markRead(ChatEntryId.local('child-a'), 2);
      final child = c.subagentEntriesFor('Main session').single;
      expect(child.unreadCount, 3);
      expect(child.isSubagent, isTrue);
      expect(child.parentId, 'Main session');
    });

    test('the grouping ignores the active search and kind filters', () async {
      final c = await controller([
        local('Main session', activity: t3),
        local('child-a', activity: t2, parentId: 'Main session', isSubagent: true),
      ]);
      c.setSearch('child');
      expect(c.subagentEntriesFor('Main session'), hasLength(1));
      c.setFilter(ChatListFilter.unread);
      expect(c.subagentsByParent['Main session'], hasLength(1));
    });
  });
}

/// Waits (bounded) until [condition] holds, pumping the event loop.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition never settled');
}

/// Counts load starts/completions; holds the first on a gate and the
/// second on a release so the test can pin the coalescing behavior.
final class _ManualChangeSource implements LocalChatListChangeSource {
  _ManualChangeSource(this.entries, this._gate);

  final List<ChatListEntry> entries;
  final Completer<void> _gate;
  final Completer<void> _release = Completer<void>();
  final _Sink _sink = _Sink();
  int started = 0;
  int completed = 0;

  @override
  Listenable get changes => _sink;

  void notify() => _sink.notify();

  void release() => _release.complete();

  @override
  Future<List<ChatListEntry>> load() async {
    started++;
    if (started == 1) await _gate.future;
    if (started == 2) await _release.future;
    completed++;
    return List.of(entries);
  }
}

final class _Sink extends ChangeNotifier {
  void notify() => notifyListeners();
}

final class _GatedNetworkAdapter implements NetworkInboxAdapter {
  final response = Completer<NetworkInboxPage>();

  @override
  Future<NetworkInboxPage> fetchInbox({
    int? limit,
    String? cursor,
    Set<ChatListEntryKind>? kinds,
  }) => response.future;

  @override
  Future<void> markChannelRead(
    String channelId, {
    int? seq,
    String? envelopeId,
    bool all = false,
  }) async {}
}
