import 'dart:typed_data';

import 'package:fa/services/cloud/drive_sync_controller.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

const testDriveIdentity = CloudIdentity(
  tenantId: 'tenant-test',
  subject: 'subject-test',
  deviceId: 'device-test',
  authGeneration: 1,
);

DriveMountScope get testDriveScope => DriveMountScope.forIdentity(
  providerId: 'test-drive',
  connectionId: 'connection-test',
  identity: testDriveIdentity,
);

DrivePath get testDrivePath => DrivePath.parse('/drive/notes.md');

Future<DriveSyncController> makeDriveStatusController({
  required ExecutionEnv env,
  required DriveSyncStatus status,
  String details = 'provider detail',
}) async {
  final store = MemoryDriveSyncStore();
  final scope = testDriveScope;
  final pending =
      status != DriveSyncStatus.synced && status != DriveSyncStatus.localOnly
      ? [
          DriveOperationRecord(
            operationId: 'op-golden-1',
            path: testDrivePath,
            bytes: Uint8List.fromList('local'.codeUnits),
            sha256: cryptoSha256('local'.codeUnits),
            fingerprint: 'fingerprint',
            baseRevision: 'r1',
            localRevision: 2,
            authGeneration: 1,
            createdAt: DateTime.utc(2026),
          ),
        ]
      : const <DriveOperationRecord>[];
  final snapshot = DriveWorkspaceSnapshot.empty(scope.mountKey).copyWith(
    files: {
      testDrivePath.absolute: DriveFileState(
        collisionKey: testDrivePath.collisionKey,
        localRevision: 2,
        localSha256: cryptoSha256('local'.codeUnits),
        remoteRevision: 'r1',
        remoteSha256: cryptoSha256('base'.codeUnits),
        status: status,
        dirty: status != DriveSyncStatus.synced,
        providerDetails: details,
        lastSyncedAt: status == DriveSyncStatus.synced
            ? DateTime.utc(2026)
            : null,
      ),
    },
    pending: pending,
  );
  await store.save(snapshot, expectedStorageRevision: 0);
  final controller = DriveSyncController(
    engine: DriveSyncEngine(
      provider: NoopDriveProvider(),
      store: store,
      env: env,
      now: () => DateTime.utc(2026),
    ),
    scope: scope,
    identity: testDriveIdentity,
    autoLoad: false,
  );
  await controller.refresh();
  return controller;
}

final class NoopDriveProvider implements RemoteDriveProvider {
  @override
  String get providerId => 'test-drive';
  @override
  DriveCapabilities get capabilities => const DriveCapabilities.none();

  Never _unused() => throw UnimplementedError('status-only test provider');

  @override
  Future<DriveResult<DriveChangesPage>> changes(DriveChangesRequest request) =>
      Future.value(DriveResult.failure(_unused()));
  @override
  Future<DriveResult<RemoteDriveItem>> delete(DriveDeleteRequest request) =>
      Future.value(DriveResult.failure(_unused()));
  @override
  Future<DriveResult<RemoteDriveDownload>> download(
    DriveMountScope scope,
    DrivePath path,
  ) => Future.value(DriveResult.failure(_unused()));
  @override
  Future<DriveResult<RemoteDriveItem>> get(
    DriveMountScope scope,
    DrivePath path,
  ) => Future.value(DriveResult.failure(_unused()));
  @override
  Future<DriveResult<List<RemoteDriveItem>>> list(DriveListRequest request) =>
      Future.value(DriveResult.failure(_unused()));
  @override
  Future<DriveResult<RemoteDriveItem>> upload(DriveUploadRequest request) =>
      Future.value(DriveResult.failure(_unused()));
}
