// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Platform seam for the agent network (issue #402): the hub transport and
/// identity path exist only where `dart:io` does. Web (and tests without a
/// transport) get [agentNetworkSupported] = false and the honest
/// not-supported UI.
library;

export 'agent_network_transport_stub.dart'
    if (dart.library.io) 'agent_network_transport_io.dart';
