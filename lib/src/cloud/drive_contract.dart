import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../product/fa_product_config.dart';

/// Provider/account-scoped mount identity. Cache cursors and idempotency keys
/// MUST be partitioned by [mountKey], never shared across tenants/providers.
final class DriveMountScope {
  const DriveMountScope({
    required this.providerId,
    required this.connectionId,
    required this.tenantId,
    required this.subject,
    this.mount = '/drive',
  });

  factory DriveMountScope.forIdentity({
    required String providerId,
    required String connectionId,
    required CloudIdentity identity,
    String mount = '/drive',
  }) {
    identity.validate();
    return DriveMountScope(
      providerId: providerId,
      connectionId: connectionId,
      tenantId: identity.tenantId,
      subject: identity.subject,
      mount: mount,
    );
  }

  final String providerId;
  final String connectionId;
  final String tenantId;
  final String subject;
  final String mount;

  String get mountKey {
    _validateIds();
    return sha256
        .convert(
          utf8.encode(
            '$providerId\u0000$connectionId\u0000$tenantId\u0000$subject\u0000$mount',
          ),
        )
        .toString();
  }

  void _validateIds() {
    for (final value in [providerId, connectionId, tenantId, subject, mount]) {
      if (value.isEmpty || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const FormatException('invalid drive mount scope');
      }
    }
    if (subject.contains('@')) {
      throw const FormatException('drive scope subject must not be email');
    }
  }
}

/// Normalized absolute POSIX path rooted at /drive or an explicit host alias.
final class DrivePath {
  factory DrivePath.parse(String input, {Set<String> aliases = const {}}) {
    if (input.isEmpty || !input.startsWith('/')) {
      throw const FormatException('drive path must be absolute');
    }
    final normalizedInput = unorm.nfc(input);
    final roots = ['/drive', ...aliases].toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final root = roots.cast<String?>().firstWhere(
      (candidate) =>
          normalizedInput == candidate ||
          normalizedInput.startsWith('$candidate/'),
      orElse: () => null,
    );
    if (root == null) {
      throw FormatException('path is outside /drive and host aliases: $input');
    }
    if (!_validRoot(root)) throw FormatException('invalid drive alias: $root');
    final tail = normalizedInput.substring(root.length);
    final rawSegments = tail.isEmpty
        ? <String>[]
        : tail.substring(1).split('/');
    final segments = <String>[];
    for (final raw in rawSegments) {
      final segment = unorm.nfc(raw);
      _validateSegment(segment);
      segments.add(segment);
    }
    return DrivePath._(root, List.unmodifiable(segments));
  }

  const DrivePath._(this.root, this.segments);

  final String root;
  final List<String> segments;

  String get relativePath => segments.join('/');
  String get absolute => '$root${segments.isEmpty ? '' : '/$relativePath'}';
  String get collisionKey => absolute.toLowerCase();
  bool get isRoot => segments.isEmpty;
  String? get name => segments.isEmpty ? null : segments.last;
  DrivePath get parent => isRoot
      ? this
      : DrivePath._(root, segments.take(segments.length - 1).toList());

  DrivePath child(String name) {
    _validateSegment(unorm.nfc(name));
    return DrivePath._(root, [...segments, unorm.nfc(name)]);
  }

  static bool _validRoot(String root) =>
      RegExp(r'^/[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(root);

  static void _validateSegment(String segment) {
    if (segment.isEmpty || segment == '.' || segment == '..') {
      throw const FormatException('empty/dotted drive path segment');
    }
    if (segment.contains(RegExp(r'[\x00-\x1f\x7f\\/]'))) {
      throw const FormatException('ambiguous drive path separator/control');
    }
    if (segment.endsWith('.') || segment.endsWith(' ')) {
      throw const FormatException('non-portable drive path segment');
    }
    final lower = segment.toLowerCase();
    final stem = lower.split('.').first;
    if (const ['con', 'prn', 'aux', 'nul', 'com1', 'lpt1'].contains(stem)) {
      throw const FormatException('reserved device name in drive path');
    }
    final sensitive =
        lower == '.env' ||
        lower.startsWith('.env.') ||
        lower == '.dap' ||
        lower == '.git' ||
        lower == 'logs' ||
        lower == 'log' ||
        lower == 'wallets' ||
        lower == 'wallet' ||
        lower == 'oauth' ||
        lower == 'saved_keys' ||
        lower == 'saved-keys' ||
        lower.endsWith('.pem') ||
        lower.endsWith('.key') ||
        lower.contains('secret') ||
        lower.contains('credential') ||
        lower.contains('refresh_token') ||
        lower.contains('access_token');
    if (sensitive) {
      throw FormatException('sensitive path is not drive-syncable: $segment');
    }
  }
}

/// Provider capabilities are declared, never inferred from HTTP success.
final class DriveCapabilities {
  const DriveCapabilities({
    required this.deltaCursors,
    required this.conditionalWrites,
    required this.revisions,
    required this.hashes,
    required this.move,
    required this.trash,
    required this.maxFileBytes,
  });

  const DriveCapabilities.none()
    : deltaCursors = false,
      conditionalWrites = false,
      revisions = false,
      hashes = false,
      move = false,
      trash = false,
      maxFileBytes = 0;

  final bool deltaCursors;
  final bool conditionalWrites;
  final bool revisions;
  final bool hashes;
  final bool move;
  final bool trash;
  final int maxFileBytes;

  void requireUpload(int bytes) {
    if (bytes < 0 || bytes > maxFileBytes) {
      throw DriveProviderException(
        DriveErrorKind.quotaExceeded,
        'file exceeds provider limit ($bytes > $maxFileBytes)',
      );
    }
  }
}

final class RemoteDriveItem {
  const RemoteDriveItem({
    required this.path,
    required this.revision,
    required this.sha256,
    required this.size,
    required this.modifiedAt,
    this.isDirectory = false,
    this.deleted = false,
    this.etag,
  });

  final DrivePath path;
  final String? revision;
  final String? sha256;
  final int size;
  final DateTime modifiedAt;
  final bool isDirectory;
  final bool deleted;
  final String? etag;
}

final class DriveUploadRequest {
  DriveUploadRequest({
    required this.scope,
    required this.path,
    required this.bytes,
    required this.operationId,
    this.baseRevision,
    this.contentType = 'application/octet-stream',
    this.authGeneration = 1,
  }) : sha256 = cryptoSha256(bytes) {
    if (!RegExp(r'^[A-Za-z0-9._:-]{8,128}$').hasMatch(operationId)) {
      throw const FormatException(
        'operationId must be a stable idempotency key',
      );
    }
    if (authGeneration < 1) {
      throw ArgumentError.value(authGeneration, 'authGeneration');
    }
    scope.mountKey;
    scope._validateIds();
  }

  final DriveMountScope scope;
  final DrivePath path;
  final Uint8List bytes;
  final String operationId;
  final String? baseRevision;
  final String contentType;
  final int authGeneration;
  final String sha256;

  Map<String, Object?> safeMetadata() => {
    'providerId': scope.providerId,
    'connectionId': scope.connectionId,
    'path': path.absolute,
    'operationId': operationId,
    'baseRevision': baseRevision,
    'sha256': sha256,
    'size': bytes.length,
    'authGeneration': authGeneration,
  };
}

final class DriveDeleteRequest {
  const DriveDeleteRequest({
    required this.scope,
    required this.path,
    required this.operationId,
    this.baseRevision,
    this.authGeneration = 1,
  });

  final DriveMountScope scope;
  final DrivePath path;
  final String operationId;
  final String? baseRevision;
  final int authGeneration;
}

final class DriveListRequest {
  const DriveListRequest({
    required this.scope,
    required this.path,
    this.cursor,
  });
  final DriveMountScope scope;
  final DrivePath path;
  final String? cursor;
}

final class DriveChangesRequest {
  const DriveChangesRequest({required this.scope, required this.cursor});
  final DriveMountScope scope;
  final String? cursor;
}

final class DriveChangesPage {
  const DriveChangesPage({
    required this.items,
    this.nextCursor,
    this.hasMore = false,
  });
  final List<RemoteDriveItem> items;
  final String? nextCursor;
  final bool hasMore;
}

enum DriveErrorKind {
  inactivePlan,
  featureDenied,
  quotaExceeded,
  providerReauthRequired,
  preconditionFailed,
  operationFingerprintMismatch,
  transient,
  rateLimited,
  invalidResponse,
  notFound,
  permanent,
}

final class DriveProviderException implements Exception {
  const DriveProviderException(
    this.kind,
    this.message, {
    this.retryAfter,
    this.providerOperationId,
    this.statusCode,
  });

  final DriveErrorKind kind;
  final String message;
  final Duration? retryAfter;
  final String? providerOperationId;
  final int? statusCode;

  bool get retryable =>
      kind == DriveErrorKind.transient || kind == DriveErrorKind.rateLimited;
  bool get requiresReauth => kind == DriveErrorKind.providerReauthRequired;

  @override
  String toString() => 'DriveProviderException($kind, $message)';
}

final class DriveResult<T> {
  const DriveResult.ok(this.value) : error = null;
  const DriveResult.failure(this.error) : value = null;

  final T? value;
  final DriveProviderException? error;
  bool get isOk => error == null;
}

/// Transport seam for external products. No stock implementation is selected
/// implicitly; hosts register providers explicitly against their own account.
abstract interface class RemoteDriveProvider {
  String get providerId;
  DriveCapabilities get capabilities;

  Future<DriveResult<List<RemoteDriveItem>>> list(DriveListRequest request);
  Future<DriveResult<RemoteDriveItem>> get(
    DriveMountScope scope,
    DrivePath path,
  );
  Future<DriveResult<RemoteDriveItem>> upload(DriveUploadRequest request);
  Future<DriveResult<void>> delete(DriveDeleteRequest request);
  Future<DriveResult<DriveChangesPage>> changes(DriveChangesRequest request);
}

enum DriveSyncStatus {
  localOnly,
  syncing,
  synced,
  conflict,
  planInactive,
  quotaExceeded,
  providerReauthRequired,
  permanentError,
}

/// Serializable state suitable for the existing Files/Recent Surfaces model.
final class DriveSyncState {
  const DriveSyncState({
    required this.status,
    required this.dirty,
    this.localRevision,
    this.remoteRevision,
    this.baseRevision,
    this.operationId,
    this.providerOperationId,
    this.providerDetails,
    this.retryAt,
    this.lastSyncedAt,
  });

  const DriveSyncState.localOnly([String? reason])
    : status = DriveSyncStatus.localOnly,
      dirty = false,
      localRevision = null,
      remoteRevision = null,
      baseRevision = null,
      operationId = null,
      providerOperationId = null,
      providerDetails = reason,
      retryAt = null,
      lastSyncedAt = null;

  final DriveSyncStatus status;
  final bool dirty;
  final String? localRevision;
  final String? remoteRevision;
  final String? baseRevision;
  final String? operationId;
  final String? providerOperationId;
  final String? providerDetails;
  final DateTime? retryAt;
  final DateTime? lastSyncedAt;

  DriveSyncState fromError(DriveProviderException error, {DateTime? now}) {
    final status = switch (error.kind) {
      DriveErrorKind.inactivePlan ||
      DriveErrorKind.featureDenied => DriveSyncStatus.planInactive,
      DriveErrorKind.quotaExceeded => DriveSyncStatus.quotaExceeded,
      DriveErrorKind.providerReauthRequired =>
        DriveSyncStatus.providerReauthRequired,
      DriveErrorKind.preconditionFailed => DriveSyncStatus.conflict,
      DriveErrorKind.permanent ||
      DriveErrorKind.invalidResponse ||
      DriveErrorKind.operationFingerprintMismatch =>
        DriveSyncStatus.permanentError,
      _ => dirty ? DriveSyncStatus.syncing : DriveSyncStatus.permanentError,
    };
    return DriveSyncState(
      status: status,
      dirty: dirty,
      localRevision: localRevision,
      remoteRevision: remoteRevision,
      baseRevision: baseRevision,
      operationId: operationId,
      providerOperationId: error.providerOperationId,
      providerDetails: error.message,
      retryAt: error.retryAfter == null || now == null
          ? null
          : now.add(error.retryAfter!),
      lastSyncedAt: lastSyncedAt,
    );
  }
}

String cryptoSha256(List<int> bytes) => sha256.convert(bytes).toString();

/// Stable payload fingerprint used for crash/restart idempotency. The auth
/// generation is deliberately excluded so retrying the SAME user operation
/// after reconnect is recognizable; stale writers are fenced separately.
String driveOperationFingerprint(DriveUploadRequest request) => sha256
    .convert(
      utf8.encode(
        '${request.scope.mountKey}\n${request.path.collisionKey}\n${request.sha256}\n${request.baseRevision ?? ''}',
      ),
    )
    .toString();
