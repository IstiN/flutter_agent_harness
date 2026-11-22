import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../env/execution_env.dart';
import '../product/fa_product_config.dart';
import '../session/session_record.dart';
import '../session/session_repo.dart';
import '../session/session_storage.dart';
import 'drive_contract.dart';
import 'session_sync_contract.dart';

/// Append-only JSONL tree synchronizer. Local files/outbox are authoritative
/// while offline; remote revisions are conditional and record ids, never
/// mtimes, drive the three-way merge.
final class CloudSessionSynchronizer {
  CloudSessionSynchronizer({
    required this.provider,
    required this.store,
    required this.localRepo,
    required this.env,
    required this.scope,
    this.remoteReadTimeout = const Duration(seconds: 12),
    String Function()? operationId,
  }) : operationId = operationId ?? _operationId;

  final RemoteSessionProvider provider;
  final CloudSessionSyncStore store;
  final SessionRepo localRepo;
  final ExecutionEnv env;
  final CloudSessionScope scope;
  final Duration remoteReadTimeout;
  final String Function() operationId;
  final Map<String, Future<void>> _dirtyChains = {};
  Object? lastDirtyError;

  /// Queues the latest complete local JSONL bytes. Callers may fire-and-forget
  /// this after the local append; [settle] makes the durable boundary explicit
  /// in tests and background flush scheduling.
  Future<void> markDirty(SessionMetadata metadata, {String? parentSessionId}) {
    final previous = _dirtyChains[metadata.id] ?? Future<void>.value();
    final result = previous.then(
      (_) => _markDirtyNow(metadata, parentSessionId),
    );
    _dirtyChains[metadata.id] = result.catchError((Object error) {
      lastDirtyError = error;
    });
    return result;
  }

  Future<void> settle() async {
    await Future.wait(_dirtyChains.values);
    final error = lastDirtyError;
    if (error != null) throw error;
  }

  Future<void> _markDirtyNow(
    SessionMetadata metadata,
    String? parentSessionId,
  ) async {
    final bytes = (await env.readBinaryFile(metadata.path)).getOrThrow();
    _validateDocument(bytes, expectedId: metadata.id);
    var snapshot = await store.load(scope.scopeKey);
    final parent = parentSessionId ?? _parentId(snapshot, metadata);
    // Coalesce not-yet-attempted writes for this session. Each operation keeps
    // its own bytes/fingerprint; an in-flight retry keeps its original key.
    final pending = snapshot.pending
        .where((op) => op.sessionId != metadata.id || op.delete)
        .toList();
    pending.add(
      CloudSessionOperation(
        sessionId: metadata.id,
        parentSessionId: parent,
        localPath: metadata.path,
        bytes: bytes,
        operationId: operationId(),
        baseRevision: snapshot.remoteRevisions[metadata.id],
        authGeneration: scope.identity.authGeneration,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    final paths = {...snapshot.localPaths, metadata.id: metadata.path};
    await store.save(
      snapshot.copyWith(pending: pending, localPaths: paths),
      expectedStorageRevision: snapshot.storageRevision,
    );
  }

  Future<CloudSessionSnapshot> enqueueRemoteDelete(
    SessionMetadata metadata,
  ) async {
    var snapshot = await store.load(scope.scopeKey);
    snapshot = await store.save(
      snapshot.copyWith(
        pending: [
          ...snapshot.pending,
          CloudSessionOperation(
            sessionId: metadata.id,
            parentSessionId: null,
            localPath: metadata.path,
            bytes: Uint8List(0),
            operationId: operationId(),
            baseRevision: snapshot.remoteRevisions[metadata.id],
            authGeneration: scope.identity.authGeneration,
            createdAt: DateTime.now().toUtc(),
            delete: true,
          ),
        ],
      ),
      expectedStorageRevision: snapshot.storageRevision,
    );
    return snapshot;
  }

  Future<CloudSessionSnapshot> flush(CloudIdentity identity) async {
    _checkIdentity(identity);
    await settle();
    var snapshot = await store.load(scope.scopeKey);
    while (snapshot.pending.isNotEmpty) {
      final operation = snapshot.pending.first;
      if (operation.authGeneration != identity.authGeneration) {
        throw const DriveProviderException(
          DriveErrorKind.providerReauthRequired,
          'cloud session operation is fenced by auth generation',
        );
      }
      final result = operation.delete
          ? await provider.delete(
              scope,
              operation.sessionId,
              operation.operationId,
              operation.baseRevision,
              identity.authGeneration,
            )
          : await provider.upload(
              CloudSessionUpload(
                scope: scope,
                sessionId: operation.sessionId,
                parentSessionId: operation.parentSessionId,
                bytes: operation.bytes,
                operationId: operation.operationId,
                baseRevision: operation.baseRevision,
                authGeneration: identity.authGeneration,
              ),
            );
      if (!result.isOk) {
        final error = result.error!;
        if (error.kind == DriveErrorKind.preconditionFailed &&
            !operation.delete) {
          final remote = await provider.download(scope, operation.sessionId);
          if (!remote.isOk) throw remote.error!;
          final merged = mergeSessionJsonl(
            operation.bytes,
            remote.value!.bytes,
            parentSessionPath: snapshot.localPaths[operation.parentSessionId],
            preferRemoteLeaf: false,
          );
          final replacement = operation.copyWith(
            bytes: merged,
            operationId: operationId(),
            baseRevision: remote.value!.record.revision,
            authGeneration: identity.authGeneration,
          );
          final pending = [...snapshot.pending]..[0] = replacement;
          snapshot = await store.save(
            snapshot.copyWith(pending: pending),
            expectedStorageRevision: snapshot.storageRevision,
          );
          await _writeIfCurrent(replacement, operation.bytes);
          continue;
        }
        throw error;
      }
      final pending = [...snapshot.pending]..removeAt(0);
      final revisions = {
        ...snapshot.remoteRevisions,
        operation.sessionId: result.value!.revision,
      };
      snapshot = await store.save(
        snapshot.copyWith(pending: pending, remoteRevisions: revisions),
        expectedStorageRevision: snapshot.storageRevision,
      );
    }
    return snapshot;
  }

  /// Pulls parent documents before forks. Timeout/failure on one remote read
  /// never rewrites or drops local pending bytes; successfully read documents
  /// still advance and the first error is surfaced after the local CAS.
  Future<CloudSessionSnapshot> pull(CloudIdentity identity) async {
    _checkIdentity(identity);
    await settle();
    var snapshot = await store.load(scope.scopeKey);
    snapshot = await _indexLocalPaths(snapshot);
    final records = <CloudSessionRemoteRecord>[];
    String? cursor;
    do {
      final page = await provider.list(scope, cursor);
      if (!page.isOk) throw page.error!;
      records.addAll(page.value!.records);
      cursor = page.value!.hasMore ? page.value!.nextCursor : null;
    } while (cursor != null);

    final ordered = _parentsFirst(records.where((record) => !record.deleted));
    Object? firstReadError;
    for (final record in ordered) {
      if (snapshot.pending.any((op) => op.sessionId == record.sessionId)) {
        continue;
      }
      if (snapshot.remoteRevisions[record.sessionId] == record.revision) {
        continue;
      }
      try {
        final download = await provider
            .download(scope, record.sessionId)
            .timeout(remoteReadTimeout);
        if (!download.isOk) throw download.error!;
        final remoteBytes = download.value!.bytes;
        _validateDocument(remoteBytes, expectedId: record.sessionId);
        if (record.sha256 != null &&
            cryptoSha256(remoteBytes) != record.sha256) {
          throw const DriveProviderException(
            DriveErrorKind.invalidResponse,
            'cloud session bytes do not match provider hash',
          );
        }
        snapshot = await _materialize(snapshot, record, remoteBytes);
      } catch (error) {
        firstReadError ??= error;
      }
    }
    snapshot = await store.save(
      snapshot.copyWith(cursor: cursor),
      expectedStorageRevision: snapshot.storageRevision,
    );
    if (firstReadError != null) throw firstReadError;
    return snapshot;
  }

  Future<SessionMetadata?> localMetadata(String sessionId) async {
    final sessions = await localRepo.list();
    for (final metadata in sessions) {
      if (metadata.id == sessionId) return metadata;
    }
    return null;
  }

  Future<CloudSessionSnapshot> _materialize(
    CloudSessionSnapshot snapshot,
    CloudSessionRemoteRecord record,
    Uint8List remoteBytes,
  ) async {
    final localPath = snapshot.localPaths[record.sessionId];
    var bytes = remoteBytes;
    if (localPath != null && (await env.exists(localPath)).getOrThrow()) {
      final localBytes = (await env.readBinaryFile(localPath)).getOrThrow();
      bytes = mergeSessionJsonl(
        localBytes,
        remoteBytes,
        parentSessionPath: _localParentPath(snapshot, record),
        preferRemoteLeaf: true,
      );
    } else {
      bytes = _rewriteParent(remoteBytes, _localParentPath(snapshot, record));
    }
    var path = localPath;
    if (path == null) {
      final header = sessionDocumentHeader(bytes);
      final parentPath = _localParentPath(snapshot, record);
      final created = await localRepo.create(
        JsonlSessionCreateOptions(
          cwd: header.cwd,
          id: record.sessionId,
          parentSessionPath: parentPath,
          metadata: header.metadata,
        ),
      );
      path = (await created.getMetadata()).path;
    }
    (await env.createDir(_parentPath(path))).getOrThrow();
    (await env.writeBinaryFile(path, bytes)).getOrThrow();
    final revisions = {
      ...snapshot.remoteRevisions,
      record.sessionId: record.revision,
    };
    final paths = {...snapshot.localPaths, record.sessionId: path};
    return store.save(
      snapshot.copyWith(remoteRevisions: revisions, localPaths: paths),
      expectedStorageRevision: snapshot.storageRevision,
    );
  }

  Future<CloudSessionSnapshot> _indexLocalPaths(
    CloudSessionSnapshot snapshot,
  ) async {
    final paths = {...snapshot.localPaths};
    for (final metadata in await localRepo.list()) {
      paths[metadata.id] = metadata.path;
    }
    if (_samePaths(paths, snapshot.localPaths)) return snapshot;
    return store.save(
      snapshot.copyWith(localPaths: paths),
      expectedStorageRevision: snapshot.storageRevision,
    );
  }

  bool _samePaths(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<void> _writeIfCurrent(
    CloudSessionOperation operation,
    Uint8List previousBytes,
  ) async {
    if (!(await env.exists(operation.localPath)).getOrThrow()) return;
    final live = (await env.readBinaryFile(operation.localPath)).getOrThrow();
    if (cryptoSha256(live) != cryptoSha256(previousBytes)) return;
    (await env.writeBinaryFile(
      operation.localPath,
      operation.bytes,
    )).getOrThrow();
  }

  void _checkIdentity(CloudIdentity identity) {
    if (!scope.accepts(identity)) {
      throw const DriveProviderException(
        DriveErrorKind.providerReauthRequired,
        'cloud session identity/auth generation is stale',
      );
    }
  }

  String? _parentId(CloudSessionSnapshot snapshot, SessionMetadata metadata) {
    for (final entry in snapshot.localPaths.entries) {
      if (entry.value == metadata.parentSessionPath) return entry.key;
    }
    return null;
  }

  String? _localParentPath(
    CloudSessionSnapshot snapshot,
    CloudSessionRemoteRecord record,
  ) => snapshot.localPaths[record.parentSessionId];

  static List<CloudSessionRemoteRecord> _parentsFirst(
    Iterable<CloudSessionRemoteRecord> input,
  ) {
    final remaining = input.toList();
    final result = <CloudSessionRemoteRecord>[];
    final seen = <String>{};
    while (remaining.isNotEmpty) {
      final index = remaining.indexWhere(
        (record) =>
            record.parentSessionId == null ||
            seen.contains(record.parentSessionId),
      );
      if (index < 0) {
        // Closed/missing parents are a supported local-only exception; retain
        // deterministic input order instead of deadlocking the walk.
        result.addAll(remaining);
        break;
      }
      final record = remaining.removeAt(index);
      seen.add(record.sessionId);
      result.add(record);
    }
    return result;
  }

  static String _operationId() =>
      'session-op-${DateTime.now().microsecondsSinceEpoch}';
  static String _parentPath(String path) =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '.';
}

final class _ParsedDocument {
  const _ParsedDocument(this.header, this.records, this.lines);
  final SessionHeader header;
  final List<SessionRecord> records;
  final List<String> lines;
}

void _validateDocument(Uint8List bytes, {required String expectedId}) {
  final parsed = _parse(bytes);
  if (parsed.header.id != expectedId) {
    throw const FormatException('cloud session id/header mismatch');
  }
}

SessionHeader sessionDocumentHeader(Uint8List bytes) => _parse(bytes).header;

/// Merges the record-id union and optionally moves the active pointer to the
/// remote leaf with an explicit sync marker. No timestamps are compared.
Uint8List mergeSessionJsonl(
  Uint8List localBytes,
  Uint8List remoteBytes, {
  String? parentSessionPath,
  bool preferRemoteLeaf = false,
}) {
  final local = _parse(localBytes);
  final remote = _parse(remoteBytes);
  if (local.header.id != remote.header.id) {
    throw const FormatException('cannot merge different session ids');
  }
  final header = SessionHeader(
    id: local.header.id,
    timestamp: local.header.timestamp,
    cwd: local.header.cwd,
    parentSessionPath: parentSessionPath ?? local.header.parentSessionPath,
    metadata: local.header.metadata,
  );
  final ids = local.records.map((record) => record.id).toSet();
  final lines = [...local.lines];
  for (var i = 0; i < remote.records.length; i++) {
    if (ids.add(remote.records[i].id)) lines.add(remote.lines[i]);
  }
  if (preferRemoteLeaf &&
      _activeLeaf(local.records) != _activeLeaf(remote.records)) {
    final target = _activeLeaf(remote.records);
    final marker = LeafRecord(
      id: 'cloud-sync-${cryptoSha256(remoteBytes).substring(0, 16)}',
      parentId: target,
      timestamp: DateTime.utc(2026, 1, 1),
      targetId: target,
    );
    if (ids.add(marker.id)) lines.add(jsonEncode(marker.toJson()));
  }
  return Uint8List.fromList(
    utf8.encode('${jsonEncode(header.toJson())}\n${lines.join('\n')}\n'),
  );
}

Uint8List _rewriteParent(Uint8List bytes, String? parentPath) {
  final parsed = _parse(bytes);
  final header = SessionHeader(
    id: parsed.header.id,
    timestamp: parsed.header.timestamp,
    cwd: parsed.header.cwd,
    parentSessionPath: parentPath,
    metadata: parsed.header.metadata,
  );
  return Uint8List.fromList(
    utf8.encode('${jsonEncode(header.toJson())}\n${parsed.lines.join('\n')}\n'),
  );
}

String? _activeLeaf(List<SessionRecord> records) {
  String? leaf;
  for (final record in records) {
    leaf = leafIdAfterSessionRecord(record);
  }
  return leaf;
}

_ParsedDocument _parse(Uint8List bytes) {
  final source = utf8.decode(bytes);
  final lines = const LineSplitter().convert(source);
  if (lines.isEmpty) throw const FormatException('empty cloud session');
  final header = SessionHeader.fromJson(
    (jsonDecode(lines.first) as Map).cast<String, dynamic>(),
  );
  final records = <SessionRecord>[];
  final recordLines = <String>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    records.add(
      SessionRecord.fromJson((jsonDecode(line) as Map).cast<String, dynamic>()),
    );
    recordLines.add(line);
  }
  return _ParsedDocument(header, records, recordLines);
}
