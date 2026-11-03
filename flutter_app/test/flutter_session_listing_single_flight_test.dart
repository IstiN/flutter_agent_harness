// Issue #2053 AC4/AC5 — app-boot session listing: names off the boot path
// (lazy, bounded fill) and one shared in-flight listing pass.
//
// The store classes are `final` on purpose, so the counters are seams, not
// subclasses: the repo's `debugOnListingPass` hook counts real listing
// passes and `debugOnNameProbe` counts the 2 MiB session_info window
// probes AC4 keeps off the boot path. (The strict fake-FS window-read
// counting lives in the core suite, test/session_listing_index_test.dart;
// here the adapter's pre-existing preview windows would pollute a raw
// readRange count.)
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory store with the two issue-#2053 op counters wired.
final class _Store {
  _Store() {
    repo.debugOnNameProbe = (metadata) => probes.add(metadata.id);
    var listings = 0;
    listingCount = () => listings;
    repo.debugOnListingPass = () => listings++;
  }

  final MemoryExecutionEnv env = MemoryExecutionEnv(cwd: '/');
  late final JsonlSessionRepo repo = JsonlSessionRepo(
    fs: env,
    sessionsRoot: '/sessions',
  );
  final probes = <String>[];
  late final int Function() listingCount;
}

void main() {
  test('AC5 — two concurrent loads share ONE repo listing', () async {
    final store = _Store();
    final manager = FlutterSessionManager(
      env: store.env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
      repo: store.repo,
    );
    for (var i = 0; i < 3; i++) {
      await store.repo.create(
        JsonlSessionCreateOptions(id: 's-$i', cwd: '/work'),
      );
    }

    // The boot race: adapter load + shell reload + a stray caller, all at
    // once — exactly the duplicated ~10s pass the incident measured.
    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
    );
    final results = await Future.wait([
      manager.listPersistedSessions(),
      manager.listPersistedSessions(),
      adapter.load(),
    ]);

    expect(results[0], hasLength(3));
    expect(results[2], hasLength(3));
    expect(store.listingCount(), 1,
        reason: 'AC5: one repo listing, shared');

    // Sequential loads still re-list (freshness contract preserved).
    await manager.listPersistedSessions();
    expect(store.listingCount(), 2);
  });

  test('AC5 — invalidation forces a fresh pass after a delete', () async {
    final store = _Store();
    final manager = FlutterSessionManager(
      env: store.env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
      repo: store.repo,
    );
    await store.repo.create(
      const JsonlSessionCreateOptions(id: 'victim', cwd: '/work'),
    );
    await store.repo.create(
      const JsonlSessionCreateOptions(id: 'survivor', cwd: '/work'),
    );
    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
    );
    expect((await adapter.load()).map((e) => e.id.value), contains('victim'));
    final before = store.listingCount();

    await manager.deleteSession('victim');

    final after = await adapter.load();
    expect(after.map((e) => e.id.value), isNot(contains('victim')));
    expect(store.listingCount(), greaterThan(before),
        reason: 'the delete invalidated the shared pass');
  });

  test('AC4 — boot performs zero name probes; names fill lazily', () async {
    final store = _Store();
    final manager = FlutterSessionManager(
      env: store.env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
      repo: store.repo,
    );
    for (var i = 0; i < 5; i++) {
      final session = await store.repo.create(
        JsonlSessionCreateOptions(id: 'plain-$i', cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('body $i'));
    }
    for (final id in ['named-a', 'named-b']) {
      final session = await store.repo.create(
        JsonlSessionCreateOptions(id: id, cwd: '/work'),
      );
      await session.appendSessionName('Title of $id');
    }
    store.probes.clear();

    // THE BOOT listing: the shell-style reload — no name probes at all.
    final persisted = await manager.listPersistedSessions();
    expect(persisted, hasLength(7));
    expect(store.probes, isEmpty,
        reason: 'AC4: zero name-probe windows on the boot path');

    // The first paint renders derived titles — a projection WITHOUT the
    // background fill (readPersistedNames: false is the pre-fill mode)
    // touches no probe and knows no JSONL name.
    final preFillAdapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
      readPersistedNames: false,
    );
    final firstPaint = await preFillAdapter.load();
    expect(store.probes, isEmpty, reason: 'tiles paint before any probe');
    expect(
      firstPaint.where((e) => e.id.value == 'named-a').single.title,
      isNot('Title of named-a'),
      reason: 'derived title first — names are NOT on the boot path',
    );

    // The lazy fill lands (bounded pool, off the boot path): every tile
    // not yet accounted for is probed exactly once.
    await manager.warmSessionNames(persisted);
    expect(store.probes, hasLength(7), reason: 'probes happen, but HERE');
    expect(manager.knownSessionNames['named-a'], 'Title of named-a');
    expect(manager.knownSessionNames['named-b'], 'Title of named-b');
    expect(manager.knownSessionNames.containsKey('plain-0'), isFalse);

    // The real adapter projection repaints the tiles with the learned
    // titles — with NO further probes (positive AND negative cache
    // entries serve every tile; unnamed tiles are not re-probed either).
    final adapter = LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
    );
    final secondPaint = await adapter.load();
    expect(
      secondPaint.where((e) => e.id.value == 'named-a').single.title,
      'Title of named-a',
    );
    expect(store.probes, hasLength(7),
        reason: 'learned names serve from cache, never re-probed');
  });

  test('AC4 — a warm call with nothing pending probes nothing', () async {
    final store = _Store();
    final manager = FlutterSessionManager(
      env: store.env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
      repo: store.repo,
    );
    final session = await store.repo.create(
      const JsonlSessionCreateOptions(id: 's', cwd: '/work'),
    );
    // The boot listing builds the persisted index (writer upserts only
    // maintain an existing one), then the fill learns and persists the
    // name, so the next listing supplies it from the index.
    await manager.listPersistedSessions();
    await store.repo.rememberSessionNames({'s': 'Known'});
    final persisted = await manager.listPersistedSessions();
    expect(persisted, hasLength(1));
    expect(manager.knownSessionNames['s'], 'Known');
    store.probes.clear();

    await manager.warmSessionNames(persisted);
    expect(store.probes, isEmpty, reason: 'nothing pending: nothing probed');

    // Repeated warm with the same rows: still nothing pending.
    await manager.warmSessionNames(persisted);
    expect(store.probes, isEmpty);
    expect(manager.knownSessionNames['s'], 'Known');
    expect(session.cachedId, 's');
  });
}
