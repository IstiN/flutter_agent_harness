// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'dap_service_stub.dart' if (dart.library.io) 'dap_service_io.dart';

// One snapshot type shared with the CLI (package `DapHubSnapshot`); the
// app-side service interface below stays here.
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show DapHubSnapshot;
export 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show DapHubSnapshot;

/// Read/write access to the DAP hub connection the app shares with the CLI
/// agents (`~/.dap/config.json`, identity under `~/.dap/keys/fah/`).
///
/// The platform implementation is picked by the conditional export above:
/// the real service on IO platforms, a never-supported stub on web.
abstract interface class DapHubService {
  /// Loads the resolved settings: URL, name, identity (created on first
  /// use, like the CLI), and channels. No network.
  Future<DapHubSnapshot> load();

  /// Persists the connection to `~/.dap/config.json`. [url] is normalized
  /// (`hub:8787` → `ws://hub:8787/ws`); an empty [name] leaves the saved
  /// name untouched (the persisted format has no clear-name operation).
  Future<void> saveConnection({required String url, required String name});

  /// Dials the hub once ([HubPlugin] start → status → dispose) and returns
  /// the snapshot with [DapHubSnapshot.connected] set. Bounded: an
  /// unreachable hub resolves to `false` after the probe timeout instead
  /// of hanging on the client's reconnect loop.
  Future<DapHubSnapshot> probe();
}
