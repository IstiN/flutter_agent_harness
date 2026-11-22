import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../product/fa_product_config.dart';
import 'drive_contract.dart';

final class CloudSessionScope {
  const CloudSessionScope({
    required this.providerId,
    required this.connectionId,
    required this.identity,
  });

  final String providerId;
  final String connectionId;
  final CloudIdentity identity;

  String get scopeKey {
    identity.validate();
    return sha256
        .convert(
          utf8.encode(
            '$providerId\u0000$connectionId\u0000${identity.accountKey}',
          ),
        )
        .toString();
  }

  bool accepts(CloudIdentity candidate) => identity.canWriteFor(candidate);
}

final class CloudSessionRemoteRecord {
  const CloudSessionRemoteRecord({
    required this.sessionId,
    required this.parentSessionId,
    required this.revision,
    required this.sha256,
    required this.size,
    this.deleted = false,
  });

  final String sessionId;
  final String? parentSessionId;
  final String revision;
  final String? sha256;
  final int size;
  final bool deleted;
}

final class CloudSessionDownload {
  const CloudSessionDownload({required this.record, required this.bytes});
  final CloudSessionRemoteRecord record;
  final Uint8List bytes;
}

final class CloudSessionUpload {
  CloudSessionUpload({
    required this.scope,
    required this.sessionId,
    required this.parentSessionId,
    required this.bytes,
    required this.operationId,
    required this.baseRevision,
    required this.authGeneration,
  }) : sha256 = cryptoSha256(bytes);

  final CloudSessionScope scope;
  final String sessionId;
  final String? parentSessionId;
  final Uint8List bytes;
  final String operationId;
  final String? baseRevision;
  final int authGeneration;
  final String sha256;

  String get fingerprint => cryptoSha256(
    utf8.encode(
      '${scope.scopeKey}\n$sessionId\n$sha256\n${baseRevision ?? ''}\n${parentSessionId ?? ''}',
    ),
  );
}

final class CloudSessionPage {
  const CloudSessionPage({
    required this.records,
    this.nextCursor,
    this.hasMore = false,
  });
  final List<CloudSessionRemoteRecord> records;
  final String? nextCursor;
  final bool hasMore;
}

abstract interface class RemoteSessionProvider {
  String get providerId;
  Future<DriveResult<CloudSessionPage>> list(
    CloudSessionScope scope,
    String? cursor,
  );
  Future<DriveResult<CloudSessionDownload>> download(
    CloudSessionScope scope,
    String sessionId,
  );
  Future<DriveResult<CloudSessionRemoteRecord>> upload(
    CloudSessionUpload upload,
  );
  Future<DriveResult<CloudSessionRemoteRecord>> delete(
    CloudSessionScope scope,
    String sessionId,
    String operationId,
    String? baseRevision,
    int authGeneration,
  );
}

/// Validated, read-only share grant returned by a host backend. The link
/// carries expiry and server-side read caps, never account/cache credentials.
final class CloudSessionShareLink {
  factory CloudSessionShareLink.parse(
    Uri uri, {
    required Set<String> allowedHosts,
    DateTime? now,
  }) {
    final segments = uri.pathSegments;
    final query = uri.queryParameters;
    final capabilities = (query['capabilities'] ?? 'read')
        .split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    final expiry = DateTime.tryParse(query['expires'] ?? '');
    final maxReads = int.tryParse(query['maxReads'] ?? '');
    if (uri.scheme != 'https' ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        !allowedHosts.contains(uri.host) ||
        segments.length != 3 ||
        segments[0] != 'share' ||
        segments[1] != 'sessions' ||
        !RegExp(r'^[A-Za-z0-9-]{6,64}$').hasMatch(segments[2]) ||
        expiry == null ||
        maxReads == null ||
        maxReads < 1 ||
        maxReads > 10000 ||
        !capabilities.every((capability) => capability == 'read') ||
        query.keys.any(
          (key) => !const {'expires', 'maxReads', 'capabilities'}.contains(key),
        )) {
      throw const FormatException(
        'invalid cloud session share link/capabilities',
      );
    }
    return CloudSessionShareLink._(
      uri,
      segments[2],
      expiry.toUtc(),
      maxReads,
      Set.unmodifiable(capabilities),
    );
  }

  const CloudSessionShareLink._(
    this.uri,
    this.sessionId,
    this.expiresAt,
    this.maxReads,
    this.capabilities,
  );

  final Uri uri;
  final String sessionId;
  final DateTime expiresAt;
  final int maxReads;
  final Set<String> capabilities;

  bool allowsReadAt(DateTime instant) =>
      capabilities.contains('read') && instant.toUtc().isBefore(expiresAt);
}

final class CloudSessionOperation {
  const CloudSessionOperation({
    required this.sessionId,
    required this.parentSessionId,
    required this.localPath,
    required this.bytes,
    required this.operationId,
    required this.baseRevision,
    required this.authGeneration,
    required this.createdAt,
    this.delete = false,
  });

  final String sessionId;
  final String? parentSessionId;
  final String localPath;
  final Uint8List bytes;
  final String operationId;
  final String? baseRevision;
  final int authGeneration;
  final DateTime createdAt;
  final bool delete;

  CloudSessionOperation copyWith({
    Uint8List? bytes,
    String? operationId,
    String? baseRevision,
    int? authGeneration,
  }) => CloudSessionOperation(
    sessionId: sessionId,
    parentSessionId: parentSessionId,
    localPath: localPath,
    bytes: bytes ?? this.bytes,
    operationId: operationId ?? this.operationId,
    baseRevision: baseRevision ?? this.baseRevision,
    authGeneration: authGeneration ?? this.authGeneration,
    createdAt: createdAt,
    delete: delete,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'parentSessionId': parentSessionId,
    'localPath': localPath,
    'bytes': base64Encode(bytes),
    'operationId': operationId,
    'baseRevision': baseRevision,
    'authGeneration': authGeneration,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'delete': delete,
  };

  factory CloudSessionOperation.fromJson(Map<String, Object?> json) {
    final bytes = Uint8List.fromList(base64Decode(json['bytes']! as String));
    return CloudSessionOperation(
      sessionId: json['sessionId']! as String,
      parentSessionId: json['parentSessionId'] as String?,
      localPath: json['localPath']! as String,
      bytes: bytes,
      operationId: json['operationId']! as String,
      baseRevision: json['baseRevision'] as String?,
      authGeneration: json['authGeneration']! as int,
      createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
      delete: json['delete']! as bool,
    );
  }
}

final class CloudSessionSnapshot {
  const CloudSessionSnapshot({
    required this.scopeKey,
    required this.storageRevision,
    required this.pending,
    required this.remoteRevisions,
    required this.localPaths,
    this.cursor,
  });

  factory CloudSessionSnapshot.empty(String scopeKey) => CloudSessionSnapshot(
    scopeKey: scopeKey,
    storageRevision: 0,
    pending: const [],
    remoteRevisions: const {},
    localPaths: const {},
  );

  final String scopeKey;
  final int storageRevision;
  final List<CloudSessionOperation> pending;
  final Map<String, String> remoteRevisions;
  final Map<String, String> localPaths;
  final String? cursor;

  CloudSessionSnapshot copyWith({
    List<CloudSessionOperation>? pending,
    Map<String, String>? remoteRevisions,
    Map<String, String>? localPaths,
    String? cursor,
  }) => CloudSessionSnapshot(
    scopeKey: scopeKey,
    storageRevision: storageRevision,
    pending: pending ?? this.pending,
    remoteRevisions: remoteRevisions ?? this.remoteRevisions,
    localPaths: localPaths ?? this.localPaths,
    cursor: cursor ?? this.cursor,
  );

  Map<String, Object?> payloadJson() => {
    'schemaVersion': 1,
    'scopeKey': scopeKey,
    'pending': pending.map((op) => op.toJson()).toList(),
    'remoteRevisions': remoteRevisions,
    'localPaths': localPaths,
    'cursor': cursor,
  };

  factory CloudSessionSnapshot.fromPayload(
    Map<String, Object?> json, {
    required int storageRevision,
  }) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('unsupported cloud session snapshot');
    }
    return CloudSessionSnapshot(
      scopeKey: json['scopeKey']! as String,
      storageRevision: storageRevision,
      pending: (json['pending']! as List)
          .map(
            (raw) => CloudSessionOperation.fromJson(
              (raw as Map).cast<String, Object?>(),
            ),
          )
          .toList(),
      remoteRevisions: (json['remoteRevisions']! as Map).cast<String, String>(),
      localPaths: (json['localPaths']! as Map).cast<String, String>(),
      cursor: json['cursor'] as String?,
    );
  }
}

final class CloudSessionStoreConcurrencyException implements Exception {
  const CloudSessionStoreConcurrencyException(this.scopeKey);
  final String scopeKey;
}

abstract interface class CloudSessionSyncStore {
  Future<CloudSessionSnapshot> load(String scopeKey);
  Future<CloudSessionSnapshot> save(
    CloudSessionSnapshot snapshot, {
    required int expectedStorageRevision,
  });
}

final class MemoryCloudSessionSyncStore implements CloudSessionSyncStore {
  final Map<String, Map<String, Object?>> _records = {};

  @override
  Future<CloudSessionSnapshot> load(String scopeKey) async {
    final record = _records[scopeKey];
    if (record == null) return CloudSessionSnapshot.empty(scopeKey);
    return CloudSessionSnapshot.fromPayload(
      _clone((record['payload']! as Map).cast<String, Object?>()),
      storageRevision: record['storageRevision']! as int,
    );
  }

  @override
  Future<CloudSessionSnapshot> save(
    CloudSessionSnapshot snapshot, {
    required int expectedStorageRevision,
  }) async {
    final current =
        _records[snapshot.scopeKey]?['storageRevision'] as int? ?? 0;
    if (current != expectedStorageRevision ||
        snapshot.storageRevision != expectedStorageRevision) {
      throw CloudSessionStoreConcurrencyException(snapshot.scopeKey);
    }
    final revision = expectedStorageRevision + 1;
    final payload = _clone(snapshot.payloadJson());
    _records[snapshot.scopeKey] = {
      'storageRevision': revision,
      'payload': payload,
    };
    return CloudSessionSnapshot.fromPayload(
      _clone(payload),
      storageRevision: revision,
    );
  }

  static Map<String, Object?> _clone(Map<String, Object?> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
}
