// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'dap_service_stub.dart' if (dart.library.io) 'dap_service_io.dart';

/// Everything the DAP hub settings page shows, in one snapshot of the
/// machine-shared `~/.dap` config (docs/dap.md §9): the resolved connection,
/// the agent identity, and the channels this machine holds keys for.
///
/// [connected] is the live-probe outcome: `null` = not probed yet,
/// `true` = the hub welcomed us, `false` = unreachable or rejected.
class DapHubSnapshot {
  const DapHubSnapshot({
    required this.supported,
    required this.url,
    required this.channels,
    this.name,
    this.agentId,
    this.envLocked = false,
    this.connected,
  });

  /// False where the hub client cannot run (web — the `fah_hub_client`
  /// package is IO-bound): the page shows the honest not-supported note.
  final bool supported;

  /// The hub URL in force (env > `~/.dap/config.json` > the zero-config
  /// default).
  final String url;

  /// The agent display name (`~/.dap/config.json` `name`), when set.
  final String? name;

  /// The 16-hex identity derived from this machine's hub key.
  final String? agentId;

  /// Channel names this machine holds a key for (`~/.dap/channels.json`),
  /// sorted.
  final List<String> channels;

  /// True when `DAP_HUB_URL` / `DAP_AGENT_NAME` env vars pin the
  /// connection — env wins over the saved config, so the editor cannot
  /// change what is in force (docs/dap.md §9.1).
  final bool envLocked;

  /// Probe outcome: `null` = not probed, `true` = welcomed by the hub,
  /// `false` = unreachable or rejected.
  final bool? connected;

  /// A copy of this snapshot with the probe outcome set.
  DapHubSnapshot withProbe(bool connected) => DapHubSnapshot(
    supported: supported,
    url: url,
    channels: channels,
    name: name,
    agentId: agentId,
    envLocked: envLocked,
    connected: connected,
  );
}

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
