import 'dart:async';

import '../exceptions.dart';
import '../session/session_record.dart';
import '../session/session_repo.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import 'cloud_session_synchronizer.dart';

/// SessionRepo decorator: every local operation completes first. Cloud work
/// rides the storage append hook and an explicit background flush/pull.
final class CloudSessionRepo implements SessionRepo {
  const CloudSessionRepo(this.local, this.synchronizer);

  final SessionRepo local;
  final CloudSessionSynchronizer synchronizer;

  @override
  Future<Session> create(JsonlSessionCreateOptions options) async {
    final session = await local.create(options);
    final metadata = await session.getMetadata();
    _markDirty(metadata);
    return _wrap(session, metadata);
  }

  @override
  Future<Session> open(
    SessionMetadata metadata, {
    bool windowed = false,
    bool wholeFileOnly = false,
  }) async {
    try {
      final session = await local.open(
        metadata,
        windowed: windowed,
        wholeFileOnly: wholeFileOnly,
      );
      return _wrap(session, await session.getMetadata());
    } on SessionException catch (error) {
      if (error.code != SessionErrorCode.notFound) rethrow;
      var snapshot = await synchronizer
          .pull(synchronizer.scope.identity)
          .timeout(synchronizer.remoteReadTimeout);
      var localMetadata = await synchronizer.localMetadata(metadata.id);
      while (localMetadata == null && snapshot.cursor != null) {
        snapshot = await synchronizer
            .pull(synchronizer.scope.identity)
            .timeout(synchronizer.remoteReadTimeout);
        localMetadata = await synchronizer.localMetadata(metadata.id);
      }
      if (localMetadata == null) rethrow;
      final session = await local.open(
        localMetadata,
        windowed: windowed,
        wholeFileOnly: wholeFileOnly,
      );
      return _wrap(session, await session.getMetadata());
    }
  }

  @override
  Future<List<SessionMetadata>> list({String? cwd}) => local.list(cwd: cwd);

  /// Local delete stays local by design: closing a branch on one device must
  /// not tombstone a shared tree on every other device.
  @override
  Future<void> delete(SessionMetadata metadata, {String actor = 'unknown'}) =>
      local.delete(metadata, actor: actor);

  /// Explicit opt-in remote tombstone, separate from local delete.
  Future<void> closeRemoteBranch(SessionMetadata metadata) =>
      synchronizer.enqueueRemoteDelete(metadata);

  @override
  Future<Session> fork(
    SessionMetadata source, {
    required String cwd,
    String? entryId,
    ForkPosition position = ForkPosition.before,
    String? id,
    String? parentSessionPath,
    Map<String, dynamic>? metadata,
  }) async {
    final session = await local.fork(
      source,
      cwd: cwd,
      entryId: entryId,
      position: position,
      id: id,
      parentSessionPath: parentSessionPath,
      metadata: metadata,
    );
    final forked = await session.getMetadata();
    _markDirty(forked, parentSessionId: source.id);
    return _wrap(session, forked);
  }

  Session _wrap(Session session, SessionMetadata metadata) =>
      session.decorateStorage(
        (storage) =>
            CloudSessionStorage(storage, onChanged: () => _markDirty(metadata)),
      );

  void _markDirty(SessionMetadata metadata, {String? parentSessionId}) {
    unawaited(
      synchronizer.markDirty(metadata, parentSessionId: parentSessionId),
    );
  }
}

final class CloudSessionStorage implements SessionStorage {
  const CloudSessionStorage(this.delegate, {required this.onChanged});

  final SessionStorage delegate;
  final void Function() onChanged;

  @override
  Future<void> appendEntry(SessionRecord record) async {
    await delegate.appendEntry(record);
    onChanged();
  }

  @override
  Future<void> setLeafId(String? leafId) async {
    await delegate.setLeafId(leafId);
    onChanged();
  }

  @override
  Future<String> createEntryId() => delegate.createEntryId();
  @override
  Future<List<SessionRecord>> findEntries(String type) =>
      delegate.findEntries(type);
  @override
  Future<SessionRecord?> getEntry(String id) => delegate.getEntry(id);
  @override
  Future<List<SessionRecord>> getEntries() => delegate.getEntries();
  @override
  Future<String?> getLabel(String id) => delegate.getLabel(id);
  @override
  Future<String?> getLeafId() => delegate.getLeafId();
  @override
  Future<SessionMetadata> getMetadata() => delegate.getMetadata();
  @override
  Future<List<SessionRecord>> getPathToRoot(String? leafId) =>
      delegate.getPathToRoot(leafId);
}
