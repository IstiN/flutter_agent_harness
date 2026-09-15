// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The web stub: no `dart:io`, no hub transport — the agent network is
/// honestly unsupported (the UI says so instead of pretending).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show HubIdentity;
import 'package:flutter_agent_harness/io.dart' show HubTransport;

/// Whether this platform can host the agent's hub membership.
const bool agentNetworkSupported = false;

/// The platform transport (never called — [agentNetworkSupported] is
/// false).
HubTransport? get platformHubTransport => null;

/// Where the agent identity persists on this platform (null = nowhere).
String? identityPathFor(String sandboxRoot) => null;

/// Never called on this platform (the network is unsupported).
Future<HubIdentity?> loadOrCreateIdentity(String? path) async => null;
