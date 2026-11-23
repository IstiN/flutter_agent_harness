import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// UI-facing state adapter for Files/Recent surfaces. Construction is opt-in
/// by a host product; stock FileBrowser leaves this null and stays local-only.
final class DriveSyncController extends ChangeNotifier {
  DriveSyncController({
    required this.engine,
    required this.scope,
    required this._identity,
    bool autoLoad = true,
  }) {
    if (autoLoad) unawaited(refresh());
  }

  final DriveSyncEngine engine;
  final DriveMountScope scope;
  CloudIdentity _identity;
  DriveWorkspaceSnapshot? _snapshot;
  Object? lastError;

  CloudIdentity get identity => _identity;

  /// Account switch/sign-out advances the fence BEFORE another flush. The
  /// store namespace changes with tenant+subject; old writers cannot mutate
  /// the newly active account.
  void updateIdentity(CloudIdentity next) {
    if (next.tenantId != _identity.tenantId ||
        next.subject != _identity.subject ||
        next.authGeneration < _identity.authGeneration) {
      throw ArgumentError('identity switch must advance the auth fence');
    }
    _identity = next;
    _snapshot = null;
    lastError = null;
    notifyListeners();
    unawaited(refresh());
  }

  DriveSyncState get overallState {
    final snapshot = _snapshot;
    if (snapshot == null) return const DriveSyncState.localOnly('loading');
    for (final status in [
      DriveSyncStatus.conflict,
      DriveSyncStatus.providerReauthRequired,
      DriveSyncStatus.planInactive,
      DriveSyncStatus.quotaExceeded,
      DriveSyncStatus.permanentError,
      DriveSyncStatus.syncing,
    ]) {
      if (snapshot.files.values.any((file) => file.status == status)) {
        return DriveSyncState(
          status: status,
          dirty: snapshot.pending.isNotEmpty,
          operationId: snapshot.pending.isEmpty
              ? null
              : snapshot.pending.first.operationId,
          providerDetails: _detailsFor(status),
        );
      }
    }
    if (snapshot.files.isEmpty) {
      return const DriveSyncState.localOnly('no drive files');
    }
    return DriveSyncState(
      status: DriveSyncStatus.synced,
      dirty: false,
      lastSyncedAt: snapshot.files.values
          .map((file) => file.lastSyncedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a),
    );
  }

  DriveSyncState stateFor(DrivePath path) {
    final file = _snapshot?.files[path.absolute];
    if (file == null) return const DriveSyncState.localOnly();
    return DriveSyncState(
      status: file.status,
      dirty: file.dirty,
      localRevision: '${file.localRevision}',
      remoteRevision: file.remoteRevision,
      providerDetails: file.providerDetails,
      retryAt: file.retryAt,
      lastSyncedAt: file.lastSyncedAt,
    );
  }

  DrivePath? get firstConflict {
    for (final entry
        in _snapshot?.files.entries ??
            const <MapEntry<String, DriveFileState>>[]) {
      if (entry.value.status == DriveSyncStatus.conflict) {
        return DrivePath.parse(entry.key);
      }
    }
    return null;
  }

  int get pendingCount => _snapshot?.pending.length ?? 0;

  Future<void> refresh() async {
    try {
      _snapshot = await engine.store.load(scope.mountKey);
      lastError = null;
    } catch (error) {
      lastError = error;
    }
    notifyListeners();
  }

  Future<void> enqueueUpload(DrivePath path, Uint8List bytes) =>
      _run(() => engine.enqueueUpload(scope, _identity, path, bytes));

  Future<void> enqueueDelete(DrivePath path) =>
      _run(() => engine.enqueueDelete(scope, _identity, path));

  Future<void> flush() => _run(() => engine.flush(scope, _identity));

  Future<void> pull() => _run(() => engine.pull(scope, _identity));

  Future<void> synchronize() async {
    await flush();
    if (overallState.status != DriveSyncStatus.conflict) await pull();
  }

  Future<void> resolveKeepLocal(DrivePath path) =>
      _run(() => engine.resolveConflictKeepLocal(scope, _identity, path));

  Future<void> resolveAcceptRemote(DrivePath path) =>
      _run(() => engine.resolveConflictAcceptRemote(scope, _identity, path));

  Future<void> _run(Future<DriveWorkspaceSnapshot> Function() action) async {
    try {
      _snapshot = await action();
      lastError = null;
    } catch (error) {
      await refresh();
      lastError = error;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  String? _detailsFor(DriveSyncStatus status) {
    for (final file in _snapshot?.files.values ?? const <DriveFileState>[]) {
      if (file.status == status) return file.providerDetails;
    }
    return null;
  }
}
