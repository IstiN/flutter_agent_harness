import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test(
    'local create/append is immediate; flush and remote open preserve JSONL',
    () async {
      final remote = FakeRemoteSessionProvider();
      final a = SessionHarness('a', remote);
      final session = await a.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 's1'),
      );
      expect(remote.uploadCalls, 0);
      await session.appendMessage(UserMessage.text('hello'));
      expect(remote.uploadCalls, 0);
      await a.sync.settle();
      expect((await a.store.load(a.scope.scopeKey)).pending, hasLength(1));
      await a.sync.flush(a.identity);

      final b = SessionHarness('b', remote);
      await b.sync.pull(b.identity);
      final metadata = await b.sync.localMetadata('s1');
      expect(metadata, isNotNull);
      final opened = await b.repo.open(metadata!);
      final entries = await opened.getEntries();
      expect(
        (entries.whereType<MessageRecord>().single.message as UserMessage)
            .content,
        'hello',
      );
      expect(metadata.path, isNot((await session.getMetadata()).path));
      await b.env.remove(metadata.path);
      final reopened = await b.repo.open(metadata);
      expect(
        (await reopened.getEntries()).whereType<MessageRecord>(),
        hasLength(1),
      );
    },
  );

  test(
    'pull persists a page cursor and resumes instead of full-scanning',
    () async {
      final remote = FakeRemoteSessionProvider()..pageSize = 1;
      final a = SessionHarness('a', remote);
      await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's1'));
      await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's2'));
      await a.sync.flush(a.identity);
      final b = SessionHarness('b', remote);
      await b.sync.pull(b.identity);
      expect(remote.listCursors, [null]);
      expect((await b.store.load(b.scope.scopeKey)).cursor, '1');
      expect(await b.sync.localMetadata('s1'), isNotNull);
      expect(await b.sync.localMetadata('s2'), isNull);
      await b.sync.pull(b.identity);
      expect(remote.listCursors, [null, '1']);
      expect((await b.store.load(b.scope.scopeKey)).cursor, isNull);
      expect(await b.sync.localMetadata('s2'), isNotNull);
      await b.sync.pull(b.identity);
      expect(remote.listCursors, [null, '1', null]);
    },
  );

  test('open fallback pulls through pages until the id materializes', () async {
    final remote = FakeRemoteSessionProvider()..pageSize = 1;
    final a = SessionHarness('a', remote);
    await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's1'));
    await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's2'));
    await a.sync.flush(a.identity);
    final remoteS2 = await a.sync.localMetadata('s2');
    final b = SessionHarness('b', remote);

    final opened = await b.repo.open(remoteS2!);

    expect((await opened.getMetadata()).id, 's2');
    expect(remote.listCursors, [null, '1']);
    expect(await b.sync.localMetadata('s2'), isNotNull);
  });

  test(
    'open recovery stops after one no-progress reconciliation cycle',
    () async {
      final remote = FakeRemoteSessionProvider()..pageSize = 1;
      final a = SessionHarness('a', remote);
      await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's1'));
      await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's2'));
      await a.sync.flush(a.identity);
      final missing = await a.sync.localMetadata('s2');
      remote.records[a.scope.scopeKey]!.remove('s2');
      final b = SessionHarness('b', remote);

      await expectLater(
        b.repo.open(missing!),
        throwsA(isA<SessionException>()),
      );

      expect(remote.listCursors, [null, null]);
    },
  );

  test('open retries a deferred child after its live parent arrives', () async {
    final remote = FakeRemoteSessionProvider()..pageSize = 1;
    final a = SessionHarness('a', remote);
    final parent = await a.repo.create(
      JsonlSessionCreateOptions(cwd: '/work', id: 'parent'),
    );
    final parentMeta = await parent.getMetadata();
    await a.repo.fork(parentMeta, cwd: '/work', id: 'child');
    await a.sync.flush(a.identity);
    final account = remote.records[a.scope.scopeKey]!;
    final parentValue = account['parent']!;
    final childValue = account['child']!;
    account
      ..clear()
      ..['child'] = childValue
      ..['parent'] = parentValue;
    final remoteChild = await a.sync.localMetadata('child');
    final b = SessionHarness('b', remote);

    final opened = await b.repo.open(remoteChild!);

    expect((await opened.getMetadata()).id, 'child');
    expect(await b.sync.localMetadata('child'), isNotNull);
    expect(await b.sync.localMetadata('parent'), isNotNull);
    expect(remote.listCursors, [null, '1', null]);
  });

  test(
    'kept fork materializes after its parent tombstone on an earlier page',
    () async {
      final remote = FakeRemoteSessionProvider()..pageSize = 1;
      final a = SessionHarness('a', remote);
      final parent = await a.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'parent'),
      );
      await parent.appendMessage(UserMessage.text('parent'));
      final parentMeta = await parent.getMetadata();
      await a.repo.fork(parentMeta, cwd: '/work', id: 'child');
      await a.sync.flush(a.identity);
      await a.sync.enqueueRemoteDelete(parentMeta);
      await a.sync.flush(a.identity);

      final b = SessionHarness('b', remote);
      await b.sync.pull(b.identity);
      expect(await b.sync.localMetadata('child'), isNull);
      await b.sync.pull(b.identity);

      final child = await b.sync.localMetadata('child');
      expect(child, isNotNull);
      expect(child!.parentSessionPath, isNull);
      expect((await (await b.repo.open(child)).getMetadata()).id, 'child');
    },
  );

  test(
    'fork → upload → pull → fork keeps parent and grandparent ancestry',
    () async {
      final remote = FakeRemoteSessionProvider();
      final a = SessionHarness('a', remote);
      final parent = await a.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'parent'),
      );
      await parent.appendMessage(UserMessage.text('parent-message'));
      final parentMeta = await parent.getMetadata();
      final fork = await a.repo.fork(
        parentMeta,
        cwd: '/work',
        id: 'fork',
        position: ForkPosition.at,
      );
      await fork.appendMessage(UserMessage.text('child-message'));
      await a.sync.flush(a.identity);

      final b = SessionHarness('b', remote);
      await b.sync.pull(b.identity);
      final bParent = await b.sync.localMetadata('parent');
      final bFork = await b.sync.localMetadata('fork');
      expect(bFork!.parentSessionPath, bParent!.path);
      final openedFork = await b.repo.open(bFork);
      expect(_messages(await openedFork.getBranch()), [
        'parent-message',
        'child-message',
      ]);

      final grand = await b.repo.fork(
        bFork,
        cwd: '/work',
        id: 'grand',
        position: ForkPosition.at,
      );
      await grand.appendMessage(UserMessage.text('grandchild-message'));
      await b.sync.flush(b.identity);
      await a.sync.pull(a.identity);
      final aGrandMeta = await a.sync.localMetadata('grand');
      final aGrand = await a.repo.open(aGrandMeta!);
      expect(_messages(await aGrand.getBranch()), [
        'parent-message',
        'child-message',
        'grandchild-message',
      ]);
    },
  );

  test(
    'crash after remote success replays the same batch idempotently',
    () async {
      final remote = FakeRemoteSessionProvider();
      final inner = MemoryCloudSessionSyncStore();
      final store = CrashCloudSessionStore(inner);
      final a = SessionHarness('a', remote, store: store);
      final session = await a.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 's1'),
      );
      await session.appendMessage(UserMessage.text('body'));
      await a.sync.settle();
      store.crashNextSave = true;
      await expectLater(a.sync.flush(a.identity), throwsStateError);
      expect(remote.successfulUploads, 1);

      final restarted = SessionHarness(
        'a2',
        remote,
        store: inner,
        env: a.env,
        repo: a.local,
      );
      await restarted.sync.flush(restarted.identity);
      expect(remote.uploadCalls, greaterThanOrEqualTo(2));
      expect(remote.successfulUploads, 1);
    },
  );

  test(
    'concurrent device appends merge by record id instead of mtime overwrite',
    () async {
      final remote = FakeRemoteSessionProvider();
      final a = SessionHarness('a', remote);
      final session = await a.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 's1'),
      );
      await session.appendMessage(UserMessage.text('base'));
      await a.sync.flush(a.identity);
      final b = SessionHarness('b', remote);
      await b.sync.pull(b.identity);
      await a.sync.pull(a.identity);

      final aOpen = await a.repo.open((await a.sync.localMetadata('s1'))!);
      final bOpen = await b.repo.open((await b.sync.localMetadata('s1'))!);
      await aOpen.appendMessage(UserMessage.text('from-a'));
      await a.sync.flush(a.identity);
      await bOpen.appendMessage(UserMessage.text('from-b'));
      await b.sync.flush(b.identity);

      final bytes = remote.bytesAt(b.scope, 's1');
      final text = utf8.decode(bytes);
      expect(text, contains('from-a'));
      expect(text, contains('from-b'));
      await a.sync.pull(a.identity);
      final reopened = await a.repo.open((await a.sync.localMetadata('s1'))!);
      expect(
        _messages(await reopened.getEntries()),
        containsAll(['base', 'from-a', 'from-b']),
      );
    },
  );

  test(
    'late remote read timeout keeps local writes and pending outbox intact',
    () async {
      final remote = FakeRemoteSessionProvider();
      final seed = SessionHarness('seed', remote);
      await seed.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'remote'),
      );
      await seed.sync.flush(seed.identity);
      final b = SessionHarness(
        'b',
        remote,
        remoteReadTimeout: const Duration(milliseconds: 20),
      );
      final local = await b.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'local'),
      );
      await local.appendMessage(UserMessage.text('offline-local'));
      await b.sync.settle();
      final before = await b.store.load(b.scope.scopeKey);
      remote.blockDownloads = true;
      await expectLater(
        b.sync.pull(b.identity),
        throwsA(isA<TimeoutException>()),
      );
      final after = await b.store.load(b.scope.scopeKey);
      expect(
        utf8.decode(after.pending.single.bytes),
        contains('offline-local'),
      );
      expect(after.pending.single.bytes, before.pending.single.bytes);
      expect(
        (await b.env.exists((await local.getMetadata()).path)).getOrThrow(),
        isTrue,
      );
    },
  );

  test(
    'local branch delete is local-only; remote close requires explicit call',
    () async {
      final remote = FakeRemoteSessionProvider();
      final a = SessionHarness('a', remote);
      final session = await a.repo.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 's1'),
      );
      await a.sync.flush(a.identity);
      final metadata = await session.getMetadata();
      await a.repo.delete(metadata);
      expect(remote.recordAt(a.scope, 's1').deleted, isFalse);
      expect((await a.store.load(a.scope.scopeKey)).pending, isEmpty);

      await a.repo.closeRemoteBranch(metadata);
      await a.sync.flush(a.identity);
      expect(remote.recordAt(a.scope, 's1').deleted, isTrue);
    },
  );

  test('account switch and auth generation fence old session writes', () async {
    final remote = FakeRemoteSessionProvider();
    final a = SessionHarness('a', remote);
    await a.repo.create(JsonlSessionCreateOptions(cwd: '/work', id: 's1'));
    await a.sync.settle();
    final calls = remote.uploadCalls;
    await expectLater(
      a.sync.flush(a.identity.nextGeneration()),
      throwsA(isA<DriveProviderException>()),
    );
    expect(remote.uploadCalls, calls);

    final other = CloudSessionScope(
      providerId: 'sessions',
      connectionId: 'connection',
      identity: CloudIdentity(
        tenantId: a.identity.tenantId,
        subject: 'other-subject',
        deviceId: 'other-device',
        authGeneration: 1,
      ),
    );
    expect(other.scopeKey, isNot(a.scope.scopeKey));
  });

  test('share links require allowlisted HTTPS, expiry and read-only caps', () {
    final link = CloudSessionShareLink.parse(
      Uri.parse(
        'https://share.example/share/sessions/session-123456'
        '?expires=2027-01-01T00:00:00Z&maxReads=5&capabilities=read',
      ),
      allowedHosts: {'share.example'},
    );
    expect(link.sessionId, 'session-123456');
    expect(link.maxReads, 5);
    expect(link.allowsReadAt(DateTime.utc(2026, 12, 31)), isTrue);
    expect(link.allowsReadAt(DateTime.utc(2027, 1, 2)), isFalse);
    expect(link.uri.query, isNot(contains('scopeKey')));
  });

  for (final uri in [
    'http://share.example/share/sessions/session-123456?expires=2027-01-01T00:00:00Z&maxReads=5',
    'https://evil.example/share/sessions/session-123456?expires=2027-01-01T00:00:00Z&maxReads=5',
    'https://share.example/share/sessions/session-123456?expires=2027-01-01T00:00:00Z&maxReads=5&capabilities=write',
    'https://share.example/share/sessions/session-123456?expires=2027-01-01T00:00:00Z&maxReads=5&accessToken=secret',
    'https://share.example/share/sessions/session-123456?maxReads=5',
  ]) {
    test('rejects unsafe share link $uri', () {
      expect(
        () => CloudSessionShareLink.parse(
          Uri.parse(uri),
          allowedHosts: {'share.example'},
        ),
        throwsFormatException,
      );
    });
  }
}

List<String> _messages(List<SessionRecord> records) => records
    .whereType<MessageRecord>()
    .map((record) => (record.message as UserMessage).content as String)
    .toList();

final class SessionHarness {
  SessionHarness(
    String name,
    this.remote, {
    CloudSessionSyncStore? store,
    MemoryExecutionEnv? env,
    JsonlSessionRepo? repo,
    Duration remoteReadTimeout = const Duration(seconds: 1),
  }) : env = env ?? MemoryExecutionEnv(),
       store = store ?? MemoryCloudSessionSyncStore() {
    local = repo ?? JsonlSessionRepo(fs: this.env, sessionsRoot: '/sessions');
    identity = CloudIdentity(
      tenantId: 'tenant',
      subject: 'subject',
      deviceId: 'device-$name',
      authGeneration: 1,
    );
    scope = CloudSessionScope(
      providerId: 'sessions',
      connectionId: 'connection',
      identity: identity,
    );
    var ids = 0;
    sync = CloudSessionSynchronizer(
      provider: remote,
      store: this.store,
      localRepo: local,
      env: this.env,
      scope: scope,
      remoteReadTimeout: remoteReadTimeout,
      operationId: () => 'session-$name-${++ids}',
    );
    this.repo = CloudSessionRepo(local, sync);
  }

  final FakeRemoteSessionProvider remote;
  final MemoryExecutionEnv env;
  final CloudSessionSyncStore store;
  late final JsonlSessionRepo local;
  late final CloudSessionRepo repo;
  late final CloudIdentity identity;
  late final CloudSessionScope scope;
  late final CloudSessionSynchronizer sync;
}

final class CrashCloudSessionStore implements CloudSessionSyncStore {
  CrashCloudSessionStore(this.inner);
  final CloudSessionSyncStore inner;
  bool crashNextSave = false;
  @override
  Future<CloudSessionSnapshot> load(String scopeKey) => inner.load(scopeKey);
  @override
  Future<CloudSessionSnapshot> save(
    CloudSessionSnapshot snapshot, {
    required int expectedStorageRevision,
  }) {
    if (crashNextSave) {
      crashNextSave = false;
      throw StateError('simulated crash after remote session upload');
    }
    return inner.save(
      snapshot,
      expectedStorageRevision: expectedStorageRevision,
    );
  }
}

final class _SessionRemoteValue {
  const _SessionRemoteValue(this.record, this.bytes);
  final CloudSessionRemoteRecord record;
  final Uint8List bytes;
}

final class FakeRemoteSessionProvider implements RemoteSessionProvider {
  @override
  String get providerId => 'sessions';
  final records = <String, Map<String, _SessionRemoteValue>>{};
  final dedup = <String, (String, CloudSessionRemoteRecord)>{};
  int revision = 0;
  int uploadCalls = 0;
  int successfulUploads = 0;
  bool blockDownloads = false;
  int? pageSize;
  final listCursors = <String?>[];

  Map<String, _SessionRemoteValue> _account(CloudSessionScope scope) =>
      records.putIfAbsent(scope.scopeKey, () => {});
  CloudSessionRemoteRecord recordAt(CloudSessionScope scope, String id) =>
      _account(scope)[id]!.record;
  Uint8List bytesAt(CloudSessionScope scope, String id) =>
      _account(scope)[id]!.bytes;

  @override
  Future<DriveResult<CloudSessionRemoteRecord>> upload(
    CloudSessionUpload upload,
  ) async {
    uploadCalls++;
    final key = '${upload.scope.scopeKey}:${upload.operationId}';
    final previous = dedup[key];
    if (previous != null) {
      return previous.$1 == upload.fingerprint
          ? DriveResult.ok(previous.$2)
          : const DriveResult.failure(
              DriveProviderException(
                DriveErrorKind.operationFingerprintMismatch,
                'same session operation id, different batch',
              ),
            );
    }
    final current = _account(upload.scope)[upload.sessionId];
    if (current?.record.revision != upload.baseRevision) {
      return const DriveResult.failure(
        DriveProviderException(
          DriveErrorKind.preconditionFailed,
          'stale session base',
        ),
      );
    }
    final record = CloudSessionRemoteRecord(
      sessionId: upload.sessionId,
      parentSessionId: upload.parentSessionId,
      revision: 'r${++revision}',
      sha256: upload.sha256,
      size: upload.bytes.length,
    );
    _account(upload.scope)[upload.sessionId] = _SessionRemoteValue(
      record,
      upload.bytes,
    );
    dedup[key] = (upload.fingerprint, record);
    successfulUploads++;
    return DriveResult.ok(record);
  }

  @override
  Future<DriveResult<CloudSessionPage>> list(
    CloudSessionScope scope,
    String? cursor,
  ) async {
    listCursors.add(cursor);
    final all = _account(scope).values.map((value) => value.record).toList();
    final size = pageSize;
    if (size == null) return DriveResult.ok(CloudSessionPage(records: all));
    final start = cursor == null ? 0 : int.parse(cursor);
    final proposedEnd = start + size;
    final end = proposedEnd < all.length ? proposedEnd : all.length;
    final hasMore = end < all.length;
    return DriveResult.ok(
      CloudSessionPage(
        records: all.sublist(start, end),
        nextCursor: hasMore ? '$end' : null,
        hasMore: hasMore,
      ),
    );
  }

  @override
  Future<DriveResult<CloudSessionDownload>> download(
    CloudSessionScope scope,
    String sessionId,
  ) async {
    if (blockDownloads) {
      return Completer<DriveResult<CloudSessionDownload>>().future;
    }
    final value = _account(scope)[sessionId];
    return value == null
        ? const DriveResult.failure(
            DriveProviderException(DriveErrorKind.notFound, 'missing session'),
          )
        : DriveResult.ok(
            CloudSessionDownload(record: value.record, bytes: value.bytes),
          );
  }

  @override
  Future<DriveResult<CloudSessionRemoteRecord>> delete(
    CloudSessionScope scope,
    String sessionId,
    String operationId,
    String? baseRevision,
    int authGeneration,
  ) async {
    final current = _account(scope)[sessionId];
    if (current?.record.revision != baseRevision) {
      return const DriveResult.failure(
        DriveProviderException(
          DriveErrorKind.preconditionFailed,
          'stale delete base',
        ),
      );
    }
    final record = CloudSessionRemoteRecord(
      sessionId: sessionId,
      parentSessionId: current?.record.parentSessionId,
      revision: 'r${++revision}',
      sha256: null,
      size: 0,
      deleted: true,
    );
    _account(scope)[sessionId] = _SessionRemoteValue(record, Uint8List(0));
    return DriveResult.ok(record);
  }
}
