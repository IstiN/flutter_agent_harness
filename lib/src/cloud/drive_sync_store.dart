import 'dart:convert';
import 'dart:typed_data';

import 'drive_contract.dart';

/// Durable self-contained mutation. Bytes are stored with the operation so a
/// later local edit cannot change the payload retried under the same key.
final class DriveOperationRecord {
  const DriveOperationRecord({
    required this.operationId,
    required this.path,
    required this.bytes,
    required this.sha256,
    required this.fingerprint,
    required this.baseRevision,
    required this.localRevision,
    required this.authGeneration,
    required this.createdAt,
    this.delete = false,
  });

  final String operationId;
  final DrivePath path;
  final Uint8List bytes;
  final String sha256;
  final String fingerprint;
  final String? baseRevision;
  final int localRevision;
  final int authGeneration;
  final DateTime createdAt;
  final bool delete;

  DriveOperationRecord rebase(String? revision) => DriveOperationRecord(
    operationId: operationId,
    path: path,
    bytes: bytes,
    sha256: sha256,
    fingerprint: fingerprint,
    baseRevision: revision,
    localRevision: localRevision,
    authGeneration: authGeneration,
    createdAt: createdAt,
    delete: delete,
  );

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'path': path.absolute,
    'bytes': base64Encode(bytes),
    'sha256': sha256,
    'fingerprint': fingerprint,
    'baseRevision': baseRevision,
    'localRevision': localRevision,
    'authGeneration': authGeneration,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'delete': delete,
  };

  factory DriveOperationRecord.fromJson(Map<String, Object?> json) {
    final path = DrivePath.parse(json['path']! as String);
    final bytes = Uint8List.fromList(base64Decode(json['bytes']! as String));
    final sha = json['sha256']! as String;
    if (cryptoSha256(bytes) != sha) {
      throw const FormatException('pending drive operation hash mismatch');
    }
    return DriveOperationRecord(
      operationId: json['operationId']! as String,
      path: path,
      bytes: bytes,
      sha256: sha,
      fingerprint: json['fingerprint']! as String,
      baseRevision: json['baseRevision'] as String?,
      localRevision: json['localRevision']! as int,
      authGeneration: json['authGeneration']! as int,
      createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
      delete: json['delete']! as bool,
    );
  }
}

final class DriveFileState {
  const DriveFileState({
    required this.collisionKey,
    required this.localRevision,
    this.localSha256,
    this.remoteRevision,
    this.remoteSha256,
    this.status = DriveSyncStatus.localOnly,
    this.dirty = false,
    this.providerDetails,
    this.retryAt,
    this.lastSyncedAt,
  });

  final String collisionKey;
  final int localRevision;
  final String? localSha256;
  final String? remoteRevision;
  final String? remoteSha256;
  final DriveSyncStatus status;
  final bool dirty;
  final String? providerDetails;
  final DateTime? retryAt;
  final DateTime? lastSyncedAt;

  DriveFileState copyWith({
    int? localRevision,
    String? localSha256,
    String? remoteRevision,
    String? remoteSha256,
    DriveSyncStatus? status,
    bool? dirty,
    String? providerDetails,
    DateTime? retryAt,
    DateTime? lastSyncedAt,
  }) => DriveFileState(
    collisionKey: collisionKey,
    localRevision: localRevision ?? this.localRevision,
    localSha256: localSha256 ?? this.localSha256,
    remoteRevision: remoteRevision ?? this.remoteRevision,
    remoteSha256: remoteSha256 ?? this.remoteSha256,
    status: status ?? this.status,
    dirty: dirty ?? this.dirty,
    providerDetails: providerDetails ?? this.providerDetails,
    retryAt: retryAt ?? this.retryAt,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );

  Map<String, Object?> toJson() => {
    'collisionKey': collisionKey,
    'localRevision': localRevision,
    'localSha256': localSha256,
    'remoteRevision': remoteRevision,
    'remoteSha256': remoteSha256,
    'status': status.name,
    'dirty': dirty,
    'providerDetails': providerDetails,
    'retryAt': retryAt?.toUtc().toIso8601String(),
    'lastSyncedAt': lastSyncedAt?.toUtc().toIso8601String(),
  };

  factory DriveFileState.fromJson(Map<String, Object?> json) => DriveFileState(
    collisionKey: json['collisionKey']! as String,
    localRevision: json['localRevision']! as int,
    localSha256: json['localSha256'] as String?,
    remoteRevision: json['remoteRevision'] as String?,
    remoteSha256: json['remoteSha256'] as String?,
    status: DriveSyncStatus.values.byName(json['status']! as String),
    dirty: json['dirty']! as bool,
    providerDetails: json['providerDetails'] as String?,
    retryAt: json['retryAt'] is String
        ? DateTime.parse(json['retryAt']! as String).toUtc()
        : null,
    lastSyncedAt: json['lastSyncedAt'] is String
        ? DateTime.parse(json['lastSyncedAt']! as String).toUtc()
        : null,
  );
}

/// Atomic browser-store envelope. [storageRevision] is the CAS version,
/// incremented by the store on every successful write.
final class DriveWorkspaceSnapshot {
  const DriveWorkspaceSnapshot({
    required this.scopeKey,
    required this.storageRevision,
    required this.nextLocalRevision,
    required this.files,
    required this.pending,
    this.cursor,
  });

  factory DriveWorkspaceSnapshot.empty(String scopeKey) =>
      DriveWorkspaceSnapshot(
        scopeKey: scopeKey,
        storageRevision: 0,
        nextLocalRevision: 1,
        files: const {},
        pending: const [],
      );

  static const schemaVersion = 1;

  final String scopeKey;
  final int storageRevision;
  final int nextLocalRevision;
  final Map<String, DriveFileState> files;
  final List<DriveOperationRecord> pending;
  final String? cursor;

  DriveWorkspaceSnapshot copyWith({
    int? storageRevision,
    int? nextLocalRevision,
    Map<String, DriveFileState>? files,
    List<DriveOperationRecord>? pending,
    String? cursor,
  }) => DriveWorkspaceSnapshot(
    scopeKey: scopeKey,
    storageRevision: storageRevision ?? this.storageRevision,
    nextLocalRevision: nextLocalRevision ?? this.nextLocalRevision,
    files: files ?? this.files,
    pending: pending ?? this.pending,
    cursor: cursor ?? this.cursor,
  );

  Map<String, Object?> payloadJson() => {
    'schemaVersion': schemaVersion,
    'scopeKey': scopeKey,
    'nextLocalRevision': nextLocalRevision,
    'files': {
      for (final entry in files.entries) entry.key: entry.value.toJson(),
    },
    'pending': pending.map((operation) => operation.toJson()).toList(),
    'cursor': cursor,
  };

  factory DriveWorkspaceSnapshot.fromPayload(
    Map<String, Object?> json, {
    required int storageRevision,
  }) {
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException('unsupported drive snapshot schema');
    }
    final files = <String, DriveFileState>{};
    final rawFiles = json['files']! as Map;
    for (final entry in rawFiles.entries) {
      files[entry.key as String] = DriveFileState.fromJson(
        (entry.value as Map).cast<String, Object?>(),
      );
    }
    return DriveWorkspaceSnapshot(
      scopeKey: json['scopeKey']! as String,
      storageRevision: storageRevision,
      nextLocalRevision: json['nextLocalRevision']! as int,
      files: files,
      pending: (json['pending']! as List)
          .map(
            (raw) => DriveOperationRecord.fromJson(
              (raw as Map).cast<String, Object?>(),
            ),
          )
          .toList(),
      cursor: json['cursor'] as String?,
    );
  }
}

final class DriveStoreConcurrencyException implements Exception {
  const DriveStoreConcurrencyException(this.scopeKey);
  final String scopeKey;
}

abstract interface class DriveSyncStore {
  Future<DriveWorkspaceSnapshot> load(String scopeKey);

  /// Atomically compares [expectedStorageRevision] and persists the payload.
  /// Implementations must clone bytes/maps so callers cannot mutate history.
  Future<DriveWorkspaceSnapshot> save(
    DriveWorkspaceSnapshot snapshot, {
    required int expectedStorageRevision,
  });
}

final class MemoryDriveSyncStore implements DriveSyncStore {
  final Map<String, Map<String, Object?>> _records = {};

  @override
  Future<DriveWorkspaceSnapshot> load(String scopeKey) async {
    final record = _records[scopeKey];
    if (record == null) return DriveWorkspaceSnapshot.empty(scopeKey);
    final revision = record['storageRevision']! as int;
    final payload = (record['payload']! as Map).cast<String, Object?>();
    return DriveWorkspaceSnapshot.fromPayload(
      _clone(payload),
      storageRevision: revision,
    );
  }

  @override
  Future<DriveWorkspaceSnapshot> save(
    DriveWorkspaceSnapshot snapshot, {
    required int expectedStorageRevision,
  }) async {
    final current =
        _records[snapshot.scopeKey]?['storageRevision'] as int? ?? 0;
    if (current != expectedStorageRevision ||
        snapshot.storageRevision != expectedStorageRevision) {
      throw DriveStoreConcurrencyException(snapshot.scopeKey);
    }
    final revision = expectedStorageRevision + 1;
    final payload = _clone(snapshot.payloadJson());
    _records[snapshot.scopeKey] = {
      'storageRevision': revision,
      'payload': payload,
    };
    return DriveWorkspaceSnapshot.fromPayload(
      _clone(payload),
      storageRevision: revision,
    );
  }

  static Map<String, Object?> _clone(Map<String, Object?> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
}
