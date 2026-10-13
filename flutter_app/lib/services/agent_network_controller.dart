// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'agent_network_store.dart';
import 'agent_network_transport.dart';

/// The app agent's membership in the DAP hub network (issue #402 AC3).
///
/// Owns the opt-in settings ([AgentNetworkStore]) and the
/// [HubMessagingRepository] lifecycle; composes the hub repository OVER
/// the app's swappable file fabric through [FallbackMessagingRepository]
/// (the exact shape the CLI's `buildAgentFabric` builds), so the agent's
/// existing inbox probe drains hub mail with no further plumbing. Opting
/// out swaps back to the bare file layer.
///
/// Failure honesty (E4): an unreachable hub boots the app fully usable on
/// the file fabric; the link retries in the background and [state] says
/// what is really going on.
class AgentNetworkController extends ChangeNotifier {
  /// Creates a controller. [fileLayer] is the app's file messaging
  /// repository (the fallback side of the composition) and [fileFabric]
  /// the swappable wrapper the agent actually uses — [start] swaps the
  /// composite in. [transport] and the identity loader come from the
  /// platform seam — null where the network is unsupported (web).
  AgentNetworkController({
    required this._env,
    required this._fileLayer,
    required this._fileFabric,
    HubTransport? transport,
    Future<HubIdentity?> Function(String? path)? loadIdentity,
    Future<AgentNetworkProvision?> Function()? provision,
  }) : _provision = provision,
       _transport = transport ?? platformHubTransport,
       _loadIdentity = loadIdentity ?? loadOrCreateIdentity {
    _store = AgentNetworkStore.inMemory();
  }

  final ExecutionEnv _env;
  final FileMessagingRepository _fileLayer;
  final SwappableMessagingRepository _fileFabric;
  final Future<AgentNetworkProvision?> Function()? _provision;
  final HubTransport? _transport;
  final Future<HubIdentity?> Function(String? path)? _loadIdentity;

  late AgentNetworkStore _store;
  HubMessagingRepository? _hub;
  StreamSubscription<HubLinkState>? _linkSub;
  bool _disposed = false;

  /// The platform seam answers (false on web).
  bool get supported => _transport != null && _loadIdentity != null;

  AgentNetworkStore get store => _store;

  /// The live link state (null = not joined).
  HubLinkState? get state => _hub?.state;

  /// This agent's hub address (null = not joined / still connecting).
  String? get agentId => _hub?.agentId;

  /// Loads the persisted settings; joins when enabled. Call once at boot
  /// (the service construction path).
  Future<void> start() async {
    _store = await AgentNetworkStore.load(_env);
    // First run with a hub URL provisioned out-of-band (sandbox
    // `.dap/config.json`, e.g. pushed over adb on a phone with no usable
    // taps): adopt it and join — once; later the user's own settings win.
    if (!_store.persisted && supported) {
      final seed = await _safeProvision();
      if (seed != null) {
        await _store.setConnection(url: seed.url, name: seed.name);
        await _store.setEnabled(true);
      }
    }
    if (_store.enabled) await _join();
    notifyListeners();
  }

  Future<AgentNetworkProvision?> _safeProvision() async {
    try {
      final custom = _provision;
      if (custom != null) return await custom();
      return await _provisionFromSandboxDap();
    } on Object {
      return null;
    }
  }

  /// Default provisioning source: `<sandbox>/.dap/config.json`
  /// (`{"url": ..., "name": ...}`), the same file the DAP connection editor
  /// writes on mobile.
  Future<AgentNetworkProvision?> _provisionFromSandboxDap() async {
    final text = (await _env.readTextFile(
      '${_env.cwd}/.dap/config.json',
    )).valueOrNull;
    if (text == null) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final url = '${decoded['url'] ?? ''}'.trim();
    if (url.isEmpty) return null;
    final name = '${decoded['name'] ?? ''}'.trim();
    return AgentNetworkProvision(url: url, name: name.isEmpty ? null : name);
  }

  Future<void> setEnabled(bool value) async {
    await _store.setEnabled(value);
    if (_disposed) return;
    if (value) {
      await _join();
    } else {
      await _leave();
    }
    notifyListeners();
  }

  /// Persists a connection change; a live link restarts onto the new
  /// settings (the /settings flow).
  Future<void> saveConnection({
    String? url,
    String? token,
    String? name,
  }) async {
    await _store.setConnection(url: url, token: token, name: name);
    if (_disposed) return;
    if (_store.enabled) {
      await _leave();
      await _join();
    }
    notifyListeners();
  }

  /// The fabric directory (the roster view). Empty when not joined —
  /// callers render the file-fabric-only world.
  Future<List<MailboxEntry>> peers() async {
    final hub = _hub;
    if (hub == null || !hub.isConnected) return const [];
    try {
      return await hub.directory();
    } on Object {
      return const [];
    }
  }

  /// Sends a DM through the composite fabric: hub-resolvable targets go
  /// hub-ward, everything else lands in the file inbox (offline carrier).
  Future<void> sendDm(String toId, String text) async {
    await _fileFabric.send(
      AgentMessage(
        id: 'dm-${DateTime.now().microsecondsSinceEpoch}',
        fromId: 'main',
        toId: toId,
        text: text,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<void> _join() async {
    if (!supported || _hub != null) return;
    final identity = await _loadIdentity!(identityPathFor(_env.cwd));
    final hub = HubMessagingRepository(
      url: Uri.parse(_store.url),
      transport: _transport!,
      identity: identity,
      token: _store.token.isEmpty ? null : _store.token,
      name: _store.name,
      onLog: (line) => debugPrint('[agent-network] $line'),
    );
    _hub = hub;
    _linkSub = hub.stateChanges.listen((_) => notifyListeners());
    await hub.start();
    // Composite over the file layer (the CLI buildAgentFabric shape).
    final composite = FallbackMessagingRepository(
      primary: hub,
      fallback: _fileLayer,
    );
    composite.primaryMailbox = () => 'main';
    _fileFabric.swap(composite);
  }

  Future<void> _leave() async {
    final hub = _hub;
    _hub = null;
    await _linkSub?.cancel();
    _linkSub = null;
    // Back to the bare file layer BEFORE the hub stops: no drain window
    // where mail would hit a stopped primary.
    _fileFabric.swap(_fileLayer);
    await hub?.stop();
    await hub?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_leave());
    super.dispose();
  }
}

/// A hub connection provisioned outside the app UI (see
/// [AgentNetworkController.start]).
class AgentNetworkProvision {
  const AgentNetworkProvision({required this.url, this.name});

  /// The hub websocket URL.
  final String url;

  /// The agent's roster name, if provisioned.
  final String? name;
}
