// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The same-origin storage the host page publishes the scoped session key
/// to (issue #2391). Web reads browser `localStorage`; every other host has
/// no bridge (the product shell is a web surface) and resolves to no
/// session. Tests inject a fake through [HostConnectionResolver].
///
/// The conditional export below provides `platformHostSessionBridge`.
library;

export 'host_session_bridge_stub.dart'
    if (dart.library.html) 'host_session_bridge_web.dart';

/// One same-origin storage read: the raw value stored under [key], or null
/// when the storage is unavailable, the key is absent, or the value is
/// empty (E7/E12 — a missing bridge is "no session", never an error).
abstract interface class HostSessionBridge {
  /// Reads [key]; never throws, never logs the value.
  String? read(String key);
}
