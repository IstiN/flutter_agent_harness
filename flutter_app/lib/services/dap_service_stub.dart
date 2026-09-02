// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dap_service.dart';

/// Web (no `dart:io`): the `fah_hub_client` package is IO-bound — plain
/// `dart:io` WebSocket transport plus the `~/.dap` files — so DAP settings
/// are honestly unsupported here; callers degrade to the not-supported note.
DapHubService createDapHubService() => const UnsupportedDapHubService();

final class UnsupportedDapHubService implements DapHubService {
  const UnsupportedDapHubService();

  /// The zero-config default URL (mirrors the package's `defaultDapUrl`,
  /// which cannot be imported here without dragging in `dart:io`).
  static const _snapshot = DapHubSnapshot(
    supported: false,
    url: 'ws://127.0.0.1:8787/ws',
    channels: [],
  );

  @override
  Future<DapHubSnapshot> load() async => _snapshot;

  @override
  Future<DapHubSnapshot> probe() async => _snapshot;

  @override
  Future<void> saveConnection({required String url, required String name}) =>
      throw StateError('DAP hub is not supported on this platform.');
}
