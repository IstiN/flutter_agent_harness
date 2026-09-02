// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';

import 'dap_service.dart';

/// The real [DapHubService] (IO platforms): reads/writes the same
/// machine-shared `~/.dap` config the CLI agents use, via the
/// `fah_hub_client` package's own loader/persister — no second config
/// format.
final class IoDapHubService implements DapHubService {
  IoDapHubService({
    Map<String, String>? environment,
    this.home,
    this.probeTimeout = const Duration(seconds: 5),
  }) : environment = environment ?? Platform.environment;

  /// Injected environment (defaults to `Platform.environment`; test seam —
  /// pointing `HOME` at a temp dir keeps tests off the real `~/.dap`).
  final Map<String, String> environment;

  /// Home directory for the `~/.dap` layout (test seam).
  final String? home;

  /// How long the live probe waits for the hub's welcome before reporting
  /// unreachable — the client keeps reconnecting forever otherwise.
  final Duration probeTimeout;

  /// The effective settings with the documented precedence (docs/dap.md
  /// §9.1): env (`DAP_HUB_URL`/`DAP_AGENT_NAME`) > `~/.dap/config.json` >
  /// zero-config defaults — env merged exactly like `HubPlugin.register`.
  DapSettings get _settings {
    final config = HubConfig.fromMap(
      readDapConfig(defaultDapConfigFile(home, environment)),
      environment,
    );
    return resolveDapSettings(
      config: config,
      environment: environment,
      home: home,
    );
  }

  @override
  Future<DapHubSnapshot> load() async {
    final settings = _settings;
    // Created 0600 on first use — the same first-use semantics as the CLI.
    final identity = await HubIdentity.load(settings.keyPath);
    final channels = (await loadChannelKeys(
      settings.channelsFile,
    )).keys.toList()..sort();
    return DapHubSnapshot(
      supported: true,
      url: settings.url,
      name: settings.name,
      agentId: identity.agentId,
      channels: channels,
      envLocked:
          environment.containsKey(HubConfig.envUrl) ||
          environment.containsKey(HubConfig.envName),
      connected: null,
    );
  }

  @override
  Future<void> saveConnection({required String url, required String name}) {
    final trimmed = name.trim();
    return persistDapConfig(
      url: normalizeDapHost(url.trim()),
      name: trimmed.isEmpty ? null : trimmed,
      file: defaultDapConfigFile(home, environment),
    );
  }

  @override
  Future<DapHubSnapshot> probe() async {
    final snapshot = await load();
    final plugin = HubPlugin(environment: environment, home: home);
    final started = plugin.start();
    var connected = false;
    try {
      await started.timeout(probeTimeout);
      connected = (await plugin.status()).connected;
    } on Object {
      // Timeout (hub not answering) or hub rejection: honest "unreachable".
      // dispose() below completes the abandoned start() with an error —
      // marked handled so it never surfaces as an unhandled async error.
      started.ignore();
    } finally {
      await plugin.dispose();
    }
    return snapshot.withProbe(connected);
  }
}

/// Creates the platform [DapHubService] (IO platforms).
DapHubService createDapHubService() => IoDapHubService();
