import 'dart:convert';
import 'dart:typed_data';

import 'drive_contract.dart';

final class DriveProviderContractCheck {
  const DriveProviderContractCheck(this.name, this.passed, this.details);
  final String name;
  final bool passed;
  final String details;
}

/// Reusable mutation contract for external provider authors. Run ONLY against
/// a dedicated test account/root: it intentionally creates and deletes files.
/// Every check is returned so package:test or another runner can assert them.
Future<List<DriveProviderContractCheck>> runRemoteDriveProviderContract({
  required RemoteDriveProvider provider,
  required DriveMountScope scope,
  required bool allowMutations,
  DrivePath? root,
}) async {
  if (!allowMutations) {
    throw StateError('provider contract requires an isolated test account');
  }
  final checks = <DriveProviderContractCheck>[];
  Future<void> check(String name, Future<String> Function() body) async {
    try {
      checks.add(DriveProviderContractCheck(name, true, await body()));
    } catch (error) {
      checks.add(DriveProviderContractCheck(name, false, '$error'));
    }
  }

  final base = root ?? DrivePath.parse('/drive/provider-contract');
  final path = base.child('item.txt');
  final bytes = Uint8List.fromList(utf8.encode('contract-one'));
  final first = DriveUploadRequest(
    scope: scope,
    path: path,
    bytes: bytes,
    operationId: 'contract-upload-1',
  );
  RemoteDriveItem? uploaded;
  await check('declared conditional/revision/hash capabilities', () async {
    final capabilities = provider.capabilities;
    if (!capabilities.conditionalWrites ||
        !capabilities.revisions ||
        !capabilities.hashes) {
      throw StateError('MVP/stub provider: complete contract not declared');
    }
    return 'complete write capabilities declared';
  });
  if (checks.single.passed) {
    await check('conditional create upload', () async {
      final result = await provider.upload(first);
      if (!result.isOk) throw result.error!;
      uploaded = result.value;
      if (uploaded?.revision == null) throw StateError('missing revision');
      return 'revision ${uploaded!.revision}';
    });
    await check('same operation replay returns the original result', () async {
      final result = await provider.upload(first);
      if (!result.isOk || result.value!.revision != uploaded?.revision) {
        throw StateError('idempotent replay changed the result');
      }
      return 'same revision and no duplicate mutation';
    });
    await check('same key with different payload is rejected', () async {
      final result = await provider.upload(
        DriveUploadRequest(
          scope: scope,
          path: path,
          bytes: Uint8List.fromList(utf8.encode('contract-two')),
          operationId: first.operationId,
        ),
      );
      if (result.error?.kind != DriveErrorKind.operationFingerprintMismatch) {
        throw StateError('provider accepted key/payload substitution');
      }
      return 'operationFingerprintMismatch';
    });
    await check('stale base revision is a precondition conflict', () async {
      final result = await provider.upload(
        DriveUploadRequest(
          scope: scope,
          path: path,
          bytes: bytes,
          operationId: 'contract-stale-1',
          baseRevision: null,
        ),
      );
      if (result.error?.kind != DriveErrorKind.preconditionFailed) {
        throw StateError('stale write did not return preconditionFailed');
      }
      return 'no silent overwrite';
    });
    await check('download bytes match revision hash', () async {
      final result = await provider.download(scope, path);
      if (!result.isOk) throw result.error!;
      if (cryptoSha256(result.value!.bytes) != uploaded?.sha256) {
        throw StateError('downloaded hash mismatch');
      }
      return 'sha256 verified';
    });
    await check('conditional delete honors the current revision', () async {
      final result = await provider.delete(
        DriveDeleteRequest(
          scope: scope,
          path: path,
          operationId: 'contract-delete-1',
          baseRevision: uploaded?.revision,
        ),
      );
      if (!result.isOk) throw result.error!;
      return 'tombstone ${result.value!.revision}';
    });
  }
  return checks;
}
