import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('DrivePath', () {
    test('normalizes a rooted relative POSIX path with Unicode NFC', () {
      final path = DrivePath.parse('/drive/notes/Cafe\u0301.md');
      expect(path.absolute, '/drive/notes/Café.md');
      expect(path.relativePath, 'notes/Café.md');
      expect(path.parent.absolute, '/drive/notes');
      expect(path.child('next.md').absolute, '/drive/notes/Café.md/next.md');
      expect(DrivePath.parse('/drive').parent.absolute, '/drive');
    });

    test('allows only explicit host aliases', () {
      expect(
        DrivePath.parse(
          '/health/records/a.json',
          aliases: {'/health'},
        ).absolute,
        '/health/records/a.json',
      );
      expect(
        () => DrivePath.parse('/health/records/a.json'),
        throwsFormatException,
      );
      expect(
        () => DrivePath.parse('/etc/passwd', aliases: {'/health'}),
        throwsFormatException,
      );
    });

    for (final path in [
      'drive/notes/a.md',
      '/drive/../a.md',
      '/drive//a.md',
      '/drive/./a.md',
      r'/drive/a\b.md',
      '/drive/con.txt',
      '/drive/trailing.',
      '/drive/.env',
      '/drive/.env.production',
      '/drive/.dap/state.json',
      '/drive/logs/today.txt',
      '/drive/saved_keys/value.json',
      '/drive/oauth/state.json',
      '/drive/client-secret.json',
      '/drive/private.pem',
    ]) {
      test('rejects $path', () {
        expect(() => DrivePath.parse(path), throwsFormatException);
      });
    }

    test(
      'Unicode and case collisions have one deterministic collision key',
      () {
        final decomposed = DrivePath.parse('/drive/Cafe\u0301.md');
        final composed = DrivePath.parse('/drive/CAFÉ.md');
        expect(decomposed.collisionKey, composed.collisionKey);
      },
    );
  });

  group('scope and upload identity', () {
    const identity = CloudIdentity(
      tenantId: 'tenant-a',
      subject: 'subject-a',
      deviceId: 'device-a',
      authGeneration: 2,
    );

    test('mount keys isolate provider, connection, account and alias', () {
      final a = DriveMountScope.forIdentity(
        providerId: 'drive-a',
        connectionId: 'connection-a',
        identity: identity,
      );
      final b = DriveMountScope.forIdentity(
        providerId: 'drive-b',
        connectionId: 'connection-a',
        identity: identity,
      );
      final health = DriveMountScope.forIdentity(
        providerId: 'drive-a',
        connectionId: 'connection-a',
        identity: identity,
        mount: '/health',
      );
      expect(a.mountKey, isNot(b.mountKey));
      expect(a.mountKey, isNot(health.mountKey));
      expect(a.mountKey, isNot(contains('tenant-a')));
      expect(a.mountKey, isNot(contains('subject-a')));
    });

    test(
      'upload carries conditional base revision, hash and idempotency key',
      () {
        final request = _upload(identity: identity);
        expect(request.sha256, cryptoSha256(utf8.encode('hello')));
        expect(request.baseRevision, 'r1');
        expect(request.operationId, 'op-000001');
        expect(request.safeMetadata(), isNot(contains('bytes')));
        expect(jsonEncode(request.safeMetadata()), isNot(contains('tenant-a')));
        expect(
          driveOperationFingerprint(request),
          driveOperationFingerprint(_upload(identity: identity)),
        );
      },
    );

    test('different bytes or base revisions never share a fingerprint', () {
      final original = _upload(identity: identity);
      final changed = _upload(identity: identity, body: 'changed');
      final rebased = _upload(identity: identity, baseRevision: 'r2');
      expect(
        driveOperationFingerprint(original),
        isNot(driveOperationFingerprint(changed)),
      );
      expect(
        driveOperationFingerprint(original),
        isNot(driveOperationFingerprint(rebased)),
      );
    });

    test('invalid idempotency keys and oversized uploads are rejected', () {
      expect(
        () => DriveUploadRequest(
          scope: _scope(identity),
          path: DrivePath.parse('/drive/a.txt'),
          bytes: Uint8List(0),
          operationId: 'bad key',
        ),
        throwsFormatException,
      );
      const capabilities = DriveCapabilities(
        deltaCursors: true,
        conditionalWrites: true,
        revisions: true,
        hashes: true,
        move: false,
        trash: true,
        maxFileBytes: 4,
      );
      expect(
        () => capabilities.requireUpload(5),
        throwsA(isA<DriveProviderException>()),
      );
    });
  });

  group('structured provider results and sync state', () {
    test('capabilities are declared rather than assumed', () {
      const capabilities = DriveCapabilities.none();
      expect(capabilities.deltaCursors, isFalse);
      expect(capabilities.conditionalWrites, isFalse);
      expect(capabilities.maxFileBytes, 0);
    });

    test('inactive plan and quota retain actionable provider details', () {
      const plan = DriveProviderException(
        DriveErrorKind.inactivePlan,
        'drive sync is not enabled for this plan',
        providerOperationId: 'provider-op-1',
      );
      const quota = DriveProviderException(
        DriveErrorKind.quotaExceeded,
        'free quota',
      );
      const syncing = DriveSyncState(
        status: DriveSyncStatus.syncing,
        dirty: true,
        localRevision: 'local-2',
        baseRevision: 'r1',
        operationId: 'op-000001',
      );
      final inactive = syncing.fromError(plan);
      expect(inactive.status, DriveSyncStatus.planInactive);
      expect(inactive.providerOperationId, 'provider-op-1');
      expect(inactive.providerDetails, contains('not enabled'));
      expect(syncing.fromError(quota).status, DriveSyncStatus.quotaExceeded);
      expect(inactive.dirty, isTrue);
    });

    test('rate limits remain retryable with an observable retryAt', () {
      const error = DriveProviderException(
        DriveErrorKind.rateLimited,
        'slow down',
        retryAfter: Duration(seconds: 30),
      );
      final now = DateTime.utc(2026, 1, 1);
      final state = const DriveSyncState(
        status: DriveSyncStatus.syncing,
        dirty: true,
      ).fromError(error, now: now);
      expect(error.retryable, isTrue);
      expect(state.retryAt, now.add(const Duration(seconds: 30)));
    });

    test('precondition and reauth never masquerade as success', () {
      const state = DriveSyncState(
        status: DriveSyncStatus.syncing,
        dirty: true,
      );
      expect(
        state
            .fromError(
              const DriveProviderException(
                DriveErrorKind.preconditionFailed,
                'r2 exists',
              ),
            )
            .status,
        DriveSyncStatus.conflict,
      );
      expect(
        state
            .fromError(
              const DriveProviderException(
                DriveErrorKind.providerReauthRequired,
                'expired',
              ),
            )
            .status,
        DriveSyncStatus.providerReauthRequired,
      );
    });

    test('local-only is explicit when no provider is enabled', () {
      const state = DriveSyncState.localOnly('stock Fa has no cloud provider');
      expect(state.status, DriveSyncStatus.localOnly);
      expect(state.providerDetails, contains('no cloud provider'));
      expect(state.dirty, isFalse);
    });
  });
}

DriveMountScope _scope(CloudIdentity identity) => DriveMountScope.forIdentity(
  providerId: 'drive-a',
  connectionId: 'connection-a',
  identity: identity,
);

DriveUploadRequest _upload({
  required CloudIdentity identity,
  String body = 'hello',
  String baseRevision = 'r1',
}) => DriveUploadRequest(
  scope: _scope(identity),
  path: DrivePath.parse('/drive/notes/a.txt'),
  bytes: Uint8List.fromList(utf8.encode(body)),
  operationId: 'op-000001',
  baseRevision: baseRevision,
  authGeneration: identity.authGeneration,
);
