// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show JsonlSessionRepo, SessionMetadata;
import 'package:flutter_agent_harness/io.dart' show LocalExecutionEnv;

import 'package:fa/services/sessions_root.dart';

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
    final binding = _readBinding();
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
      inboundMode: binding.$1,
      boundSessionTitle: binding.$2,
    );
  }

  /// The `boundSession` block of the raw config (`{mode, sessionId?,
  /// title?}`) — readDapConfig returns the full map, so app-only keys
  /// ride along untouched by the package's persist helpers.
  (DapInboundMode, String?) _readBinding() {
    final raw = readDapConfig(defaultDapConfigFile(home, environment));
    final bound = raw['boundSession'];
    if (bound is! Map) return (DapInboundMode.currentSession, null);
    final mode = switch ('${bound['mode'] ?? ''}') {
      'dedicated' => DapInboundMode.dedicated,
      'named' => DapInboundMode.named,
      _ => DapInboundMode.currentSession,
    };
    final title = '${bound['title'] ?? ''}'.trim();
    return (mode, title.isEmpty ? null : title);
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
  Future<void> saveBinding(
    DapInboundMode mode, {
    String? sessionId,
    String? sessionTitle,
  }) async {
    final path = defaultDapConfigFile(home, environment);
    final next = Map<String, dynamic>.of(readDapConfig(path));
    if (mode == DapInboundMode.currentSession) {
      next.remove('boundSession');
    } else {
      next['boundSession'] = <String, dynamic>{
        'mode': mode.name,
        if (sessionId != null && sessionId.isNotEmpty)
          'sessionId': sessionId,
        if (sessionTitle != null && sessionTitle.isNotEmpty)
          'title': sessionTitle,
      };
    }
    final target = File(path);
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }
    await target.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(next)}\n',
    );
  }

  @override
  Future<List<DapBindableSession>> listBindableSessions() async {
    // The app's own sessions: every candidate root (the shared App Group
    // container + the ~/.fah fallback on macOS), newest activity first.
    final env = LocalExecutionEnv();
    final out = <DapBindableSession>[];
    for (final root in allSessionRoots(
      defaultSessionsRoot(Directory.current.path),
    )) {
      try {
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: root);
        final metas = await repo.list();
        for (final meta in metas) {
          out.add((id: meta.id, title: _sessionTitle(meta)));
        }
      } on Object {
        // Unreadable root — other roots still list.
      }
    }
    // Dedup by id (a session visible from two roots lists once).
    final seen = <String>{};
    return [
      for (final entry in out)
        if (seen.add(entry.id)) entry,
    ].take(50).toList();
  }

  /// Display label for the picker: the app-written title/name metadata,
  /// else a short id.
  static String _sessionTitle(SessionMetadata meta) {
    final raw = meta.metadata;
    for (final key in const ['title', 'name', 'displayName']) {
      final value = raw?[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    final id = meta.id;
    return 'session ${id.length > 8 ? id.substring(0, 8) : id}';
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
    } finally {
      await plugin.dispose();
      // fah_hub_client 0.2.5 (verified in hub_plugin.dart): dispose()
      // neither cancels nor awaits an in-flight start() — it only tears
      // down the fields it sees. Two interleavings matter: dispose after
      // start() assigned _repository makes start() die on a null
      // assertion (`_repository!`) — marked handled here, after dispose,
      // so anything dispose induces is covered; dispose before start()
      // touches its fields is a no-op that leaves start() running.
      started.ignore();
      // ponytail: residual ceiling — start() has no cancel API, so a
      // timeout that lands before start() assigns its fields leaves the
      // socket + reconnect loop alive with no owner. Upgrade path: a
      // close()-style API in the package, then await it here.
    }
    return snapshot.withProbe(connected);
  }
}

/// Creates the platform [DapHubService] (IO platforms).
DapHubService createDapHubService() => IoDapHubService();
