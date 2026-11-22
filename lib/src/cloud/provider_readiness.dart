import 'drive_contract.dart';

enum CloudProviderReadinessLevel { stub, mvp, complete }

/// Host-facing readiness assessment. Missing delta support is an MVP full-scan
/// fallback, never a reason to claim complete synchronization.
final class CloudProviderReadiness {
  const CloudProviderReadiness({
    required this.capabilities,
    required this.planEnabled,
    required this.featureAllowed,
    required this.usedBytes,
    required this.quotaBytes,
  });

  final DriveCapabilities capabilities;
  final bool planEnabled;
  final bool featureAllowed;
  final int usedBytes;
  final int quotaBytes;

  CloudProviderReadinessLevel get level {
    if (capabilities.maxFileBytes <= 0 ||
        !capabilities.conditionalWrites ||
        !capabilities.revisions) {
      return CloudProviderReadinessLevel.stub;
    }
    if (!capabilities.deltaCursors || !capabilities.hashes) {
      return CloudProviderReadinessLevel.mvp;
    }
    return CloudProviderReadinessLevel.complete;
  }

  bool get requiresFullScan => !capabilities.deltaCursors;
  bool get onlineWritesAllowed =>
      planEnabled &&
      featureAllowed &&
      level != CloudProviderReadinessLevel.stub;
  int? get remainingBytes => quotaBytes < 0 ? null : quotaBytes - usedBytes;

  void validateUpload(int size) {
    if (!planEnabled) {
      throw const DriveProviderException(
        DriveErrorKind.inactivePlan,
        'cloud sync is not enabled for this account plan',
      );
    }
    if (!featureAllowed) {
      throw const DriveProviderException(
        DriveErrorKind.featureDenied,
        'cloud sync is denied for this account',
      );
    }
    if (size < 0 || size > capabilities.maxFileBytes) {
      throw DriveProviderException(
        DriveErrorKind.quotaExceeded,
        'file exceeds the provider size limit',
      );
    }
    final remaining = remainingBytes;
    if (remaining != null && size > remaining) {
      throw const DriveProviderException(
        DriveErrorKind.quotaExceeded,
        'account cloud quota exhausted',
      );
    }
  }
}

/// Deterministic HTTP/provider payload mapping shared by host adapters.
final class CloudProviderErrorMapper {
  const CloudProviderErrorMapper._();

  static DriveProviderException fromResponse({
    required int statusCode,
    String? providerCode,
    String? message,
    String? retryAfter,
    String? providerOperationId,
  }) {
    final code = providerCode?.toLowerCase();
    final inactivePlan =
        statusCode == 403 &&
        const {'inactive_plan', 'plan_required'}.contains(code);
    final kind = inactivePlan
        ? DriveErrorKind.inactivePlan
        : _httpErrorKinds[statusCode] ??
              (statusCode >= 500 && statusCode <= 599
                  ? DriveErrorKind.transient
                  : DriveErrorKind.permanent);
    return DriveProviderException(
      kind,
      message ?? 'provider HTTP $statusCode',
      retryAfter: _retryAfter(retryAfter),
      providerOperationId: providerOperationId,
      statusCode: statusCode,
    );
  }

  static RemoteDriveItem itemFromJson(
    Map<String, Object?> json, {
    Set<String> aliases = const {},
  }) {
    try {
      final path = DrivePath.parse(json['path']! as String, aliases: aliases);
      final revision = json['revision']! as String;
      final hash = json['sha256'] as String?;
      final size = json['size']! as int;
      final modified = DateTime.parse(json['modifiedAt']! as String).toUtc();
      if (revision.isEmpty ||
          size < 0 ||
          (hash != null && !_sha.hasMatch(hash))) {
        throw const FormatException('invalid revision/hash/size');
      }
      return RemoteDriveItem(
        path: path,
        revision: revision,
        sha256: hash,
        size: size,
        modifiedAt: modified,
        isDirectory: json['isDirectory'] == true,
        deleted: json['deleted'] == true,
        etag: json['etag'] as String?,
      );
    } catch (error) {
      throw DriveProviderException(
        DriveErrorKind.invalidResponse,
        'invalid drive item payload',
        cause: error,
      );
    }
  }

  static DriveChangesPage changesFromJson(
    Map<String, Object?> json, {
    Set<String> aliases = const {},
  }) {
    try {
      final hasMore = json['hasMore'] == true;
      final cursor = json['nextCursor'] as String?;
      if (hasMore && (cursor == null || cursor.isEmpty)) {
        throw const FormatException('missing delta cursor');
      }
      return DriveChangesPage(
        items: (json['items']! as List)
            .map(
              (raw) => itemFromJson(
                (raw as Map).cast<String, Object?>(),
                aliases: aliases,
              ),
            )
            .toList(),
        nextCursor: cursor,
        hasMore: hasMore,
      );
    } on DriveProviderException {
      rethrow;
    } catch (error) {
      throw DriveProviderException(
        DriveErrorKind.invalidResponse,
        'invalid drive changes payload',
        cause: error,
      );
    }
  }

  static const _httpErrorKinds = <int, DriveErrorKind>{
    401: DriveErrorKind.providerReauthRequired,
    402: DriveErrorKind.inactivePlan,
    403: DriveErrorKind.featureDenied,
    404: DriveErrorKind.notFound,
    409: DriveErrorKind.preconditionFailed,
    412: DriveErrorKind.preconditionFailed,
    413: DriveErrorKind.quotaExceeded,
    429: DriveErrorKind.rateLimited,
    507: DriveErrorKind.quotaExceeded,
  };

  static Duration? _retryAfter(String? value) {
    final seconds = value == null ? null : int.tryParse(value);
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  static final RegExp _sha = RegExp(r'^[a-fA-F0-9]{64}$');
}

/// Explicit no-backend provider for host wiring/tests. It performs no network
/// and always reports featureDenied instead of pretending to synchronize.
final class StubRemoteDriveProvider implements RemoteDriveProvider {
  const StubRemoteDriveProvider(this.providerId);

  @override
  final String providerId;
  @override
  DriveCapabilities get capabilities => const DriveCapabilities.none();

  DriveResult<T> _denied<T>() => const DriveResult.failure(
    DriveProviderException(
      DriveErrorKind.featureDenied,
      'stub provider has no live backend',
    ),
  );

  @override
  Future<DriveResult<DriveChangesPage>> changes(
    DriveChangesRequest request,
  ) async => _denied();
  @override
  Future<DriveResult<RemoteDriveItem>> delete(
    DriveDeleteRequest request,
  ) async => _denied();
  @override
  Future<DriveResult<RemoteDriveDownload>> download(
    DriveMountScope scope,
    DrivePath path,
  ) async => _denied();
  @override
  Future<DriveResult<RemoteDriveItem>> get(
    DriveMountScope scope,
    DrivePath path,
  ) async => _denied();
  @override
  Future<DriveResult<List<RemoteDriveItem>>> list(
    DriveListRequest request,
  ) async => _denied();
  @override
  Future<DriveResult<RemoteDriveItem>> upload(
    DriveUploadRequest request,
  ) async => _denied();
}
