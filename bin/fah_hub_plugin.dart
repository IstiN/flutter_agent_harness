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
import 'dart:io' show Platform;

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Plugin name used by `--plugin hub` and `.fah/packages.yaml`.
const _pluginName = 'hub';

/// Host for the vendored [hub.HubPlugin]: adapts the package's mirrored
/// plugin seam onto the real [FahPlugin] API and contributes the `dap_*`
/// tools, the `/dap` slash command, and the hub-mail inbox.
final class HubPluginHost implements FahPlugin {
  /// Creates the host around [hubPlugin]. [environment]/[home] override
  /// the process defaults — tests inject them so the `~/.dap` resolution
  /// and the `DAP_*` env overrides are deterministic. When
  /// [fabricDeliversMail] is true, the hub-backed messaging repository
  /// (issue #27) is wired into the fabric and owns hub mail delivery —
  /// this host skips its separate external inbox so hub frames have
  /// exactly one consumer (the main inbox drain).
  HubPluginHost(
    hub.HubPlugin hubPlugin, {
    Map<String, String>? environment,
    String? home,
    this.fabricDeliversMail = false,
  }) : _hub = hubPlugin,
       // ignore: prefer_initializing_formals
       _environment = environment ?? Platform.environment,
       // ignore: prefer_initializing_formals
       _home = home;

  /// Whether the messaging-fabric composite consumes hub mail instead of
  /// this host's external inbox.
  final bool fabricDeliversMail;

  final hub.HubPlugin _hub;
  final Map<String, String> _environment;

  /// Home directory override for the `~/.dap/config.json` resolution.
  final String? _home;

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
    context.registerSlashCommand(
      '/dap',
      (args) => _dapSlash(context, args),
      description:
          'DAP hub — end-to-end-encrypted messaging between agents '
          '(status / connect / secret)',
    );
    // The inbox stays unconditional EXCEPT when the fabric composite owns
    // delivery (issue #27): registering both would race one hub frame
    // between two consumers.
    if (!fabricDeliversMail) {
      context.registerExternalInbox(
        ExternalInbox(drain: _drainHubMail, hasPending: _hasPendingHubMail),
      );
    }
    // Issue #19 AC1: register the dap_* tools only when a hub is actually
    // configured. On the zero-config default URL every tool call would
    // dead-end ("no hub running"), so an unconfigured install hands the
    // model no such tools. Resolution = the same precedence the connection
    // uses (env > `hub:` section > `~/.dap/config.json` > default). The
    // /dap slash command and the inbox stay unconditional: `/dap <host>`
    // connects on demand and the tools appear on the next launch.
    final settings = hub.resolveDapSettings(
      config: hub.HubConfig.fromMap(context.config, _environment),
      environment: _environment,
      home: _home,
    );
    if (settings.url != hub.defaultDapUrl) {
      for (final tool in _dapTools()) {
        context.registerTool(tool);
      }
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

  /// `/dap` — no args: the guided menu when the host is interactive
  /// (status / connect / master secret / about), a one-line status
  /// otherwise; `/dap <host> [name] [channel]`: move the live connection
  /// to another hub.
  Future<void> _dapSlash(PluginContext context, List<String> args) async {
    final positional = args.where((arg) => arg.isNotEmpty).toList();
    final pick = context.pickOption;
    if (positional.isEmpty && pick != null) {
      await _dapMenu(context, pick);
      return;
    }
    try {
      if (positional.isEmpty) {
        await _printStatus(context);
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

  /// Whether the plugin's kill switch is set (mirrors the hub plugin's
  /// own check, without throwing).
  bool get _dapEnabled => (_environment[hub.envMasterSecret] ?? '').isNotEmpty;

  /// The one-line status, friendly when DAP is disabled.
  Future<void> _printStatus(PluginContext context) async {
    if (!_dapEnabled) {
      context.io.writeln(
        'DAP disabled — no master secret. '
        'Run /dap and choose "Set master secret…", or export '
        'DAP_MASTER_SECRET before launching.',
      );
      return;
    }
    final status = await _hub.status();
    if (!status.connected) {
      // A disconnected status still carries the configured url (often a
      // stale loopback port from an old session) — say what to do next
      // instead of leaving the user staring at a dead address.
      context.io.writeln(
        'hub disconnected${status.url != null ? ' — ${status.url}' : ''}\n'
        'Start a hub, then pick "Connect to a hub…" in /dap to dial it.',
      );
      return;
    }
    context.io.writeln(
      'hub connected — '
      'agentId: ${status.agentId ?? '-'}, name: ${status.name ?? '-'}, '
      'url: ${status.url ?? '-'}',
    );
  }

  /// The guided `/dap` menu: every entry explains itself; inputs are
  /// interactive (masked for the secret).
  Future<void> _dapMenu(PluginContext context, PluginPickOption pick) async {
    final choice = await pick(
      'DAP — Distributed Agents Platform: end-to-end-encrypted '
      'messaging between agents over a local hub',
      [
        (
          'status',
          'Connection status',
          'agent id, display name, hub url, joined channels',
        ),
        (
          'connect',
          'Connect to a hub…',
          'enter a host, optional display name and channel',
        ),
        (
          'secret',
          'Set master secret…',
          'masked input — enables DAP for this session',
        ),
        (
          'about',
          'What is DAP?',
          'a short explainer of the hub, channels and secrets',
        ),
      ],
    );
    switch (choice) {
      case 'status':
        await _printStatus(context);
      case 'connect':
        await _menuConnect(context);
      case 'secret':
        await _menuSetSecret(context);
      case 'about':
        context.io.writeln(_aboutText);
      case null:
        break; // cancelled — stay quiet
    }
  }

  /// Connect…: interactive host (+ optional name / channel) prompts.
  Future<void> _menuConnect(PluginContext context) async {
    if (!_dapEnabled) {
      context.io.writeln(
        'DAP needs a master secret first — pick '
        '"Set master secret…" in the /dap menu.',
      );
      return;
    }
    final ask = context.askLine;
    if (ask == null) return;
    // Beat the boot race: the plugin connects in the background at
    // register time, so an immediate /dap connect can land before the
    // repository exists. start() is a no-op once started; a dead initial
    // hub must not wedge the menu, hence the timeout — the connect below
    // reports the real error either way.
    try {
      await _hub.start().timeout(const Duration(seconds: 8));
    } on Object {
      // The connect below reports the real error.
    }
    // Pre-fill the current hub url (the `(empty = …)` convention makes the
    // TUI prompt show it as the default): reconnecting to the configured
    // hub is an Enter away, and a stale port is easy to edit in place.
    final currentUrl = (await _hub.status()).url;
    final hostInput = await ask(
      currentUrl != null
          ? 'hub host (empty = $currentUrl): '
          : 'hub host (host:port or ws(s):// URL): ',
    );
    if (hostInput == null) return; // cancelled
    // The guided-flow convention: an empty answer keeps the default (the
    // TUI pre-fills it; line mode treats empty as "keep" too — Esc/Ctrl-C
    // is the cancel path, not an empty line).
    final host = hostInput.trim().isEmpty ? currentUrl : hostInput.trim();
    if (host == null || host.isEmpty) return;
    // NB: the `(empty = X)` phrasing is the guided-flow DEFAULT convention
    // — an empty submit resolves to X literally, so "leave empty for …"
    // must not use that shape or Enter would set the name to "default".
    final name = await ask('display name (leave empty for the default): ');
    final channel = await ask('channel (leave empty for the default room): ');
    try {
      final connection = await _hub.connectTo(
        host,
        name: name == null || name.isEmpty ? null : name,
        channel: channel == null || channel.isEmpty ? null : channel,
      );
      context.io.writeln(
        'connected to ${connection.url} as ${connection.agentId} — '
        'channels: ${connection.channels.join(', ')}',
      );
    } on Object catch (error) {
      context.io.writeln('[hub] $error');
    }
  }

  /// Set master secret: masked input, session-only enable, then
  /// the zero-config start (default hub) so the agent comes online.
  Future<void> _menuSetSecret(PluginContext context) async {
    final ask = context.askLine;
    if (ask == null) return;
    final secret = await ask(
      'DAP master secret (session only): ',
      secret: true,
    );
    if (secret == null || secret.isEmpty) return;
    try {
      _environment[hub.envMasterSecret] = secret;
    } on Object {
      context.io.writeln(
        '[hub] this host\'s environment is read-only — export '
        'DAP_MASTER_SECRET before launching instead',
      );
      return;
    }
    context.io.writeln(
      'master secret set for this session — '
      'export DAP_MASTER_SECRET to make it permanent',
    );
    try {
      await _hub.start();
      await _printStatus(context);
    } on Object catch (error) {
      context.io.writeln('[hub] secret set; connect failed: $error');
    }
  }

  /// The `/dap → about` explainer.
  static const _aboutText =
      'DAP (Distributed Agents Platform) is a local message hub for '
      'agents: a zero-knowledge relay (usually ws://127.0.0.1:8787/ws) '
      'that routes end-to-end-encrypted channels and direct messages '
      'between agent harnesses — the hub never sees plaintext.\n'
      'Enable it by setting a master secret: export DAP_MASTER_SECRET '
      'before launching, or choose "Set master secret…" in this '
      'menu (session only). Once connected, /dap shows the connection, '
      '/dap <host> moves it, and the dap_* tools let the agent see '
      'peers, DM them, and manage channel invites.';

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
