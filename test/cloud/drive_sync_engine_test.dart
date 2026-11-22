import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  const identity = CloudIdentity(
    tenantId: 'tenant-a',
    subject: 'subject-a',
    deviceId: 'device-a',
    authGeneration: 1,
  );
  final scope = DriveMountScope.forIdentity(
    providerId: 'fake-drive',
    connectionId: 'connection-a',
    identity: identity,
  );
  final path = DrivePath.parse('/drive/notes/a.txt');

  test(
    'offline edits persist self-contained operations and flush FIFO after restart',
    () async {
      final remote = FakeRemoteDriveProvider();
      final store = MemoryDriveSyncStore();
      var ids = 0;
      final env = MemoryExecutionEnv();
      final engine = DriveSyncEngine(
        provider: remote,
        store: store,
        env: env,
        operationId: () => 'op-device-a-${++ids}',
      );
      await engine.enqueueUpload(scope, identity, path, _bytes('one'));
      final second = DrivePath.parse('/drive/notes/b.txt');
      await engine.enqueueUpload(scope, identity, second, _bytes('two'));
      expect(remote.uploadCalls, 0);
      final beforeRestart = await store.load(scope.mountKey);
      expect(beforeRestart.pending, hasLength(2));
      expect(beforeRestart.pending.map((op) => utf8.decode(op.bytes)), [
        'one',
        'two',
      ]);

      final restarted = DriveSyncEngine(
        provider: remote,
        store: store,
        env: MemoryExecutionEnv(),
      );
      final synced = await restarted.flush(scope, identity);
      expect(synced.pending, isEmpty);
      expect(remote.uploadOrder, ['one', 'two']);
      expect(synced.files[path.absolute]!.status, DriveSyncStatus.synced);
      expect(synced.files[second.absolute]!.dirty, isFalse);
    },
  );

  test(
    'pull accepts a tombstone for a path never materialized locally',
    () async {
      final remote = FakeRemoteDriveProvider();
      final missing = DrivePath.parse('/drive/notes/never-here.txt');
      remote.history[scope.mountKey] = [
        RemoteDriveItem(
          path: missing,
          revision: 'r1',
          sha256: null,
          size: 0,
          modifiedAt: DateTime.utc(2026),
          deleted: true,
        ),
      ];
      final store = MemoryDriveSyncStore();
      final engine = DriveSyncEngine(
        provider: remote,
        store: store,
        env: MemoryExecutionEnv(),
      );
      final snapshot = await engine.pull(scope, identity);
      expect(snapshot.files[missing.absolute]!.status, DriveSyncStatus.synced);
      expect(snapshot.cursor, '1');
    },
  );

  test(
    'crash after remote success before CAS retries the same operation without duplication',
    () async {
      final remote = FakeRemoteDriveProvider();
      final inner = MemoryDriveSyncStore();
      final store = CrashAfterRemoteStore(inner);
      final engine = DriveSyncEngine(
        provider: remote,
        store: store,
        env: MemoryExecutionEnv(),
        operationId: () => 'op-crash-1',
      );
      await engine.enqueueUpload(scope, identity, path, _bytes('payload'));
      store.crashNextSave = true;
      await expectLater(engine.flush(scope, identity), throwsStateError);
      expect(remote.successfulUploads, 1);

      final restarted = DriveSyncEngine(
        provider: remote,
        store: inner,
        env: MemoryExecutionEnv(),
      );
      final synced = await restarted.flush(scope, identity);
      expect(remote.successfulUploads, 1);
      expect(remote.uploadCalls, 2);
      expect(synced.pending, isEmpty);
    },
  );

  test(
    'pending bytes are immutable even if the live local file changes before retry',
    () async {
      final remote = FakeRemoteDriveProvider();
      final store = MemoryDriveSyncStore();
      final env = MemoryExecutionEnv();
      final engine = DriveSyncEngine(
        provider: remote,
        store: store,
        env: env,
        operationId: () => 'op-bytes-1',
      );
      await engine.enqueueUpload(scope, identity, path, _bytes('durable'));
      (await env.writeFile(path.absolute, 'live-edit')).getOrThrow();
      await engine.flush(scope, identity);
      expect(remote.textAt(scope, path), 'durable');
    },
  );

  test(
    'two devices never overwrite silently: conflict is durable and retry is parked',
    () async {
      final remote = FakeRemoteDriveProvider();
      remote.seed(scope, path, _bytes('base'));
      final engineA = _engine(remote, MemoryDriveSyncStore(), 'a');
      final engineB = _engine(remote, MemoryDriveSyncStore(), 'b');
      await engineA.pull(scope, identity);
      await engineB.pull(scope, identity);
      await engineA.enqueueUpload(scope, identity, path, _bytes('from-a'));
      await engineA.flush(scope, identity);
      await engineB.enqueueUpload(scope, identity, path, _bytes('from-b'));

      final conflict = await engineB.flush(scope, identity);
      expect(conflict.files[path.absolute]!.status, DriveSyncStatus.conflict);
      expect(conflict.pending, hasLength(1));
      expect(remote.textAt(scope, path), 'from-a');
      final calls = remote.uploadCalls;
      await engineB.flush(scope, identity);
      expect(
        remote.uploadCalls,
        calls,
        reason: 'a conflict must not auto-overwrite',
      );

      final resolved = await engineB.resolveConflictAcceptRemote(
        scope,
        identity,
        path,
      );
      expect(resolved.pending, isEmpty);
      expect(resolved.files[path.absolute]!.status, DriveSyncStatus.synced);
      expect(
        utf8.decode(
          (await engineB.env.readBinaryFile(path.absolute)).getOrThrow(),
        ),
        'from-a',
      );
    },
  );

  test('explicit keep-local rebases on the fetched remote revision', () async {
    final remote = FakeRemoteDriveProvider();
    remote.seed(scope, path, _bytes('base'));
    final engineA = _engine(remote, MemoryDriveSyncStore(), 'a');
    final engineB = _engine(remote, MemoryDriveSyncStore(), 'b');
    await engineA.pull(scope, identity);
    await engineB.pull(scope, identity);
    await engineA.enqueueUpload(scope, identity, path, _bytes('from-a'));
    await engineA.flush(scope, identity);
    await engineB.enqueueUpload(scope, identity, path, _bytes('from-b'));
    await engineB.flush(scope, identity);
    await engineB.resolveConflictKeepLocal(scope, identity, path);
    final synced = await engineB.flush(scope, identity);
    expect(synced.files[path.absolute]!.status, DriveSyncStatus.synced);
    expect(remote.textAt(scope, path), 'from-b');
    expect(remote.itemAt(scope, path).revision, 'r3');
  });

  test(
    'same operation id with a different fingerprint is rejected without mutation',
    () async {
      final remote = FakeRemoteDriveProvider();
      final first = DriveUploadRequest(
        scope: scope,
        path: path,
        bytes: _bytes('one'),
        operationId: 'op-same-01',
      );
      final second = DriveUploadRequest(
        scope: scope,
        path: path,
        bytes: _bytes('two'),
        operationId: 'op-same-01',
      );
      expect((await remote.upload(first)).isOk, isTrue);
      final replay = await remote.upload(second);
      expect(replay.error!.kind, DriveErrorKind.operationFingerprintMismatch);
      expect(remote.textAt(scope, path), 'one');
      expect(remote.successfulUploads, 1);
    },
  );

  test('quota failures are per-account, durable and recoverable', () async {
    final remote = FakeRemoteDriveProvider()
      ..remainingQuota[scope.mountKey] = 3;
    final store = MemoryDriveSyncStore();
    final engine = DriveSyncEngine(
      provider: remote,
      store: store,
      env: MemoryExecutionEnv(),
      operationId: () => 'op-quota-1',
    );
    await engine.enqueueUpload(scope, identity, path, _bytes('four'));
    final failed = await engine.flush(scope, identity);
    expect(failed.files[path.absolute]!.status, DriveSyncStatus.quotaExceeded);
    expect(failed.pending, hasLength(1));

    const otherIdentity = CloudIdentity(
      tenantId: 'tenant-a',
      subject: 'subject-b',
      deviceId: 'device-b',
      authGeneration: 1,
    );
    final otherScope = DriveMountScope.forIdentity(
      providerId: 'fake-drive',
      connectionId: 'connection-a',
      identity: otherIdentity,
    );
    final other = DriveSyncEngine(
      provider: remote,
      store: MemoryDriveSyncStore(),
      env: MemoryExecutionEnv(),
      operationId: () => 'op-other-1',
    );
    await other.enqueueUpload(otherScope, otherIdentity, path, _bytes('four'));
    await other.flush(otherScope, otherIdentity);
    expect(remote.textAt(otherScope, path), 'four');

    remote.remainingQuota[scope.mountKey] = 100;
    final recovered = await engine.flush(scope, identity);
    expect(recovered.pending, isEmpty);
    expect(recovered.files[path.absolute]!.status, DriveSyncStatus.synced);
  });

  test(
    'inactive plan and provider reauth are not reported as local success',
    () async {
      final remote = FakeRemoteDriveProvider()
        ..forcedError = const DriveProviderException(
          DriveErrorKind.inactivePlan,
          'upgrade required',
          providerOperationId: 'provider-op-9',
        );
      final engine = DriveSyncEngine(
        provider: remote,
        store: MemoryDriveSyncStore(),
        env: MemoryExecutionEnv(),
        operationId: () => 'op-plan-01',
      );
      await engine.enqueueUpload(scope, identity, path, _bytes('body'));
      final failed = await engine.flush(scope, identity);
      expect(failed.files[path.absolute]!.status, DriveSyncStatus.planInactive);
      expect(failed.files[path.absolute]!.providerDetails, 'upgrade required');
      expect(failed.pending, hasLength(1));
    },
  );

  test(
    'auth generation advance fences pending work before provider traffic',
    () async {
      final remote = FakeRemoteDriveProvider();
      final engine = DriveSyncEngine(
        provider: remote,
        store: MemoryDriveSyncStore(),
        env: MemoryExecutionEnv(),
        operationId: () => 'op-fence-1',
      );
      await engine.enqueueUpload(scope, identity, path, _bytes('body'));
      await expectLater(
        engine.flush(scope, identity.nextGeneration()),
        throwsA(isA<DriveProviderException>()),
      );
      expect(remote.uploadCalls, 0);
    },
  );

  test(
    'CAS prevents two tabs from silently losing each other pending edits',
    () async {
      final store = MemoryDriveSyncStore();
      final first = await store.load(scope.mountKey);
      final second = await store.load(scope.mountKey);
      await store.save(first, expectedStorageRevision: 0);
      await expectLater(
        store.save(second, expectedStorageRevision: 0),
        throwsA(isA<DriveStoreConcurrencyException>()),
      );
    },
  );

  test('delete is conditional and produces a remote tombstone', () async {
    final remote = FakeRemoteDriveProvider();
    remote.seed(scope, path, _bytes('base'));
    final engine = _engine(remote, MemoryDriveSyncStore(), 'delete');
    await engine.pull(scope, identity);
    await engine.enqueueDelete(scope, identity, path);
    final synced = await engine.flush(scope, identity);
    expect(synced.pending, isEmpty);
    expect(remote.itemAt(scope, path).deleted, isTrue);
    expect((await engine.env.exists(path.absolute)).getOrThrow(), isFalse);
  });

  test('reusable external-provider contract passes a complete fake', () async {
    final remote = FakeRemoteDriveProvider();
    final checks = await runRemoteDriveProviderContract(
      provider: remote,
      scope: scope,
      allowMutations: true,
    );
    expect(checks, hasLength(7));
    expect(
      checks.where((check) => !check.passed),
      isEmpty,
      reason: checks
          .map((check) => '${check.name}: ${check.details}')
          .join('\n'),
    );
    await expectLater(
      runRemoteDriveProviderContract(
        provider: remote,
        scope: scope,
        allowMutations: false,
      ),
      throwsStateError,
    );
  });
}

DriveSyncEngine _engine(
  FakeRemoteDriveProvider remote,
  DriveSyncStore store,
  String prefix,
) {
  var ids = 0;
  return DriveSyncEngine(
    provider: remote,
    store: store,
    env: MemoryExecutionEnv(),
    operationId: () => 'op-device-$prefix-${++ids}',
  );
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

final class CrashAfterRemoteStore implements DriveSyncStore {
  CrashAfterRemoteStore(this.inner);
  final MemoryDriveSyncStore inner;
  bool crashNextSave = false;

  @override
  Future<DriveWorkspaceSnapshot> load(String scopeKey) => inner.load(scopeKey);

  @override
  Future<DriveWorkspaceSnapshot> save(
    DriveWorkspaceSnapshot snapshot, {
    required int expectedStorageRevision,
  }) {
    if (crashNextSave) {
      crashNextSave = false;
      throw StateError('simulated browser crash after remote mutation');
    }
    return inner.save(
      snapshot,
      expectedStorageRevision: expectedStorageRevision,
    );
  }
}

final class _RemoteRecord {
  const _RemoteRecord(this.item, this.bytes);
  final RemoteDriveItem item;
  final Uint8List bytes;
}

final class _OperationRecord {
  const _OperationRecord(this.fingerprint, this.item);
  final String fingerprint;
  final RemoteDriveItem item;
}

final class FakeRemoteDriveProvider implements RemoteDriveProvider {
  @override
  String get providerId => 'fake-drive';

  @override
  DriveCapabilities get capabilities => const DriveCapabilities(
    deltaCursors: true,
    conditionalWrites: true,
    revisions: true,
    hashes: true,
    move: false,
    trash: true,
    maxFileBytes: 1024 * 1024,
  );

  final accounts = <String, Map<String, _RemoteRecord>>{};
  final history = <String, List<RemoteDriveItem>>{};
  final revisions = <String, int>{};
  final remainingQuota = <String, int>{};
  final dedup = <String, _OperationRecord>{};
  final uploadOrder = <String>[];
  int uploadCalls = 0;
  int successfulUploads = 0;
  DriveProviderException? forcedError;

  Map<String, _RemoteRecord> _files(DriveMountScope scope) =>
      accounts.putIfAbsent(scope.mountKey, () => {});
  List<RemoteDriveItem> _history(DriveMountScope scope) =>
      history.putIfAbsent(scope.mountKey, () => []);

  void seed(DriveMountScope scope, DrivePath path, Uint8List bytes) {
    final revision = 'r${(revisions[scope.mountKey] ?? 0) + 1}';
    revisions[scope.mountKey] = int.parse(revision.substring(1));
    final item = RemoteDriveItem(
      path: path,
      revision: revision,
      sha256: cryptoSha256(bytes),
      size: bytes.length,
      modifiedAt: DateTime.utc(2026),
    );
    _files(scope)[path.absolute] = _RemoteRecord(item, bytes);
    _history(scope).add(item);
  }

  RemoteDriveItem itemAt(DriveMountScope scope, DrivePath path) =>
      _files(scope)[path.absolute]!.item;
  String textAt(DriveMountScope scope, DrivePath path) =>
      utf8.decode(_files(scope)[path.absolute]!.bytes);

  @override
  Future<DriveResult<RemoteDriveItem>> upload(
    DriveUploadRequest request,
  ) async {
    uploadCalls++;
    final key = '${request.scope.mountKey}:${request.operationId}';
    final fingerprint = driveOperationFingerprint(request);
    final previous = dedup[key];
    if (previous != null) {
      return previous.fingerprint == fingerprint
          ? DriveResult.ok(previous.item)
          : const DriveResult.failure(
              DriveProviderException(
                DriveErrorKind.operationFingerprintMismatch,
                'operation id was reused with different payload/base',
              ),
            );
    }
    if (forcedError != null) return DriveResult.failure(forcedError);
    final current = _files(request.scope)[request.path.absolute];
    if (current?.item.revision != request.baseRevision) {
      return const DriveResult.failure(
        DriveProviderException(
          DriveErrorKind.preconditionFailed,
          'base mismatch',
        ),
      );
    }
    final quota = remainingQuota[request.scope.mountKey];
    if (quota != null && request.bytes.length > quota) {
      return const DriveResult.failure(
        DriveProviderException(DriveErrorKind.quotaExceeded, 'account quota'),
      );
    }
    if (quota != null) {
      remainingQuota[request.scope.mountKey] = quota - request.bytes.length;
    }
    seed(request.scope, request.path, request.bytes);
    final item = itemAt(request.scope, request.path);
    dedup[key] = _OperationRecord(fingerprint, item);
    uploadOrder.add(utf8.decode(request.bytes));
    successfulUploads++;
    return DriveResult.ok(item);
  }

  @override
  Future<DriveResult<RemoteDriveItem>> delete(
    DriveDeleteRequest request,
  ) async {
    final current = _files(request.scope)[request.path.absolute];
    if (current?.item.revision != request.baseRevision) {
      return const DriveResult.failure(
        DriveProviderException(
          DriveErrorKind.preconditionFailed,
          'base mismatch',
        ),
      );
    }
    final revision = 'r${(revisions[request.scope.mountKey] ?? 0) + 1}';
    revisions[request.scope.mountKey] = int.parse(revision.substring(1));
    final item = RemoteDriveItem(
      path: request.path,
      revision: revision,
      sha256: null,
      size: 0,
      modifiedAt: DateTime.utc(2026),
      deleted: true,
    );
    _files(request.scope)[request.path.absolute] = _RemoteRecord(
      item,
      Uint8List(0),
    );
    _history(request.scope).add(item);
    return DriveResult.ok(item);
  }

  @override
  Future<DriveResult<RemoteDriveItem>> get(
    DriveMountScope scope,
    DrivePath path,
  ) async {
    final record = _files(scope)[path.absolute];
    return record == null
        ? const DriveResult.failure(
            DriveProviderException(DriveErrorKind.notFound, 'not found'),
          )
        : DriveResult.ok(record.item);
  }

  @override
  Future<DriveResult<RemoteDriveDownload>> download(
    DriveMountScope scope,
    DrivePath path,
  ) async {
    final record = _files(scope)[path.absolute];
    return record == null
        ? const DriveResult.failure(
            DriveProviderException(DriveErrorKind.notFound, 'not found'),
          )
        : DriveResult.ok(
            RemoteDriveDownload(item: record.item, bytes: record.bytes),
          );
  }

  @override
  Future<DriveResult<List<RemoteDriveItem>>> list(
    DriveListRequest request,
  ) async {
    final prefix = request.path.absolute;
    return DriveResult.ok(
      _files(request.scope).values
          .where((record) => record.item.path.absolute.startsWith(prefix))
          .map((record) => record.item)
          .toList(),
    );
  }

  @override
  Future<DriveResult<DriveChangesPage>> changes(
    DriveChangesRequest request,
  ) async {
    final all = _history(request.scope);
    final offset = request.cursor == null ? 0 : int.parse(request.cursor!);
    final items = all.skip(offset).toList();
    return DriveResult.ok(
      DriveChangesPage(items: items, nextCursor: '${all.length}'),
    );
  }
}
