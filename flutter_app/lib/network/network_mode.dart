// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The top-level app mode of the Fa shell (issue #955): the classic local
/// agent surface or the fa_network client surface. One app, one sidebar,
/// two worlds — network mode is a mode, never a fork.
enum AppMode {
  local,
  network;

  static AppMode parse(String? wire) =>
      wire == 'network' ? AppMode.network : AppMode.local;

  String get wire => name;
}

/// Tiny persisted store for the network-mode shell state: the current
/// [AppMode] plus the last selected network/channel, so a relaunch lands
/// the human exactly where they left (AC-N1). Same tiny-JSON pattern as
/// `AppsHomeModeStore` (`apps_home_mode.json`) — non-secret by design
/// (session tokens and channel keys live in the KeyWallet, never here).
class NetworkModeStore {
  NetworkModeStore._(
    this._env,
    this._mode,
    this._lastNetworkId,
    this._lastChannelId,
  );

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'network_mode.json';

  static const _version = 1;

  final ExecutionEnv? _env;
  AppMode _mode;
  String? _lastNetworkId;
  String? _lastChannelId;

  /// Loads the persisted state; a missing, unreadable, corrupt, or
  /// wrong-version file yields the first-run default (local mode, no
  /// selection) — boot must never crash on prefs.
  static Future<NetworkModeStore> load(ExecutionEnv env) async {
    var mode = AppMode.local;
    String? networkId;
    String? channelId;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> && decoded['version'] == _version) {
          mode = AppMode.parse(decoded['mode'] as String?);
          networkId = decoded['lastNetworkId'] as String?;
          channelId = decoded['lastChannelId'] as String?;
        }
      }
    } on Object {
      // Corrupt or incompatible file → defaults, never crash boot.
    }
    return NetworkModeStore._(env, mode, networkId, channelId);
  }

  AppMode get mode => _mode;
  String? get lastNetworkId => _lastNetworkId;
  String? get lastChannelId => _lastChannelId;

  /// Records the new state and persists it best-effort: a failed write
  /// must never block a mode toggle.
  Future<void> setState({
    AppMode? mode,
    String? lastNetworkId,
    String? lastChannelId,
  }) async {
    _mode = mode ?? _mode;
    _lastNetworkId = lastNetworkId;
    _lastChannelId = lastChannelId;
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({
          'version': _version,
          'mode': _mode.wire,
          'lastNetworkId': _lastNetworkId,
          'lastChannelId': _lastChannelId,
        }),
      );
    } on Object {
      // Best effort: persistence must never block the UI.
    }
  }
}

/// The network-mode navigation state machine (issue #955):
/// `local → networkPicker → network(networkId) → channel(channelId)`.
/// Thin [ChangeNotifier] over [NetworkModeStore]; every transition
/// notifies listeners and persists. The controller holds no backend
/// state — networks/channels/messages flow through `NetworkSession`.
class NetworkModeController extends ChangeNotifier {
  NetworkModeController(this._store);

  /// A controller without persistence (tests, golden fixtures).
  factory NetworkModeController.inMemory({
    AppMode mode = AppMode.local,
    String? networkId,
    String? channelId,
  }) {
    final store = _InMemoryNetworkModeStore(mode, networkId, channelId);
    return NetworkModeController(store);
  }

  final NetworkModeStore _store;

  /// Transient (never persisted) anonymous showcase browsing: a public
  /// network id being previewed read-only, without a join. Set by
  /// [viewShowcase], cleared by any real navigation.
  String? get showcaseNetworkId => _showcaseNetworkId;
  String? _showcaseNetworkId;

  AppMode get mode => _store.mode;
  String? get networkId => _store.lastNetworkId;
  String? get channelId => _store.lastChannelId;

  /// Opens the anonymous read-only showcase of a public network (no
  /// membership, no keys — the catalog tile tap). Stays in network mode
  /// with no selected network; the picker stays reachable behind it.
  Future<void> viewShowcase(String networkId) async {
    _showcaseNetworkId = networkId;
    await _apply(mode: AppMode.network, networkId: null, channelId: null);
  }

  /// Enters network mode on [networkId] (channel cleared).
  Future<void> enterNetwork(String networkId) =>
      _apply(mode: AppMode.network, networkId: networkId, channelId: null);

  /// Selects [channelId] inside the current network.
  Future<void> selectChannel(String channelId) =>
      _apply(mode: AppMode.network, networkId: networkId, channelId: channelId);

  /// Back to the networks picker (stays in network mode). Also closes
  /// the anonymous showcase preview.
  Future<void> backToNetworks() {
    _showcaseNetworkId = null;
    return _apply(mode: AppMode.network, networkId: null, channelId: null);
  }

  /// Back to the channel rail of the current network.
  Future<void> backToChannels() =>
      _apply(mode: AppMode.network, networkId: networkId, channelId: null);

  /// Back to the classic local surface; selection cleared.
  Future<void> exitToLocal() =>
      _apply(mode: AppMode.local, networkId: null, channelId: null);

  Future<void> _apply({
    required AppMode mode,
    required String? networkId,
    required String? channelId,
  }) async {
    // Any real navigation (network enter/back, local exit) leaves the
    // showcase preview; only viewShowcase itself sets it.
    if (networkId != null || mode == AppMode.local) _showcaseNetworkId = null;
    await _store.setState(
      mode: mode,
      lastNetworkId: networkId,
      lastChannelId: channelId,
    );
    notifyListeners();
  }
}

class _InMemoryNetworkModeStore extends NetworkModeStore {
  _InMemoryNetworkModeStore(AppMode mode, String? networkId, String? channelId)
    : super._(null, mode, networkId, channelId);
}
