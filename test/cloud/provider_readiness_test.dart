import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('readiness levels and usage', () {
    test('stub, MVP/full-scan and complete are explicit', () {
      const stub = CloudProviderReadiness(
        capabilities: DriveCapabilities.none(),
        planEnabled: true,
        featureAllowed: true,
        usedBytes: 0,
        quotaBytes: 100,
      );
      expect(stub.level, CloudProviderReadinessLevel.stub);
      expect(stub.onlineWritesAllowed, isFalse);
      final mvp = CloudProviderReadiness(
        capabilities: _capabilities(delta: false, hashes: true),
        planEnabled: true,
        featureAllowed: true,
        usedBytes: 20,
        quotaBytes: 100,
      );
      expect(mvp.level, CloudProviderReadinessLevel.mvp);
      expect(mvp.requiresFullScan, isTrue);
      expect(mvp.onlineWritesAllowed, isTrue);
      expect(mvp.remainingBytes, 80);
      final complete = CloudProviderReadiness(
        capabilities: _capabilities(delta: true, hashes: true),
        planEnabled: true,
        featureAllowed: true,
        usedBytes: 0,
        quotaBytes: -1,
      );
      expect(complete.level, CloudProviderReadinessLevel.complete);
      expect(complete.remainingBytes, isNull);
    });

    test(
      'inactive plan, feature denial, per-account quota and size are distinct',
      () {
        CloudProviderReadiness readiness({
          bool plan = true,
          bool feature = true,
          int used = 0,
          int quota = 10,
          int max = 8,
        }) => CloudProviderReadiness(
          capabilities: _capabilities(delta: true, hashes: true, max: max),
          planEnabled: plan,
          featureAllowed: feature,
          usedBytes: used,
          quotaBytes: quota,
        );
        expect(
          () => readiness(plan: false).validateUpload(1),
          throwsA(_error(DriveErrorKind.inactivePlan)),
        );
        expect(
          () => readiness(feature: false).validateUpload(1),
          throwsA(_error(DriveErrorKind.featureDenied)),
        );
        expect(
          () => readiness(used: 9).validateUpload(2),
          throwsA(_error(DriveErrorKind.quotaExceeded)),
        );
        expect(
          () => readiness(quota: -1, max: 4).validateUpload(5),
          throwsA(_error(DriveErrorKind.quotaExceeded)),
        );
        expect(() => readiness(used: 8).validateUpload(2), returnsNormally);
      },
    );
  });

  group('provider error mapping', () {
    for (final (status, code, kind) in [
      (401, null, DriveErrorKind.providerReauthRequired),
      (402, null, DriveErrorKind.inactivePlan),
      (403, 'inactive_plan', DriveErrorKind.inactivePlan),
      (403, null, DriveErrorKind.featureDenied),
      (409, null, DriveErrorKind.preconditionFailed),
      (412, null, DriveErrorKind.preconditionFailed),
      (413, null, DriveErrorKind.quotaExceeded),
      (429, null, DriveErrorKind.rateLimited),
      (503, null, DriveErrorKind.transient),
    ]) {
      test('$status/$code maps to $kind', () {
        final error = CloudProviderErrorMapper.fromResponse(
          statusCode: status,
          providerCode: code,
          retryAfter: '30',
          providerOperationId: 'provider-op',
        );
        expect(error.kind, kind);
        expect(error.statusCode, status);
        expect(error.retryAfter, const Duration(seconds: 30));
        expect(error.providerOperationId, 'provider-op');
      });
    }

    test('malformed item and missing delta cursor fail closed', () {
      expect(
        () => CloudProviderErrorMapper.itemFromJson({
          'path': '/drive/a.txt',
          'revision': '',
          'sha256': 'bad',
          'size': -1,
          'modifiedAt': 'not-a-date',
        }),
        throwsA(_error(DriveErrorKind.invalidResponse)),
      );
      expect(
        () => CloudProviderErrorMapper.changesFromJson({
          'items': <Object?>[],
          'hasMore': true,
        }),
        throwsA(_error(DriveErrorKind.invalidResponse)),
      );
    });

    test('valid item preserves revision/hash and normalized path', () {
      final item = CloudProviderErrorMapper.itemFromJson({
        'path': '/drive/Cafe\u0301.md',
        'revision': 'r2',
        'sha256': 'a' * 64,
        'size': 4,
        'modifiedAt': '2026-01-01T00:00:00Z',
      });
      expect(item.path.absolute, '/drive/Café.md');
      expect(item.revision, 'r2');
      expect(item.sha256, 'a' * 64);
    });
  });

  test(
    'stub provider performs no live work and returns featureDenied',
    () async {
      const provider = StubRemoteDriveProvider('stub');
      final identity = const CloudIdentity(
        tenantId: 'tenant',
        subject: 'subject',
        deviceId: 'device',
        authGeneration: 1,
      );
      final scope = DriveMountScope.forIdentity(
        providerId: 'stub',
        connectionId: 'connection',
        identity: identity,
      );
      final result = await provider.list(
        DriveListRequest(scope: scope, path: DrivePath.parse('/drive')),
      );
      expect(result.error!.kind, DriveErrorKind.featureDenied);
      expect(provider.capabilities.maxFileBytes, 0);
    },
  );
}

DriveCapabilities _capabilities({
  required bool delta,
  required bool hashes,
  int max = 1024,
}) => DriveCapabilities(
  deltaCursors: delta,
  conditionalWrites: true,
  revisions: true,
  hashes: hashes,
  move: false,
  trash: true,
  maxFileBytes: max,
);

Matcher _error(DriveErrorKind kind) =>
    isA<DriveProviderException>().having((error) => error.kind, 'kind', kind);
