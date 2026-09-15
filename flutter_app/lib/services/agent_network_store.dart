// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Whether the app's agent joins the DAP hub network as a live member
/// (issue #402 AC3), and with which connection. Persisted as JSON at
/// `agent_network.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same tiny-store pattern as `apps_home_mode.json`.
///
/// The hub URL and pairing token ride the same shape as the CLI's
/// `~/.dap/config.json` connection, but live app-side: the agent
/// membership is this app's own decision (E3 — no scanning magic, the
/// address + token are entered by hand, prefilled for the macOS
/// loopback default).
class AgentNetworkStore {
  AgentNetworkStore._(
    this._env,
    this._enabled,
    this._url,
    this._token,
    this._name,
  );

  /// A store without persistence (tests): setters flip memory only.
  AgentNetworkStore.inMemory()
    : _env = null,
      _enabled = false,
      _url = defaultAgentNetworkUrl,
      _token = '',
      _name = defaultAgentNetworkName;

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'agent_network.json';

  /// Schema version of the JSON envelope.
  static const _version = 1;

  /// The zero-config macOS loopback default (mirrors the CLI).
  static const defaultAgentNetworkUrl = 'ws://127.0.0.1:8787/ws';

  /// The default agent display name on the hub roster.
  static const defaultAgentNetworkName = 'app-agent';

  final ExecutionEnv? _env;
  bool _enabled;
  String _url;
  String _token;
  String _name;

  bool get enabled => _enabled;
  String get url => _url;
  String get token => _token;
  String get name => _name;

  /// Loads the settings persisted in [env]; a missing, unreadable, or
  /// corrupt file yields the first-run default (off — joining the network
  /// is an explicit opt-in).
  static Future<AgentNetworkStore> load(ExecutionEnv env) async {
    var enabled = false;
    var url = defaultAgentNetworkUrl;
    var token = '';
    var name = defaultAgentNetworkName;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> && decoded['version'] == _version) {
          enabled = decoded['enabled'] == true;
          url = '${decoded['url'] ?? defaultAgentNetworkUrl}'.trim();
          token = '${decoded['token'] ?? ''}';
          final savedName = '${decoded['name'] ?? defaultAgentNetworkName}'
              .trim();
          name = savedName.isEmpty ? defaultAgentNetworkName : savedName;
        }
      }
      // Corrupt or incompatible file → the defaults, never crash boot.
    } on Object {
      // (handled above: fall through to the defaults)
    }
    return AgentNetworkStore._(env, enabled, url, token, name);
  }

  Future<void> _persist() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({
          'version': _version,
          'enabled': _enabled,
          'url': _url,
          'token': _token,
          'name': _name,
        }),
      );
    } on Object {
      // Best effort: an unwritable root keeps the app running; the
      // settings just do not survive the restart.
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _persist();
  }

  Future<void> setConnection({String? url, String? token, String? name}) async {
    if (url != null && url.trim().isNotEmpty) _url = url.trim();
    if (token != null) _token = token;
    if (name != null && name.trim().isNotEmpty) _name = name.trim();
    await _persist();
  }
}
