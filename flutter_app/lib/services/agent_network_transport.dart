// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Platform seam for the agent network (issue #402): native uses `dart:io`;
/// browser builds use a real WebSocket plus the IndexedDB-backed app sandbox.
/// Targets with neither implementation keep the honest not-supported UI.
library;

export 'agent_network_transport_stub.dart'
    if (dart.library.io) 'agent_network_transport_io.dart'
    if (dart.library.html) 'agent_network_transport_web.dart';
