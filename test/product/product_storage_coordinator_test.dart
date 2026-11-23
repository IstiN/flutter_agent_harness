import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  final config = FaProductConfig.fromJson({
    'productId': 'host-product',
    'displayName': 'Host Workspace',
    'driveEndpoint': 'https://drive.example',
    'featureFlags': ['cloudSync'],
  });
  const a = CloudIdentity(
    tenantId: 'tenant',
    subject: 'subject-a',
    deviceId: 'device-a',
    authGeneration: 1,
  );
  const b = CloudIdentity(
    tenantId: 'tenant',
    subject: 'subject-b',
    deviceId: 'device-b',
    authGeneration: 1,
  );

  test('stock activation is disabled and never rewrites legacy storage', () async {
    var writes = 0;
    final coordinator = ProductStorageCoordinator(
      FaProductConfig.stock,
      (_) => writes++,
    );
    expect(coordinator.currentNamespace, isNull);
    await coordinator.signOut();
    await expectLater(coordinator.activate(a), throwsStateError);
    expect(writes, 0);
  });

  test('account switch partitions data and fences stale writers', () async {
    final namespaces = <String?>[];
    final coordinator = ProductStorageCoordinator(config, namespaces.add);
    await coordinator.activate(a);
    expect(coordinator.permits(a), isTrue);
    expect(coordinator.currentNamespace, contains('account:'));
    final aNamespace = coordinator.currentNamespace;
    await coordinator.activate(b);
    expect(coordinator.currentNamespace, isNot(aNamespace));
    expect(coordinator.permits(a), isFalse);
    expect(coordinator.permits(b), isTrue);
    await coordinator.signOut();
    expect(coordinator.active, isNull);
    expect(coordinator.currentNamespace, 'fa-product:host-product:schema:1');
    expect(namespaces, [aNamespace, isNot(aNamespace), 'fa-product:host-product:schema:1']);
  });

  test('generation rollback and failed namespace swap preserve the old fence', () async {
    var fail = false;
    final coordinator = ProductStorageCoordinator(config, (_) {
      if (fail) throw StateError('IndexedDB close failed');
    });
    await coordinator.activate(a.nextGeneration());
    await expectLater(coordinator.activate(a), throwsStateError);
    expect(coordinator.active!.authGeneration, 2);
    fail = true;
    await expectLater(coordinator.activate(b), throwsStateError);
    expect(coordinator.active!.subject, 'subject-a');
  });
}
