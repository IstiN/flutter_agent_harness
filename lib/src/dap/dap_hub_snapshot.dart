// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// One DAP/1 hub snapshot — everything a host shows about the hub
/// connection in one immutable value (docs/dap.md §9): the resolved
/// connection, the agent identity, and the channels this machine holds
/// keys for.
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
  /// package is IO-bound): the host shows the honest not-supported note.
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
  /// connection — env wins over the saved config, so an editor cannot
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
