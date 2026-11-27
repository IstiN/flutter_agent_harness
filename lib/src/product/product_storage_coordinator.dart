import 'dart:async';

import 'fa_product_config.dart';

typedef ProductNamespaceWriter = FutureOr<void> Function(String? namespace);

/// Account-switch boundary for browser storage. The writer closes old DB
/// handles and swaps the namespace synchronously before any new engine work;
/// remote writes are independently fenced by [CloudIdentity.authGeneration].
final class ProductStorageCoordinator {
  ProductStorageCoordinator(this.config, this._writer);

  final FaProductConfig config;
  final ProductNamespaceWriter _writer;
  CloudIdentity? _active;

  CloudIdentity? get active => _active;
  String? get currentNamespace => namespaceFor(_active);

  String? namespaceFor(CloudIdentity? identity) {
    if (config.isStock) return null;
    return identity == null
        ? config.storageNamespace(config.storageSchemaVersion)
        : config.accountNamespace(identity, config.storageSchemaVersion);
  }

  Future<void> activate(CloudIdentity identity) async {
    if (config.isStock) {
      throw StateError('stock Fa has no cloud account storage coordinator');
    }
    identity.validate();
    final previous = _active;
    if (previous != null &&
        previous.tenantId == identity.tenantId &&
        previous.subject == identity.subject &&
        identity.authGeneration < previous.authGeneration) {
      throw StateError('auth generation cannot move backwards');
    }
    // Write first: if closing/swapping fails, the old active fence remains.
    await _writer(namespaceFor(identity));
    _active = identity;
  }

  Future<void> signOut() async {
    if (config.isStock) return;
    await _writer(namespaceFor(null));
    _active = null;
  }

  bool permits(CloudIdentity identity) => _active?.canWriteFor(identity) ?? false;
}
