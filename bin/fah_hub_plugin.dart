/// The `hub` built-in plugin for `fah`: bridges the vendored DAP hub client
/// (`package:fah_hub_client`) onto the real plugin API.
///
/// Everything here lives in `bin/` on purpose — the package imports
/// `dart:io`, and `lib/src/**` stays web-pure. The host maps the package's
/// mirrored seam types (`hub.AgentMessage`, `hub.PluginContext`, …) onto
/// the real `flutter_agent_harness` types field-by-field; the mirrors are
/// never imported into lib/.
///
/// Registered by default in `bin/fah.dart`: on startup the CLI connects to
/// the zero-config hub (`~/.dap`), inbound hub mail is drained into the
/// agent loop as steering messages, and the agent gets the `dap_*` tools
/// plus the `/dap` slash command.
library;

import 'dart:async';

import 'package:fah_hub_client/fah_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Plugin name used by `--plugin hub` and `.fah/packages.yaml`.
const _pluginName = 'hub';

/// Host for the vendored [hub.HubPlugin]: adapts the package's mirrored
/// plugin seam onto the real [FahPlugin] API and contributes the `dap_*`
/// tools, the `/dap` slash command, and the hub-mail inbox.
final class HubPluginHost implements FahPlugin {
  /// Creates the host around [hubPlugin].
  HubPluginHost(hub.HubPlugin hubPlugin) : _hub = hubPlugin;

  final hub.HubPlugin _hub;

  @override
  String get name => _pluginName;

  @override
  void register(PluginContext context) {
    _hub.register(
      hub.PluginContext(
        io: _HubPluginIO(context.io),
        // The CLI passes this plugin's already-scoped section; the package
        // register reads `config['hub']`.
        config: {_pluginName: context.config},
      ),
    );
    unawaited(
      _connect(context).catchError((Object e, StackTrace s) {
        context.io.writeln('[hub] connect failed: $e');
      }),
    );
    context.registerSlashCommand('/dap', (args) => _dapSlash(context, args));
    context.registerExternalInbox(
      ExternalInbox(drain: _drainHubMail, hasPending: _hasPendingHubMail),
    );
    for (final tool in _dapTools()) {
      context.registerTool(tool);
    }
  }

  /// Connects in the background (`register` is sync void); failures
  /// surface on the terminal instead of blocking startup. On the
  /// zero-config default URL (usually just "no hub running") a failure
  /// prints one quiet hint line; an explicitly configured hub that fails
  /// keeps its full error.
  Future<void> _connect(PluginContext context) async {
    try {
      await _hub.start();
    } on Object catch (error) {
      if (_hub.isDefaultUrl) {
        context.io.writeln('[hub] not configured — set DAP_HUB_URL to enable');
        return;
      }
      context.io.writeln('[hub] connect failed: $error');
    }
  }

  /// `/dap` — no args: connection status; `/dap <host> [name] [channel]`:
  /// move the live connection to another hub.
  Future<void> _dapSlash(PluginContext context, List<String> args) async {
    final positional = args.where((arg) => arg.isNotEmpty).toList();
    try {
      if (positional.isEmpty) {
        final status = await _hub.status();
        context.io.writeln(
          'hub ${status.connected ? 'connected' : 'disconnected'} — '
          'agentId: ${status.agentId ?? '-'}, name: ${status.name ?? '-'}, '
          'url: ${status.url ?? '-'}',
        );
        return;
      }
      final connection = await _hub.connectTo(
        positional[0],
        name: positional.length > 1 ? positional[1] : null,
        channel: positional.length > 2 ? positional[2] : null,
      );
      context.io.writeln(
        'connected to ${connection.url} as ${connection.agentId} — '
        'channels: ${connection.channels.join(', ')}',
      );
    } on Object catch (error) {
      context.io.writeln('[hub] $error');
    }
  }

  /// Hub mail → real steering messages. The package drain closure already
  /// swallows transport errors (empty list); the guard here only covers
  /// mapping surprises, keeping the never-throw steering contract.
  Future<List<AgentMessage>> _drainHubMail() async {
    try {
      return [
        for (final message in await _hub.externalSteeringSource())
          AgentMessage(
            id: message.id,
            fromId: message.fromId,
            toId: message.toId,
            text: message.text,
            sentAt: message.sentAt,
            hops: message.hops,
          ),
      ];
    } on Object {
      return const [];
    }
  }

  /// Non-draining probe: unread mail in our own hub inbox.
  Future<bool> _hasPendingHubMail() async {
    final repository = _hub.repository;
    final agentId = _hub.agentId;
    // No agentId yet (pre-welcome): peek the '' mailbox would report the
    // frames parked there forever and churn the wake loop — report empty.
    if (repository == null || agentId == null) return false;
    final pending = await repository.peek(agentId);
    return pending.isNotEmpty;
  }

  /// The `dap_*` tools: status/peers are read-only; dm/invite/connect
  /// reach the network and are gated at the exec tier (like MCP tools).
  List<AgentTool> _dapTools() => [
    AgentTool(
      name: 'dap_status',
      label: 'dap_status',
      tier: ApprovalTier.read,
      description:
          'Show the DAP hub connection: our agent id, display name, hub '
          'url, connected state, joined channels, and hello/welcome '
          'handshake counters.',
      parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
      execute: (arguments, cancelToken, onUpdate) async {
        final status = await _hub.status();
        return ToolExecutionResult(
          content: [
            TextContent(
              text:
                  'agentId: ${status.agentId ?? '-'}\n'
                  'name: ${status.name ?? '-'}\n'
                  'url: ${status.url ?? '-'}\n'
                  'connected: ${status.connected}\n'
                  'channels: '
                  '${status.channels.isEmpty ? '-' : status.channels.join(', ')}\n'
                  'handshakes: ${status.hellos} hello(s), '
                  '${status.welcomes} welcome(s)',
            ),
          ],
        );
      },
    ),
    AgentTool(
      name: 'dap_peers',
      label: 'dap_peers',
      tier: ApprovalTier.read,
      description:
          'List ONLINE peers known to the DAP hub. Your own entry is '
          'included and flagged self — do not DM yourself. Use the ids '
          'from this list as dap_dm recipients.',
      parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
      execute: (arguments, cancelToken, onUpdate) async {
        final peers = await _hub.peers();
        final text = peers.isEmpty
            ? 'no peers on the hub'
            : [
                for (final peer in peers)
                  '${peer.agentId} ${peer.name ?? '-'}'
                      '${peer.self ? ' (self)' : ''}',
              ].join('\n');
        return ToolExecutionResult(content: [TextContent(text: text)]);
      },
    ),
    AgentTool(
      name: 'dap_dm',
      label: 'dap_dm',
      tier: ApprovalTier.exec,
      description:
          'Send an end-to-end encrypted direct message to a hub peer. '
          '`to` is the 16-hex agent id or a display name (run dap_peers '
          'first); this is how hub mail is answered — hub mail must not be '
          'replied to with agent_message.',
      parameters: const {
        'type': 'object',
        'properties': {
          'to': {
            'type': 'string',
            'description': 'Recipient: 16-hex agent id or display name',
          },
          'text': {'type': 'string', 'description': 'Message body'},
        },
        'required': ['to', 'text'],
      },
      execute: (arguments, cancelToken, onUpdate) async {
        final to = arguments['to'] as String;
        final target = await _resolvePeer(to);
        final repository = _hub.repository;
        final agentId = _hub.agentId;
        if (repository == null || agentId == null) {
          throw StateError('not connected to a hub — run /dap to connect');
        }
        await repository.send(
          hub.AgentMessage(
            id: newMessageId(),
            fromId: agentId,
            toId: target,
            text: arguments['text'] as String,
            sentAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
        return ToolExecutionResult(
          content: [TextContent(text: 'DM sent to $target')],
        );
      },
    ),
    AgentTool(
      name: 'dap_invite',
      label: 'dap_invite',
      tier: ApprovalTier.exec,
      description:
          'Invite a peer into a channel: DMs them the channel keypair '
          '(their membership). An offline or unknown name arms a pending '
          'invite that is delivered automatically when they come online.',
      parameters: const {
        'type': 'object',
        'properties': {
          'nameOrId': {
            'type': 'string',
            'description': 'Peer display name or 16-hex agent id',
          },
          'channel': {
            'type': 'string',
            'description': 'Channel to invite into (default: the current room)',
          },
        },
        'required': ['nameOrId'],
      },
      execute: (arguments, cancelToken, onUpdate) async {
        final result = await _hub.inviteTo(
          arguments['nameOrId'] as String,
          channel: arguments['channel'] as String?,
        );
        if (!result.ok) {
          throw StateError('invite failed: ${result.error}');
        }
        return ToolExecutionResult(
          content: [
            TextContent(
              text: result.pending
                  ? 'invite armed for ${result.to} on ${result.channel} — '
                        'delivered when they come online'
                  : 'invite sent to ${result.to} on ${result.channel}',
            ),
          ],
        );
      },
    ),
    AgentTool(
      name: 'dap_connect',
      label: 'dap_connect',
      tier: ApprovalTier.exec,
      description:
          'Connect the agent to any DAP hub at runtime. `host` is a bare '
          'host, host:port, or ws(s):// URL; an optional `name` is the '
          'display name AND identity (a new name is a new agentId); an '
          'optional `channel` is the default room joined after connecting.',
      parameters: const {
        'type': 'object',
        'properties': {
          'host': {
            'type': 'string',
            'description': 'Hub host, host:port, or ws(s):// URL',
          },
          'name': {
            'type': 'string',
            'description': 'Display name AND identity (new name = new agentId)',
          },
          'channel': {
            'type': 'string',
            'description': 'Default room to join after connecting',
          },
        },
        'required': ['host'],
      },
      execute: (arguments, cancelToken, onUpdate) async {
        final connection = await _hub.connectTo(
          arguments['host'] as String,
          name: arguments['name'] as String?,
          channel: arguments['channel'] as String?,
        );
        return ToolExecutionResult(
          content: [
            TextContent(
              text:
                  'connected to ${connection.url} as ${connection.agentId} — '
                  'channels: ${connection.channels.join(', ')}',
            ),
          ],
        );
      },
    ),
  ];

  /// Resolves [to] to a peer agent id: an exact id wins, otherwise the
  /// display name must match exactly one online peer. Ambiguity and
  /// no-match errors list the online peers so the model can retry.
  Future<String> _resolvePeer(String to) async {
    final peers = await _hub.peers();
    for (final peer in peers) {
      if (peer.agentId == to) return to;
    }
    final byName = peers.where((peer) => peer.name == to).toList();
    if (byName.length == 1) return byName.single.agentId;
    final online = [
      for (final peer in peers)
        '${peer.agentId} ${peer.name ?? '-'}'
            '${peer.online ? '' : ' (offline)'}',
    ].join('\n');
    throw StateError(
      byName.isEmpty
          ? 'no online peer matches "$to" — online peers:\n$online'
          : 'peer name "$to" is ambiguous — online peers:\n$online',
    );
  }
}

/// Bridges the real [PluginIO] onto the package's mirrored interface.
final class _HubPluginIO implements hub.PluginIO {
  _HubPluginIO(this._io);

  final PluginIO _io;

  @override
  void write(String text) => _io.write(text);

  @override
  void writeln(String text) => _io.writeln(text);
}
