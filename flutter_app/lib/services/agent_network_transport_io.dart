// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The IO transport: a real WebSocket hub transport plus the sandbox
/// identity file, so the app agent keeps one stable hub address across
/// restarts (issue #402 AC3).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show HubIdentity;
import 'package:flutter_agent_harness/io.dart';

/// Whether this platform can host the agent's hub membership.
const bool agentNetworkSupported = true;

/// The platform transport.
HubTransport? get platformHubTransport => const IoHubTransport();

/// The agent identity lives in the app sandbox root.
String? identityPathFor(String sandboxRoot) => '$sandboxRoot/hub_identity';

/// Loads (or first-boot creates) the agent identity at [path].
Future<HubIdentity?> loadOrCreateIdentity(String? path) async =>
    path == null ? null : loadHubIdentity(path);
