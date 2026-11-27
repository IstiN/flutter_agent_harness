// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-web platform bridge: the product shell's host-session bridge is a
/// same-origin browser surface, so native hosts simply have no session
/// (issue #2391) — reads resolve to null and the stock flow applies.
library;

import 'host_session_bridge.dart';

/// The platform [HostSessionBridge]: no storage on native hosts.
HostSessionBridge platformHostSessionBridge = const _NoBridge();

final class _NoBridge implements HostSessionBridge {
  const _NoBridge();

  @override
  String? read(String key) => null;
}
