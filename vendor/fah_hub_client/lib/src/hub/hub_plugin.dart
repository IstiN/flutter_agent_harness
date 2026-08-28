/// `FahPlugin` (`.fah/packages.yaml` key `hub:`) wiring hub delivery into
/// the agent loop via `Agent.externalSteeringSource`.
///
/// Host wiring (upstream PR):
/// ```dart
/// final plugin = HubPlugin();
/// plugin.register(context);            // reads context.config['hub']
/// await plugin.start();
/// agent.externalSteeringSource = plugin.externalSteeringSource;
/// ```
library;

import 'dart:async';
import 'dart:io';

import '../fah/messaging.dart';
import '../fah/plugin.dart';
import 'channels.dart';
import 'dap_settings.dart';
import 'hub_client.dart';
import 'hub_config.dart';
import 'hub_messaging_repository.dart';
import 'identity.dart';

class HubPlugin implements FahPlugin {
  HubPlugin({Map<String, String>? environment, this.home})
      : environment = environment ?? Platform.environment;

  /// Injected environment (defaults to `Platform.environment`).
  final Map<String, String> environment;

  /// Home directory for the `~/.dap` zero-config layout (test seam;
  /// defaults to the platform home).
  final String? home;

  HubConfig _config = const HubConfig();
  PluginIO? _io;
  HubClient? _client;
  HubMessagingRepository? _repository;
  PendingInvites? _invites;
  HubIdentity? _identity;
  StreamSubscription<HubError>? _errorSub;

  @override
  String get name => 'hub';

  @override
  void register(PluginContext context) {
    final section = context.config['hub'];
    _config = HubConfig.fromMap(
      section is Map<String, dynamic> ? section : const {},
      environment,
    );
    _io = context.io;
  }

  /// Loads the identity, connects to the hub, and starts inbox delivery —
  /// zero-config: url/keyPath default per [resolveDapSettings] (env >
  /// `~/.dap/config.json` > `ws://127.0.0.1:8787/ws` /
  /// `~/.dap/keys/fah/<name|hostname>.key`), and the channel store picks up
  /// the machine-shared `~/.dap/channels.json`. Idempotent.
  Future<void> start({HubIdentity? identity}) async {
    if (_repository != null) return;
    final settings =
        resolveDapSettings(config: _config, environment: environment, home: home);
    _identity = identity ?? await HubIdentity.load(settings.keyPath);
    _client = HubClient(
      config: HubConfig(
        url: settings.url,
        name: settings.name,
        channels: _config.channels,
        channelSecrets: _config.channelSecrets,
      ),
      identity: _identity!,
      channelStore: await ChannelStore.fromFile(settings.channelsFile),
    );
    // Hub rejections must never be silent: print them to the host terminal.
    _errorSub = _client!.errors.listen(
      (e) => _io?.writeln('[hub] hub rejected a frame — ${e.code}: ${e.msg}'),
    );
    _repository = HubMessagingRepository(_client!);
    await _repository!.start();
    final invites = PendingInvites(
      client: _client!,
      configFile: defaultDapConfigFile(home),
      onNotice: (notice) => _io?.writeln('[hub] $notice'),
    );
    invites.start();
    _invites = invites;
    _io?.writeln('[hub] connected as ${_client!.agentId}');
  }

  /// Inbound hub mail, drained at every turn boundary. Contract per
  /// upstream: never throws, empty list when nothing arrived.
  ExternalSteeringSource get externalSteeringSource => () async {
        final repository = _repository;
        final agentId = _client?.agentId;
        if (repository == null || agentId == null) return const [];
        try {
          return await repository.drain(agentId);
        } on Object {
          return const <AgentMessage>[];
        }
      };

  /// The backing repository (exposed for hosts that prefer direct access).
  HubMessagingRepository? get repository => _repository;

  /// dap_invite (see [PendingInvites.invite]): [nameOrId] is a 16-hex
  /// agent id (immediate chankey DM) or a display name — a currently
  /// online name is invited immediately, an unknown or offline name arms
  /// a pending invite (auto-delivered when they come online) and the
  /// result carries the paste-ready connect line for the invited user.
  /// The mirrored [PluginContext] subset carries no tool registry, so
  /// hosts register their `invite` tool around this one-liner; the
  /// upstream PR would wire `registerTool` directly.
  Future<InviteResult> inviteTo(String nameOrId, {String? channel}) async {
    final invites = _invites;
    if (invites == null) {
      throw StateError('plugin not started — call start() first');
    }
    return invites.invite(nameOrId, channel: channel);
  }

  /// dap_connect — a manual invitation to any DAP hub, at runtime (the
  /// upstream-PR tool wraps this one method): [host] is a bare host,
  /// host:port, or ws(s):// URL; optional [name] is the display name
  /// AND identity (name-derived key file `~/.dap/keys/fah/<name>.key`,
  /// auto-created 0600 — same name = same agent everywhere, new name =
  /// new agentId); optional [channel] is the default room, joined
  /// after connect and on every later launch. Persists url/name/
  /// channels to `~/.dap/config.json` and retargets the live client.
  ///
  /// NOTE: if the room already exists on the target hub under another
  /// member's key, ask a member for a dap_invite — a blind join lets
  /// you post, but the members cannot read you.
  Future<DapConnection> connectTo(String host,
      {String? name, String? channel}) async {
    final repository = _repository;
    if (repository == null) {
      throw StateError('plugin not started — call start() first');
    }
    final result = await repository.connectTo(
      host,
      name: name,
      channel: channel,
      home: home,
    );
    await persistDapConfig(
      url: result.url,
      name: name,
      channels: channel != null ? [channel] : null,
      file: defaultDapConfigFile(home),
    );
    _io?.writeln('[hub] connected to ${result.url} as ${result.agentId}');
    return result;
  }

  /// Connection snapshot for the `dap_status` tool (see
  /// [HubClient.status]). The mirrored [PluginContext] subset carries no
  /// tool registry, so hosts register their `status` tool around this
  /// one-liner; the upstream PR would wire `registerTool` directly.
  Future<HubStatus> status() async {
    final repository = _repository;
    if (repository == null) {
      throw StateError('plugin not started — call start() first');
    }
    return repository.status();
  }

  /// Hub presence list for the `dap_peers` tool (see [HubClient.peers]):
  /// online-only unless [includeOffline] is true; same registerTool
  /// pattern as [status].
  Future<List<AgentInfo>> peers({bool includeOffline = false}) async {
    final repository = _repository;
    if (repository == null) {
      throw StateError('plugin not started — call start() first');
    }
    return repository.peers(includeOffline: includeOffline);
  }

  /// Our hub agent id once connected.
  String? get agentId => _client?.agentId;

  Future<void> dispose() async {
    await _errorSub?.cancel();
    await _invites?.dispose();
    _invites = null;
    await _repository?.dispose();
    _repository = null;
    _client = null;
  }
}
