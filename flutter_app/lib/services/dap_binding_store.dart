// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dap_service.dart';

/// App-wide view of the DAP inbound binding (which session receives
/// messages from other agents): the settings page writes through it, the
/// sidebar listens to mark the bound session. Lazy singleton — the first
/// listener triggers the load; every saveBinding refreshes.
class DapBindingStore extends ChangeNotifier {
  DapBindingStore._({DapHubService? service})
    : _service = service ?? createDapHubService() {
    unawaited(refresh());
  }

  /// The shared instance (platform service under the hood).
  static final DapBindingStore instance = DapBindingStore._();

  /// Test seam.
  factory DapBindingStore.forTest(DapHubService service) =>
      DapBindingStore._(service: service);

  final DapHubService _service;

  DapHubSnapshot? _snapshot;

  /// The last loaded snapshot (null until the first load lands).
  DapHubSnapshot? get snapshot => _snapshot;

  /// The session id marked in the sidebar (null = no binding / unknown).
  String? get boundSessionId => _snapshot?.boundSessionId;

  /// Reloads the snapshot from the platform service. Never throws — a
  /// failed load keeps the last good snapshot.
  Future<void> refresh() async {
    try {
      _snapshot = await _service.load();
      notifyListeners();
    } on Object {
      // Unsupported platform / unreadable config — stay with the last
      // snapshot (or none).
    }
  }
}
