import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../env/execution_env.dart';
import '../product/fa_product_config.dart';
import 'drive_contract.dart';
import 'drive_sync_store.dart';

typedef DriveUtcNow = DateTime Function();
typedef DriveOperationId = String Function();

/// Conditional-revision drive synchronizer. It deliberately knows nothing
/// about a specific cloud provider or product and is never constructed for
/// stock Fa unless a host explicitly registers a provider.
final class DriveSyncEngine {
  DriveSyncEngine({
    required this.provider,
    required this.store,
    required this.env,
    DriveUtcNow? now,
    DriveOperationId? operationId,
  }) : now = now ?? (() => DateTime.now().toUtc()),
       operationId = operationId ?? _defaultOperationId;

  final RemoteDriveProvider provider;
  final DriveSyncStore store;
  final ExecutionEnv env;
  final DriveUtcNow now;
  final DriveOperationId operationId;

  Future<DriveWorkspaceSnapshot> enqueueUpload(
    DriveMountScope scope,
    CloudIdentity identity,
    DrivePath path,
    Uint8List bytes,
  ) async {
    _checkIdentity(scope, identity);
    provider.capabilities.requireUpload(bytes.length);
    var snapshot = await store.load(scope.mountKey);
    _checkCollision(snapshot, path);
    final revision = snapshot.nextLocalRevision;
    final previous = snapshot.files[path.absolute];
    final operation = _newOperation(
      scope: scope,
      path: path,
      bytes: bytes,
      baseRevision: previous?.remoteRevision,
      localRevision: revision,
      authGeneration: identity.authGeneration,
    );
    final files = {...snapshot.files};
    files[path.absolute] = DriveFileState(
      collisionKey: path.collisionKey,
      localRevision: revision,
      localSha256: operation.sha256,
      remoteRevision: previous?.remoteRevision,
      remoteSha256: previous?.remoteSha256,
      status: DriveSyncStatus.syncing,
      dirty: true,
    );
    snapshot = await store.save(
      snapshot.copyWith(
        nextLocalRevision: revision + 1,
        files: files,
        pending: [...snapshot.pending, operation],
      ),
      expectedStorageRevision: snapshot.storageRevision,
    );
    await _writeLocal(path, bytes);
    return snapshot;
  }

  Future<DriveWorkspaceSnapshot> enqueueDelete(
    DriveMountScope scope,
    CloudIdentity identity,
    DrivePath path,
  ) async {
    _checkIdentity(scope, identity);
    var snapshot = await store.load(scope.mountKey);
    final revision = snapshot.nextLocalRevision;
    final previous = snapshot.files[path.absolute];
    final operation = _newOperation(
      scope: scope,
      path: path,
      bytes: Uint8List(0),
      baseRevision: previous?.remoteRevision,
      localRevision: revision,
      authGeneration: identity.authGeneration,
      delete: true,
    );
    final files = {...snapshot.files};
    files[path.absolute] = DriveFileState(
      collisionKey: path.collisionKey,
      localRevision: revision,
      localSha256: operation.sha256,
      remoteRevision: previous?.remoteRevision,
      remoteSha256: previous?.remoteSha256,
      status: DriveSyncStatus.syncing,
      dirty: true,
    );
    snapshot = await store.save(
      snapshot.copyWith(
        nextLocalRevision: revision + 1,
        files: files,
        pending: [...snapshot.pending, operation],
      ),
      expectedStorageRevision: snapshot.storageRevision,
    );
    (await env.remove(path.absolute, force: true)).getOrThrow();
    return snapshot;
  }

  /// Flushes pending operations FIFO. Every remote attempt uses the durable
  /// operation id; a crash after remote success but before local CAS replays
  /// the same key and never creates a duplicate mutation.
  Future<DriveWorkspaceSnapshot> flush(
    DriveMountScope scope,
    CloudIdentity identity,
  ) async {
    _checkIdentity(scope, identity);
    var snapshot = await store.load(scope.mountKey);
    while (snapshot.pending.isNotEmpty) {
      final operation = snapshot.pending.first;
      if (operation.authGeneration != identity.authGeneration) {
        throw const DriveProviderException(
          DriveErrorKind.providerReauthRequired,
          'pending operation belongs to a fenced auth generation',
        );
      }
      final file = snapshot.files[operation.path.absolute];
      if (file?.status == DriveSyncStatus.conflict) break;
      final baseRevision = file?.remoteRevision ?? operation.baseRevision;
      final DriveResult<RemoteDriveItem> result;
      if (operation.delete) {
        final deleted = await provider.delete(
          DriveDeleteRequest(
            scope: scope,
            path: operation.path,
            operationId: operation.operationId,
            baseRevision: baseRevision,
            authGeneration: identity.authGeneration,
          ),
        );
        result = deleted;
      } else {
        result = await provider.upload(
          DriveUploadRequest(
            scope: scope,
            path: operation.path,
            bytes: operation.bytes,
            operationId: operation.operationId,
            baseRevision: baseRevision,
            authGeneration: identity.authGeneration,
          ),
        );
      }
      if (!result.isOk) {
        final error = result.error!;
        var files = {...snapshot.files};
        var current = files[operation.path.absolute];
        if (error.kind == DriveErrorKind.preconditionFailed) {
          final remote = await provider.get(scope, operation.path);
          if (remote.isOk) {
            current = (current ?? _emptyFile(operation.path)).copyWith(
              remoteRevision: remote.value!.revision,
              remoteSha256: remote.value!.sha256,
              status: DriveSyncStatus.conflict,
              dirty: true,
              providerDetails: 'remote changed from the conditional base',
            );
          } else {
            current = (current ?? _emptyFile(operation.path)).copyWith(
              status: DriveSyncStatus.conflict,
              dirty: true,
              providerDetails: error.message,
            );
          }
        } else {
          final syncState = DriveSyncState(
            status: DriveSyncStatus.syncing,
            dirty: true,
            localRevision:
                '${current?.localRevision ?? operation.localRevision}',
            baseRevision: baseRevision,
            operationId: operation.operationId,
          ).fromError(error, now: now());
          current = (current ?? _emptyFile(operation.path)).copyWith(
            status: syncState.status,
            dirty: true,
            providerDetails: error.message,
            retryAt: syncState.retryAt,
          );
        }
        files[operation.path.absolute] = current;
        return store.save(
          snapshot.copyWith(files: files),
          expectedStorageRevision: snapshot.storageRevision,
        );
      }

      final remote = result.value!;
      final pending = [...snapshot.pending]..removeAt(0);
      final files = {...snapshot.files};
      final current =
          files[operation.path.absolute] ?? _emptyFile(operation.path);
      final stillDirty =
          current.localRevision > operation.localRevision ||
          pending.any(
            (candidate) => candidate.path.absolute == operation.path.absolute,
          );
      files[operation.path.absolute] = current.copyWith(
        localSha256: current.localRevision == operation.localRevision
            ? operation.sha256
            : current.localSha256,
        remoteRevision: remote.revision,
        remoteSha256: remote.sha256,
        status: stillDirty ? DriveSyncStatus.syncing : DriveSyncStatus.synced,
        dirty: stillDirty,
        providerDetails: null,
        retryAt: null,
        lastSyncedAt: now(),
      );
      snapshot = await store.save(
        snapshot.copyWith(files: files, pending: pending),
        expectedStorageRevision: snapshot.storageRevision,
      );
    }
    return snapshot;
  }

  /// Pulls remote delta changes. A dirty path with a different remote revision
  /// becomes an explicit conflict and is NEVER overwritten automatically.
  Future<DriveWorkspaceSnapshot> pull(
    DriveMountScope scope,
    CloudIdentity identity,
  ) async {
    _checkIdentity(scope, identity);
    final snapshot = await store.load(scope.mountKey);
    final result = await provider.changes(
      DriveChangesRequest(scope: scope, cursor: snapshot.cursor),
    );
    if (!result.isOk) throw result.error!;
    final files = {...snapshot.files};
    for (final remote in result.value!.items) {
      final update = await _pullRemoteItem(scope, snapshot, remote);
      if (update != null) files[update.key] = update.value;
    }
    return store.save(
      snapshot.copyWith(files: files, cursor: result.value!.nextCursor),
      expectedStorageRevision: snapshot.storageRevision,
    );
  }

  Future<MapEntry<String, DriveFileState>?> _pullRemoteItem(
    DriveMountScope scope,
    DriveWorkspaceSnapshot snapshot,
    RemoteDriveItem remote,
  ) async {
    final path = remote.path;
    final current = snapshot.files[path.absolute] ?? _emptyFile(path);
    final hasLocal = snapshot.pending.any(
      (operation) => operation.path.absolute == path.absolute,
    );
    if (hasLocal && remote.revision != current.remoteRevision) {
      return MapEntry(
        path.absolute,
        current.copyWith(
          remoteRevision: remote.revision,
          remoteSha256: remote.sha256,
          status: DriveSyncStatus.conflict,
          dirty: true,
          providerDetails: 'remote delta raced a local edit',
        ),
      );
    }
    if (remote.deleted) {
      return MapEntry(
        path.absolute,
        await _pullRemoteDelete(path, current, remote),
      );
    }
    if (remote.sha256 == current.localSha256 &&
        remote.revision == current.remoteRevision) {
      return null;
    }
    return MapEntry(
      path.absolute,
      await _pullRemoteDownload(scope, path, current, remote),
    );
  }

  Future<DriveFileState> _pullRemoteDelete(
    DrivePath path,
    DriveFileState current,
    RemoteDriveItem remote,
  ) async {
    (await env.remove(path.absolute, force: true)).getOrThrow();
    return current.copyWith(
      remoteRevision: remote.revision,
      remoteSha256: null,
      status: DriveSyncStatus.synced,
      dirty: false,
      lastSyncedAt: now(),
    );
  }

  Future<DriveFileState> _pullRemoteDownload(
    DriveMountScope scope,
    DrivePath path,
    DriveFileState current,
    RemoteDriveItem remote,
  ) async {
    final result = await provider.download(scope, path);
    if (!result.isOk) throw result.error!;
    final download = result.value!;
    _validateDownloadHash(download);
    await _writeLocal(path, download.bytes);
    return current.copyWith(
      localSha256: cryptoSha256(download.bytes),
      remoteRevision: remote.revision,
      remoteSha256: remote.sha256,
      status: DriveSyncStatus.synced,
      dirty: false,
      lastSyncedAt: now(),
    );
  }

  static void _validateDownloadHash(RemoteDriveDownload download) {
    final expected = download.item.sha256;
    if (expected != null && cryptoSha256(download.bytes) != expected) {
      throw const DriveProviderException(
        DriveErrorKind.invalidResponse,
        'downloaded bytes do not match provider hash',
      );
    }
  }

  Future<DriveWorkspaceSnapshot> resolveConflictKeepLocal(
    DriveMountScope scope,
    CloudIdentity identity,
    DrivePath path,
  ) async {
    _checkIdentity(scope, identity);
    var snapshot = await store.load(scope.mountKey);
    final current = snapshot.files[path.absolute];
    if (current?.status != DriveSyncStatus.conflict) {
      throw StateError('path is not in conflict');
    }
    final files = {...snapshot.files};
    files[path.absolute] = current!.copyWith(
      status: DriveSyncStatus.syncing,
      dirty: true,
      providerDetails: 'explicit keep-local resolution',
    );
    return store.save(
      snapshot.copyWith(files: files),
      expectedStorageRevision: snapshot.storageRevision,
    );
  }

  Future<DriveWorkspaceSnapshot> resolveConflictAcceptRemote(
    DriveMountScope scope,
    CloudIdentity identity,
    DrivePath path,
  ) async {
    _checkIdentity(scope, identity);
    var snapshot = await store.load(scope.mountKey);
    if (snapshot.files[path.absolute]?.status != DriveSyncStatus.conflict) {
      throw StateError('path is not in conflict');
    }
    final pending = snapshot.pending
        .where((operation) => operation.path.absolute != path.absolute)
        .toList();
    final files = {...snapshot.files};
    files[path.absolute] = snapshot.files[path.absolute]!.copyWith(
      status: DriveSyncStatus.syncing,
      dirty: false,
      providerDetails: 'explicit accept-remote resolution',
    );
    snapshot = await store.save(
      snapshot.copyWith(files: files, pending: pending),
      expectedStorageRevision: snapshot.storageRevision,
    );
    final download = await provider.download(scope, path);
    if (!download.isOk) throw download.error!;
    await _writeLocal(path, download.value!.bytes);
    files[path.absolute] = files[path.absolute]!.copyWith(
      localSha256: cryptoSha256(download.value!.bytes),
      remoteRevision: download.value!.item.revision,
      remoteSha256: download.value!.item.sha256,
      status: DriveSyncStatus.synced,
      dirty: false,
      lastSyncedAt: now(),
    );
    return store.save(
      snapshot.copyWith(files: files),
      expectedStorageRevision: snapshot.storageRevision,
    );
  }

  DriveOperationRecord _newOperation({
    required DriveMountScope scope,
    required DrivePath path,
    required Uint8List bytes,
    required String? baseRevision,
    required int localRevision,
    required int authGeneration,
    bool delete = false,
  }) {
    final sha = cryptoSha256(bytes);
    final id = operationId();
    final request = DriveUploadRequest(
      scope: scope,
      path: path,
      bytes: bytes,
      operationId: id,
      baseRevision: baseRevision,
      authGeneration: authGeneration,
    );
    return DriveOperationRecord(
      operationId: id,
      path: path,
      bytes: bytes,
      sha256: sha,
      fingerprint: driveOperationFingerprint(request),
      baseRevision: baseRevision,
      localRevision: localRevision,
      authGeneration: authGeneration,
      createdAt: now(),
      delete: delete,
    );
  }

  void _checkIdentity(DriveMountScope scope, CloudIdentity identity) {
    identity.validate();
    final expected = DriveMountScope.forIdentity(
      providerId: scope.providerId,
      connectionId: scope.connectionId,
      identity: identity,
      mount: scope.mount,
    );
    if (scope.mountKey != expected.mountKey) {
      throw const FormatException('cloud identity does not match drive scope');
    }
  }

  void _checkCollision(DriveWorkspaceSnapshot snapshot, DrivePath path) {
    for (final entry in snapshot.files.entries) {
      if (entry.key != path.absolute &&
          entry.value.collisionKey == path.collisionKey) {
        throw FormatException('Unicode/case path collision: ${path.absolute}');
      }
    }
  }

  DriveFileState _emptyFile(DrivePath path) =>
      DriveFileState(collisionKey: path.collisionKey, localRevision: 0);

  Future<void> _writeLocal(DrivePath path, Uint8List bytes) async {
    if (!path.isRoot) {
      (await env.createDir(path.parent.absolute)).getOrThrow();
    }
    (await env.writeBinaryFile(path.absolute, bytes)).getOrThrow();
  }

  static String _defaultOperationId() {
    final seed = '${DateTime.now().microsecondsSinceEpoch}';
    return 'op-${sha256.convert(utf8.encode(seed)).toString().substring(0, 24)}';
  }
}
