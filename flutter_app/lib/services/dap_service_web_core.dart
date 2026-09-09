// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dap_service.dart';

/// Request/response bridge into the extension service worker
/// (`chrome.runtime.sendMessage`). Injected so this core stays
/// VM-testable — the js_interop defaults live in `dap_service_web.dart`.
typedef SwSendMessage = Future<Object?> Function(Map<String, Object?> message);

/// `chrome.storage.local.get` for one key, resolving to the raw storage
/// result map (`{key: value}`). Injected for the same reason as
/// [SwSendMessage].
typedef SwStorageGet = Future<Object?> Function(String key);

/// The zero-config default URL (mirrors `fah_hub_client`'s `defaultDapUrl`,
/// which cannot be imported here without dragging in `dart:io`).
const defaultWebDapUrl = 'ws://127.0.0.1:8787/ws';

/// `host:8787` → `ws://host:8787/ws` — the same normalization the CLI
/// applies (`fah_hub_client`'s `normalizeDapHost`, re-implemented so this
/// file stays IO-free).
String normalizeWebDapHost(String host) {
  final withScheme = host.startsWith(RegExp(r'wss?://')) ? host : 'ws://$host';
  final uri = Uri.parse(withScheme);
  final path = (uri.path.isEmpty || uri.path == '/') ? '/ws' : uri.path;
  return uri.replace(path: path).toString();
}

/// The extension-hosted [DapHubService]: the panel app cannot open its own
/// hub connection (the service worker already holds one for the same
/// identity — a second dial would evict it), so settings read the
/// configured connection from `chrome.storage` (`faDap`, the same key the
/// SW agent boots from) and the live phase/agentId from the SW's status
/// snapshot, and saves go through the SW's `hub.save` handler (which
/// reconfigures the live agent without a reboot).
final class ExtensionDapHubService implements DapHubService {
  ExtensionDapHubService({
    required SwSendMessage sendMessage,
    required SwStorageGet storageGet,
    this.probeTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _sendMessage = sendMessage,
       _storageGet = storageGet;

  final SwSendMessage _sendMessage;
  final SwStorageGet _storageGet;

  /// How long [probe] waits for a transient phase (connecting /
  /// reconnecting) to settle before reporting unreachable.
  final Duration probeTimeout;

  /// Poll step for the [probe] settle loop.
  final Duration pollInterval;

  @override
  Future<DapHubSnapshot> load() async {
    final config = await _readConfig();
    final live = await _readLive();
    return DapHubSnapshot(
      supported: true,
      url: config.url,
      name: config.name,
      agentId: live.agentId,
      // Channels v1 is not implemented in the extension client (no channel
      // key store) — the honest list is empty.
      channels: const [],
      connected: live.connected,
    );
  }

  @override
  Future<void> saveConnection({
    required String url,
    required String name,
  }) async {
    final reply = await _sendMessage({
      'type': 'hub.save',
      'url': normalizeWebDapHost(url.trim()),
      'name': name.trim(),
    });
    if (reply is Map && reply['ok'] == false) {
      throw StateError('hub.save failed: ${reply['error'] ?? 'unknown'}');
    }
  }

  @override
  Future<DapHubSnapshot> probe() async {
    final snapshot = await load();
    var live = await _readLive();
    // The SW owns a persistent connection with its own reconnects — a
    // probe polls briefly for a transient phase to settle instead of
    // dialing a second socket.
    final deadline = DateTime.now().add(probeTimeout);
    while (live.connected == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      live = await _readLive();
    }
    return snapshot.withProbe(live.connected ?? false);
  }

  // -- internals --------------------------------------------------------------

  /// The configured connection (`faDap` in chrome.storage), falling back
  /// to the zero-config default when never saved.
  Future<({String url, String? name})> _readConfig() async {
    try {
      final result = await _storageGet('faDap');
      if (result is Map) {
        final raw = result['faDap'];
        if (raw is Map) {
          final url = '${raw['url'] ?? ''}'.trim();
          if (url.isNotEmpty) {
            final name = '${raw['name'] ?? ''}'.trim();
            return (url: url, name: name.isEmpty ? null : name);
          }
        }
      }
    } on Object {
      // Storage blocked → fall through to the default.
    }
    return (url: defaultWebDapUrl, name: null);
  }

  /// The SW's live hub status: the `status` handler answers with the
  /// snapshot WRAPPED — `{ok: true, status: {…, agent: {hub: …}}}` —
  /// so unwrap the envelope first (a bare map without `status` is
  /// tolerated for tests/future relays).
  Future<({bool? connected, String? agentId})> _readLive() async {
    try {
      final reply = await _sendMessage({'type': 'status'});
      if (reply is! Map) return (connected: null, agentId: null);
      final wrapped = reply['status'];
      final envelope = wrapped is Map ? wrapped : reply;
      final agent = envelope['agent'];
      if (agent is! Map) return (connected: null, agentId: null);
      final hub = agent['hub'];
      if (hub is! Map) return (connected: null, agentId: null);
      return (
        connected: switch (hub['phase']) {
          'connected' => true,
          'disconnected' => false,
          _ => null, // connecting/reconnecting — not settled yet
        },
        agentId: hub['agentId'] is String ? hub['agentId'] as String : null,
      );
    } on Object {
      // SW unreachable (update in flight) — unknown, not "unreachable hub".
      return (connected: null, agentId: null);
    }
  }
}
