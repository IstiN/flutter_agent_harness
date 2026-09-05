/// Agent-host wiring for the DAP hub (issue #23 G3): resolves (or creates
/// and persists) the extension identity, runs one [DapClient], feeds
/// decrypted inbound mail into the host's shared mail intake, and exposes
/// the agent-facing tools (`dap_dm`, `dap_peers`).
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart'
    show ToolExecutionResult;
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';

import 'dap_client.dart';
import 'dap_frames.dart';

/// faDap settings from chrome.storage plus the persistence seams for the
/// identity key file (stored as `faDapKey` in the key-file format, so an
/// export stays byte-compatible with the CLI's `~/.dap` identity).
final class DapConfig {
  DapConfig({
    required this.url,
    required this.name,
    required this.loadKeyFile,
    required this.saveKeyFile,
  });

  final String url;

  /// Display name for the hello (cosmetic; ids are how peers address us).
  final String name;
  final Future<String?> Function() loadKeyFile;
  final Future<void> Function(String) saveKeyFile;

  /// Stable across reconnects/restarts: same config (url+name) keeps the
  /// live client instead of dropping the connection.
  bool sameTargetAs(DapConfig other) => url == other.url && name == other.name;
}

/// Owns the extension's hub presence for one [DapConfig]. Created by
/// [AgentHost] when faDap config exists; disposed on reconfigure.
final class DapIntegration {
  DapIntegration({
    required this.config,
    required this.pushMail,
    required this.onStatusChanged,
  });

  final DapConfig config;
  final void Function(String from, String text) pushMail;
  final void Function() onStatusChanged;

  DapClient? _client;
  Map<String, dynamic> _status = const {'phase': 'disconnected'};

  /// Latest hub status for the host's state snapshot (null = no hub).
  /// Reports even when the client never came up — a silent failure is
  /// undebuggable from outside the service worker.
  Map<String, dynamic>? snapshot() => _status;

  late final AgentTool dapDm = AgentTool(
    name: 'dap_dm',
    description:
        'Send an end-to-end encrypted direct message to a peer on the DAP '
        'hub. "to" is the peer\'s exact 16-hex agent id, or a unique ONLINE '
        'display name (list them with dap_peers). Replies arrive as '
        '"[from <agentId>]" mail at the next turn boundary.',
    parameters: const {
      'type': 'object',
      'properties': {
        'to': {'type': 'string'},
        'text': {'type': 'string'},
      },
      'required': ['to', 'text'],
    },
    tier: ApprovalTier.exec,
    execute: (arguments, cancelToken, onUpdate) async {
      final to = '${arguments['to'] ?? ''}'.trim();
      final text = '${arguments['text'] ?? ''}';
      if (to.isEmpty || text.isEmpty) {
        throw ArgumentError('dap_dm needs non-empty "to" and "text"');
      }
      final client = _requireClient();
      return ToolExecutionResult.text(await client.sendDm(to, text));
    },
  );

  late final AgentTool dapPeers = AgentTool(
    name: 'dap_peers',
    description:
        'List agents currently ONLINE on the DAP hub, one "<name> <agentId>" '
        'per line. Use an id with dap_dm.',
    parameters: const {'type': 'object', 'properties': {}},
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async {
      final agents = await _requireClient().presence();
      final online = [
        for (final agent in agents)
          if (agent['online'] == true)
            '${agent['name'] ?? '(unnamed)'} ${agent['agentId']}',
      ];
      return ToolExecutionResult.text(
        online.isEmpty ? 'no agents online' : online.join('\n'),
      );
    },
  );

  List<AgentTool> get tools => [dapDm, dapPeers];

  /// Resolves the identity (loading or generating + persisting it), then
  /// starts the client. Quiet on failure — the status reflects it.
  Future<void> start() async {
    try {
      final stored = await config.loadKeyFile();
      final identity = stored != null
          ? await DapIdentity.fromKeyFile(stored)
          : await _freshIdentity();
      final client = DapClient(
        identity: identity,
        url: config.url,
        name: config.name,
        onMail: pushMail,
        onStatus: (status) {
          _status = status.toMap();
          onStatusChanged();
        },
      );
      _client = client;
      client.start();
    } on Object catch (e) {
      // A silent hub-presence failure is undebuggable — the console is the
      // only window into a service worker. Surface what actually broke.
      print('[fa] dap identity/start failed: $e');
      _status = {
        'phase': 'disconnected',
        'reason': 'identity unavailable',
        'error': '$e',
      };
      onStatusChanged();
    }
  }

  Future<void> stop() async {
    final client = _client;
    _client = null;
    await client?.stop();
  }

  DapClient _requireClient() {
    final client = _client;
    if (client == null) throw StateError('hub is not configured');
    return client;
  }

  Future<DapIdentity> _freshIdentity() async {
    final identity = await DapIdentity.generate();
    await config.saveKeyFile(await identity.toKeyFile());
    return identity;
  }
}
