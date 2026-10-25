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
import 'dart:convert' show jsonEncode;
import 'dart:io'
    show File, HttpClient, Platform, Process, ProcessStartMode, pid;
import 'dart:math' show Random;

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    show defaultHubStateFile, envHubSecret, readHubStateSecret;

import 'fah_dap_command.dart' show DapHubController, resolveDapLocalHubUrl;
import 'fah_dap_scoped.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';

// The /dap menu lives in lib/ as pure data (issue #129): the untagged
// structural test pins it without importing this dart:io plugin, which
// would drag bin/ into the default coverage run and trip the CRAP
// ratchet. Re-exported so the integration PTY tests see the constant
// through this library.
export 'package:flutter_agent_harness/src/cli/dap_menu_options.dart'
    show dapMenuOptions;
import 'package:flutter_agent_harness/src/cli/dap_menu_options.dart';

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
    String? localHubUrl,
    Future<bool> Function(int port)? hubHealthProbe,
    Future<void> Function(int port)? hubSpawner,
    this.hubStopper,
  }) : _hub = hubPlugin,
       // ignore: prefer_initializing_formals
       _environment = environment ?? Platform.environment,
       // ignore: prefer_initializing_formals
       _home = home,
       // The one-step local surface (start/stop/state rows, issue #304):
       // `DAP_LOCAL_HUB_URL` wins over the zero-config default so hosts
       // and tests can pin it; the CONNECT config stays independent.
       _localHubUrl =
           localHubUrl ??
           resolveDapLocalHubUrl(environment ?? Platform.environment),
       _hubHealthProbe = hubHealthProbe ?? _defaultHubHealthProbe,
       _hubSpawner = hubSpawner ?? _defaultHubSpawner;

  /// Whether the messaging-fabric composite consumes hub mail instead of
  /// this host's external inbox.
  final bool fabricDeliversMail;

  final hub.HubPlugin _hub;
  final Map<String, String> _environment;

  /// Home directory override for the `~/.dap/config.json` resolution.
  final String? _home;

  /// The zero-config hub `/dap start` brings up and dials
  /// (`ws://127.0.0.1:8787/ws` normally; tests point it at an ephemeral
  /// [LocalHub]).
  final String _localHubUrl;

  /// `/dap start` seams: is a hub answering on [port] (`/healthz`), and
  /// launch one. Injected by tests; the defaults use dart:io.
  final Future<bool> Function(int port) _hubHealthProbe;
  final Future<void> Function(int port) _hubSpawner;

  /// `/dap stop` seam: the graceful-stop exit code for the local hub at
  /// [url] (the [DapHubController] default: peer warning, SIGTERM the
  /// owning pid from the `~/.dap/hub.pid` state file, no zombie). Null
  /// builds the production controller; tests inject a fake.
  final Future<int> Function(String url)? hubStopper;

  /// Scoped channel membership (issue #1825), built at register time.
  DapScopedMemberships? _scoped;

  /// Set whenever the runtime client must (re)join the effective union:
  /// at boot, after a session replay becomes visible, after join/leave.
  bool _runtimeSyncPending = true;

  /// Rate limit for the post-replay remote dial (10 s between attempts).
  DateTime? _runtimeConnectNotBefore;

  /// The connected hub url for the channel-leave delivery filter.
  String? _connectedHubUrl;

  /// Agent-facing channel notices (issue #1825): after a join and on the
  /// first drain with memberships, the AGENT itself must learn which
  /// channels it is on and how to write — otherwise it has no idea DAP
  /// channels exist (live user report).
  /// The scoped connection: owned by THIS host when a join/boot carries
  /// an enrolled name-bound credential. The vendored plugin cannot
  /// retrofit a new secret onto its (possibly dead) client — its failed
  /// start leaves `_repository` non-null but unconnected, which is
  /// exactly why joins reported NOT live after a 401 at boot.
  hub.HubMessagingRepository? _scopedRepository;
  PluginIO? _pluginIo;

  /// Test seam: replaces the live scoped connect so unit tests never
  /// touch the network.
  Future<void> Function(String hubUrl)? scopedConnectOverride;

  hub.HubMessagingRepository? get _activeRepository =>
      _scopedRepository ?? _hub.repository;

  /// Lets [HubFabricRepository] route through the ACTIVE repository
  /// (scoped client included) while keeping its lazy vendored fallback.
  static final Map<hub.HubPlugin, HubPluginHost> _byPlugin = {};

  /// The active repository for [plugin]'s host, or null when the host
  /// has none (the caller falls back to `plugin.repository`).
  static hub.HubMessagingRepository? activeRepositoryFor(
    hub.HubPlugin plugin,
  ) => _byPlugin[plugin]?._activeRepository;

  /// The live display name used to recognize @-mentions in channel mail.
  /// Reads the ACTIVE client so a scoped join or reconnect never leaves the
  /// CLI with a stale identity; the IO dependency stays behind this seam.
  static String? dapDisplayNameFor(hub.HubPlugin plugin) {
    final client =
        _byPlugin[plugin]?._activeRepository?.client ??
        plugin.repository?.client;
    return client?.config.name;
  }

  /// Whether [channel] is a keyless (PUBLIC showcase) membership on the
  /// host's active hub — public channels use the raw-payload contract,
  /// not chankey E2E.
  ExecutionEnv? _pluginEnv;

  /// The channel ids joined on the host's active hub — the fabric must
  /// drain `#channel` inboxes too: `drain(agentId)` alone only ever
  /// returns DMs, which is why channel traffic never reached the agent.
  static Future<List<String>> joinedChannelsFor(hub.HubPlugin plugin) async {
    final host = _byPlugin[plugin];
    final scoped = host?._scoped;
    if (host == null || scoped == null) return const [];
    try {
      // Idle probes use this list too: finish a deferred resume join here,
      // before checking (or draining) the channel inboxes.
      await host._syncRuntimeMemberships();
      final hubUrl = host._connectedHubUrl;
      return [
        for (final m in await scoped.runtimeEffective())
          if (hubUrl == null || m.hubUrl == hubUrl) m.channelId,
      ];
    } on Object {
      return const [];
    }
  }

  static Future<bool> publicChannelFor(
    hub.HubPlugin plugin,
    String channel,
  ) async {
    final host = _byPlugin[plugin];
    if (host == null) return false;
    return host._isPublicChannel(channel);
  }

  Future<bool> _isPublicChannel(String channel) async {
    final scoped = _scoped;
    if (scoped == null) return false;
    try {
      final effective = await scoped.runtimeEffective();
      return effective.any(
        (membership) => _isPublicMembership(membership, channel),
      );
    } on Object {
      return false;
    }
  }

  bool _isPublicMembership(DapChannelMembership membership, String channel) {
    if (!_membershipMatchesChannel(membership, channel)) return false;
    return membership.pub == null || membership.priv == null;
  }

  bool _membershipMatchesChannel(
    DapChannelMembership membership,
    String channel,
  ) {
    if (membership.channelId != channel) return false;
    final hubUrl = _connectedHubUrl;
    return hubUrl == null || membership.hubUrl == hubUrl;
  }

  final List<AgentMessage> _networkNotices = [];
  var _networkNoticeSeq = 0;
  var _bootNoticeSent = false;

  @override
  String get name => _pluginName;

  @override
  void register(PluginContext context) {
    _pluginIo = context.io;
    _pluginEnv = context.env;
    _byPlugin[_hub] = this;
    _hub.register(
      hub.PluginContext(
        io: _HubPluginIO(context.io),
        // The CLI passes this plugin's already-scoped section; the package
        // register reads `config['hub']`.
        config: {_pluginName: context.config},
      ),
    );
    _initScopedMemberships(context);
    context.registerSessionReadyListener(() {
      // Registration happens before the resumed JSONL is loaded. Its
      // session-scoped records become visible now, so the next inbox drain
      // or idle probe must rebuild and join the effective membership set.
      _runtimeSyncPending = true;
      // Do not wait for an inbox probe: with no connected hub the fabric
      // probe short-circuits to "empty" BEFORE the membership sync, so
      // the remote dial would never happen (deadlock found live on
      // resumed ai_kb/ai_conf). Drive the dial + joins right here.
      unawaited(_syncRuntimeMemberships().catchError((Object _) {}));
    });
    unawaited(
      _connect(context).catchError((Object e, StackTrace s) {
        context.io.writeln('[hub] connect failed: $e');
      }),
    );
    context.registerSlashCommand(
      '/network',
      (args) => _networkSlash(context, args),
      description:
          'DAP channels — join by invite (session/project/global scope), '
          'list, leave, copy invite, status',
    );
    context.registerSlashCommand(
      '/dap',
      (args) => _dapSlash(context, args),
      description:
          'DAP hub — end-to-end-encrypted messaging between agents '
          '(start / stop / status / connect / secret)',
    );
    // The inbox stays unconditional EXCEPT when the fabric composite owns
    // delivery (issue #27): registering both would race one hub frame
    // between two consumers.
    if (!fabricDeliversMail) {
      context.registerExternalInbox(
        ExternalInbox(drain: _drainHubMail, hasPending: _hasPendingHubMail),
      );
    }
    // Channel notices + the live-membership sync ride their OWN inbox so
    // they work in both delivery modes (fabric composite or plugin).
    context.registerExternalInbox(ExternalInbox(drain: _drainNetworkNotices));
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
      await _connectWithScopedBoot();
    } on Object catch (error) {
      _printBootConnectError(context, error);
    }
  }

  Future<void> _connectWithScopedBoot() async {
    // Issue #1825: seed the runtime channel-key overlay with the scoped
    // union BEFORE the vendored client loads its channel store, so boot
    // joins cover project/global/env scopes (session records arrive later
    // and sync on the first drain).
    final scoped = _scoped;
    final preferred = await scoped?.preferredBootMembership();
    _applyBootMembership(preferred);
    await scoped?.seedOverlay();
    if (preferred?.hubClientSecret != null) {
      await _tryScopedBootConnect(preferred!.hubUrl);
    } else {
      await _startHub();
    }
    _connectedHubUrl ??= scoped?.defaultHubUrl;
  }

  void _applyBootMembership(DapChannelMembership? preferred) {
    if (preferred == null) return;
    // The invite hub, not the zero-config local default — dial it directly
    // (process env only, ~/.dap/config.json untouched), with the enrolled
    // name-bound credential when one is stored.
    _environment['DAP_HUB_URL'] = preferred.hubUrl;
    _applyScopedIdentity(preferred.hubClientSecret, preferred.agentName);
    _connectedHubUrl = preferred.hubUrl;
  }

  void _applyScopedIdentity(String? secret, String? name) {
    _setEnvironmentValue('DAP_CLIENT_SECRET', secret);
    _setEnvironmentValue('DAP_AGENT_NAME', name);
  }

  void _setEnvironmentValue(String key, String? value) {
    if (value == null || value.isEmpty) return;
    _environment[key] = value;
  }

  Future<void> _tryScopedBootConnect(String hubUrl) async {
    try {
      await _ensureChannelConnection(hubUrl);
    } on Object catch (error) {
      _pluginIo?.writeln('[hub] scoped boot connect failed: $error');
    }
  }

  void _printBootConnectError(PluginContext context, Object error) {
    if (_hub.isDefaultUrl) {
      context.io.writeln('[hub] not configured — set DAP_HUB_URL to enable');
      return;
    }
    context.io.writeln('[hub] connect failed: $error');
  }

  /// Builds the scoped membership service (issue #1825) and points the
  /// vendored client at the RUNTIME overlay channel-key file, so the
  /// client's own key writes never leak scoped keys into the legacy
  /// global `~/.dap/channels.json`.
  void _initScopedMemberships(PluginContext context) {
    final home = _home ?? hub.defaultHome(_environment);
    final overlay = '$home/.dap/runtime/channels-$pid.json';
    _scoped = DapScopedMemberships(
      globalConfigFile: hub.defaultDapConfigFile(_home, _environment),
      globalChannelsFile:
          _environment[hub.envChannelsFile] ?? '$home/.dap/channels.json',
      overlayChannelsFile: overlay,
      projectFile: '${context.env.cwd}/.fah/dap.json',
      environment: _environment,
      appendSessionRecord: context.appendSessionRecord,
      readSessionRecords: context.readSessionRecords,
      keychain: const MacOsDapChannelKeychain(),
      passphrasePrompt: context.askLine == null
          ? null
          : (hubUrl, channelId) async {
              final answer = await context.askLine!(
                'Passphrase for #$channelId (empty = cancel; saved to '
                'Keychain by default)',
                secret: true,
              );
              if (answer == null || answer.isEmpty) return null;
              return (passphrase: answer, save: true);
            },
    );
    try {
      _environment[hub.envChannelsFile] = overlay;
    } on UnsupportedError {
      // A read-only embedder still gets the scoped connector (which uses
      // [overlay] directly). Its legacy /dap start path keeps the
      // original friendly read-only error instead of crashing at plugin
      // registration before any command can run.
    }
  }

  /// Joins every effective membership on the LIVE client (AC1: no
  /// restart). Idempotent: re-joins are cheap and reconnect-safe.
  Future<void> _syncRuntimeMemberships() async {
    if (!_runtimeSyncPending) return;
    await _syncPendingRuntimeMemberships();
  }

  Future<void> _syncPendingRuntimeMemberships() async {
    final scoped = _scoped;
    if (scoped == null) return;
    scoped.invalidateCache();
    await _dialRuntimeMembershipHub(scoped);
    final client = _activeRepository?.client;
    // No live client yet (hub down / still connecting): RETRY on the next
    // drain instead of consuming the one-shot sync.
    if (client == null) return;
    _runtimeSyncPending = false;
    await _joinRuntimeMemberships(scoped, client);
  }

  Future<void> _dialRuntimeMembershipHub(DapScopedMemberships scoped) async {
    // Session-scoped memberships are invisible to boot (the JSONL is
    // replayed later): dial the membership's hub BEFORE joining channels
    // on the active client. Throttled: a rejected dial must not be retried
    // on every inbox probe.
    final preferred = await scoped.preferredBootMembership();
    if (preferred == null || !_needsRuntimeDial(preferred)) return;
    await _dialPreferredRuntimeMembership(preferred);
  }

  bool _needsRuntimeDial(DapChannelMembership preferred) {
    if (_activeRepository?.client.connected != true) return true;
    final normalized = DapScopedMemberships.normalizeHubUrl(preferred.hubUrl);
    return _connectedHubUrl != normalized;
  }

  Future<void> _dialPreferredRuntimeMembership(
    DapChannelMembership preferred,
  ) async {
    // Throttling suppresses ONLY the re-dial: channel joins (and the key
    // accept they carry) must still run on the current client — otherwise
    // a fresh invite sits unaccepted for seconds and the first outbound
    // frame auto-keygens a pair nobody can read.
    final throttled = _runtimeDialThrottled();
    if (!throttled) _markChannelDialed();
    _applyScopedIdentity(preferred.hubClientSecret, preferred.agentName);
    if (!throttled) await _ensureChannelConnection(preferred.hubUrl);
  }

  bool _runtimeDialThrottled() {
    final notBefore = _runtimeConnectNotBefore;
    return notBefore != null && DateTime.now().isBefore(notBefore);
  }

  Future<void> _joinRuntimeMemberships(
    DapScopedMemberships scoped,
    hub.HubClient client,
  ) async {
    for (final membership in await scoped.runtimeEffective()) {
      await _tryJoinRuntimeMembership(client, membership);
    }
  }

  Future<void> _tryJoinRuntimeMembership(
    hub.HubClient client,
    DapChannelMembership membership,
  ) async {
    try {
      await _joinRuntimeMembership(client, membership);
    } on Object {
      // A single bad channel must not block the others.
    }
  }

  Future<void> _joinRuntimeMembership(
    hub.HubClient client,
    DapChannelMembership membership,
  ) async {
    final priv = membership.priv;
    if (membership.pub == null || priv == null) {
      // PUBLIC showcase channel: join keyless and NEVER mint a chankey —
      // the client decodes the raw base64 public payload contract instead
      // of attempting (and failing) chankey E2E.
      client.join(membership.channelId, '');
      return;
    }
    await client.channelStore?.accept(
      membership.channelId,
      hub.ChannelKeys(pub: membership.pub!, priv: priv),
    );
    client.join(membership.channelId, membership.pub!);
  }

  /// Dials [hubUrl] on the live client without persisting it over the
  /// configured default hub (E3). Starts the client when it is down.
  Future<void> _ensureChannelConnection(String hubUrl) async {
    final normalized = DapScopedMemberships.normalizeHubUrl(hubUrl);
    final hasScopedCredential =
        (_environment['DAP_CLIENT_SECRET'] ?? '').isNotEmpty;
    if (hasScopedCredential) {
      if (_connectedHubUrl == normalized &&
          _scopedRepository?.client.connected == true) {
        return;
      }
      await _connectScoped(normalized);
      _markChannelDialed();
      return;
    }
    final repository = _activeRepository;
    if (repository == null) {
      _environment['DAP_HUB_URL'] = normalized;
      await _startHub();
    } else if (_connectedHubUrl != normalized) {
      await repository.connectTo(normalized);
    } else if (!repository.client.connected) {
      // The vendored start leaves a DEAD repository after a failed
      // dial (401 at boot): retry instead of doing nothing.
      await repository.start();
    }
    _connectedHubUrl = normalized;
    _markChannelDialed();
  }

  /// A successful live dial (wizard join, boot, runtime sync) also arms
  /// the runtime-sync throttle: the very next sync must not immediately
  /// dial the SAME hub a second time just because the client handshake
  /// has not flipped `connected` yet (regression: network_wizard_test
  /// saw two scoped connects for one join).
  void _markChannelDialed() {
    _runtimeConnectNotBefore = DateTime.now().add(const Duration(seconds: 10));
  }

  /// Dials [normalized] with the process-local enrolled credential on a
  /// client THIS host owns (the vendored plugin's client keeps the
  /// secret it was constructed with — it can never learn a new one).
  Future<void> _connectScoped(String normalized) async {
    final override = scopedConnectOverride;
    if (override != null) {
      await override(normalized);
      _connectedHubUrl = normalized;
      return;
    }
    // DAP_AGENT_NAME enters settings ONLY through HubConfig.fromMap —
    // resolveDapSettings alone reads the name from ~/.dap/config.json,
    // which is the LOCAL agent's name and fails name-bound enrollment.
    final liveConfig = hub.HubConfig.fromMap(
      const <String, dynamic>{},
      _environment,
    );
    final settings = hub.resolveDapSettings(
      config: liveConfig,
      environment: _environment,
      home: _home,
    );
    final store = await hub.ChannelStore.fromFile(
      _scoped?.overlayChannelsFile ?? settings.channelsFile,
    );
    final scopedSecret = _environment['DAP_CLIENT_SECRET'] ?? '';
    final client = hub.HubClient(
      config: hub.HubConfig(url: normalized, name: settings.name),
      identity: await hub.HubIdentity.load(
        scopedIdentityKeyPath(
          defaultKeyPath: settings.keyPath,
          explicitKeyPath:
              liveConfig.keyPath != null ||
              (_environment[hub.HubConfig.envKeyPath] ?? '').isNotEmpty,
          projectCwd: _pluginEnv?.cwd ?? _home ?? '',
        ),
      ),
      channelStore: store,
      clientSecret: (scopedSecret.isEmpty ? null : scopedSecret),
      enroll: false,
      secretSource: hub.DapSecretSource.env,
    );
    client.errors.listen(
      (e) => _pluginIo?.writeln(
        '[hub] hub rejected a frame — ${e.code}: ${e.msg}',
      ),
    );
    final repository = hub.HubMessagingRepository(client);
    // Throws on rejection: the previous (working) state is kept.
    await repository.start();
    _scopedRepository = repository;
    _connectedHubUrl = normalized;
    _pluginIo?.writeln('[hub] connected as ${client.agentId}');
  }

  void _queueNetworkNotice(String text) {
    _networkNotices.add(
      AgentMessage(
        id: 'network-${_networkNoticeSeq++}',
        fromId: 'network',
        toId: '',
        text: text,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// One concise identity clause for the existing membership notice.
  String get _dapIdentityNotice {
    final client = _activeRepository?.client;
    if (client == null) return '';
    final name = client.config.name?.trim();
    if (name == null || name.isEmpty) return '';
    final agentId = client.agentId ?? client.identity.agentId;
    return 'Your DAP identity is $name (agentId $agentId). ';
  }

  /// The always-on inbox: live membership sync, the boot channel notice
  /// (so the agent knows its channels from the first turn), and queued
  /// join notices — in BOTH delivery modes.
  Future<List<AgentMessage>> _drainNetworkNotices() async {
    try {
      await _syncRuntimeMemberships();
      if (!_bootNoticeSent) {
        _bootNoticeSent = true;
        final scoped = _scoped;
        if (scoped != null) {
          final effective = await scoped.runtimeEffective();
          if (effective.isNotEmpty) {
            _queueNetworkNotice(
              '$_dapIdentityNotice'
              'You are a member of DAP channel(s): '
              '${effective.map((m) => '#${m.channelId} [${m.scope.name}]').join(', ')}. '
              'Any channel member can steer you; inbound frames arrive '
              'as provenance-prefixed steering (#channel · sender). '
              'To write to a channel use agent_message to: "#<channel>". '
              'The human manages membership via /network.',
            );
          }
        }
      }
      final out = List<AgentMessage>.of(_networkNotices);
      _networkNotices.clear();
      return out;
    } on Object {
      return const [];
    }
  }

  /// `/network` — the scoped join wizard + channel management (AC6):
  /// Join (default) → paste → scope (session default) → live. With
  /// `join <invite>` args the paste step is prefilled (composer AC7).
  Future<void> _networkSlash(PluginContext context, List<String> args) async {
    final scoped = _scoped;
    if (scoped == null) return;
    final positional = args.where((arg) => arg.isNotEmpty).toList();
    if (positional.isNotEmpty) {
      await _networkArgs(context, scoped, positional);
      return;
    }
    await _networkDefault(context, scoped);
  }

  Future<void> _networkArgs(
    PluginContext context,
    DapScopedMemberships scoped,
    List<String> positional,
  ) async {
    if (positional.first != 'join') {
      context.io.writeln('usage: /network [join <invite|channel-id>]');
      return;
    }
    final invite = positional.sublist(1).join(' ').trim();
    if (invite.isEmpty) {
      context.io.writeln('usage: /network join <invite|channel-id>');
      return;
    }
    await _networkJoin(context, scoped, invite);
  }

  Future<void> _networkDefault(
    PluginContext context,
    DapScopedMemberships scoped,
  ) async {
    final pick = context.pickOption;
    if (pick == null) {
      await _printNetworkChannelsStatus(context, scoped);
      return;
    }
    final action = await pick('Network', [
      ('join', 'Join channel', 'Paste an invite, pick a scope, join live'),
      ('channels', 'Channels', 'Joined channels: badges, leave, copy invite'),
      ('status', 'Status', 'Hub url, connection state, reconnect'),
    ], initialKey: 'join');
    final actions = <String, Future<void> Function()>{
      'join': () => _networkMenuJoin(context, scoped),
      'channels': () => _networkChannels(context, scoped),
      'status': () => _printStatus(context),
    };
    await actions[action]?.call();
  }

  Future<void> _printNetworkChannelsStatus(
    PluginContext context,
    DapScopedMemberships scoped,
  ) async {
    // Headless/line hosts: one-line status, no menus.
    final effective = await scoped.union().then((union) => union.effective());
    context.io.writeln(
      'network: ${effective.length} channel(s): '
      '${effective.map((m) => '#${m.channelId}').join(', ')}',
    );
  }

  Future<void> _networkMenuJoin(
    PluginContext context,
    DapScopedMemberships scoped,
  ) async {
    final invite = await context.askLine?.call(
      'Paste the channel invite (url, url#keys, channel id, or '
      'fa dap import …)',
    );
    if (invite == null || invite.trim().isEmpty) return;
    await _networkJoin(context, scoped, invite.trim());
  }

  Future<void> _networkJoin(
    PluginContext context,
    DapScopedMemberships scoped,
    String rawInvite,
  ) async {
    final io = context.io;
    final DapJoinBundle bundle;
    try {
      bundle = parseDapJoinBundle(
        rawInvite,
        defaultHubUrl: scoped.defaultHubUrl,
      );
    } on FormatException catch (e) {
      // E4: inline validation error, nothing stored, no agent message.
      io.writeln('network: invalid invite — ${e.message}');
      return;
    }
    final invite = bundle.invite;
    final scope = await _networkJoinScope(context);
    if (scope == null) return;
    final outcome = await scoped.join(
      invite,
      scope,
      agentName: bundle.agentName,
      hubClientSecret: bundle.clientSecret,
    );
    await _connectJoinedChannel(context, bundle);
    _notifyNetworkJoin(context, bundle, scope, outcome);
  }

  Future<DapChannelScope?> _networkJoinScope(PluginContext context) async {
    final pick = context.pickOption;
    if (pick == null) return DapChannelScope.session;
    final chosen = await pick('Scope — members can steer this agent', [
      ('session', 'Session', 'Only this agent session (resume re-joins)'),
      ('project', 'Project', 'Every fa agent started in this folder'),
      ('global', 'Global', 'Every fa agent on this machine'),
    ], initialKey: 'session');
    if (chosen == null) return null;
    return DapChannelScope.values.firstWhere((s) => s.name == chosen);
  }

  Future<void> _connectJoinedChannel(
    PluginContext context,
    DapJoinBundle bundle,
  ) async {
    // Process-local enrolled credential: the vendored client resolves
    // DAP_CLIENT_SECRET / DAP_AGENT_NAME at start, so the (re)start
    // below authenticates with the name-bound secret. Never printed.
    _applyScopedIdentity(bundle.clientSecret, bundle.agentName);
    // AC1/AC9: dial the INVITE hub live (never persisting it over the
    // configured default); a down hub leaves the membership stored and
    // the reconnect path picks it up.
    try {
      await _ensureChannelConnection(bundle.hubUrl);
    } on Object catch (e) {
      context.io.writeln(
        'network: hub unreachable ($e) — membership stored, auto-join '
        'on reconnect',
      );
    }
    _runtimeSyncPending = true;
    await _syncRuntimeMemberships();
    final live = _activeRepository?.client.connected ?? false;
    if (!live) {
      context.io.writeln(
        'network: membership stored but NOT live — the hub rejected or '
        'is unreachable. On hubs with enrolled agents paste the WHOLE '
        'DAP block (Add an agent → DAP: invite + DAP_CLIENT_SECRET + '
        'DAP_AGENT_NAME), then restart fa.',
      );
    }
  }

  void _notifyNetworkJoin(
    PluginContext context,
    DapJoinBundle bundle,
    DapChannelScope scope,
    DapScopedOutcome outcome,
  ) {
    final invite = bundle.invite;
    _queueNetworkNotice(
      'You joined DAP channel #${invite.channel} [${scope.name}] @ '
      '${DapScopedMemberships.normalizeHubUrl(invite.hubUrl)}. '
      'Any member of this channel can steer you; inbound frames arrive '
      'as provenance-prefixed steering (#${invite.channel} · sender). '
      'To write to the channel use agent_message to: '
      '"#${invite.channel}". The human manages membership via /network.',
    );
    for (final warning in outcome.warnings) {
      context.io.writeln(warning);
    }
    context.io.writeln(
      'network: joined #${invite.channel} [${scope.name}] @ '
      '${invite.hubUrl} — members can steer this agent',
    );
  }

  Future<void> _networkChannels(
    PluginContext context,
    DapScopedMemberships scoped,
  ) async {
    final union = await scoped.union();
    final effective = union.effective();
    if (effective.isEmpty) {
      context.io.writeln(
        'network: no channels joined yet — Join channel first',
      );
      return;
    }
    final pick = context.pickOption;
    if (pick == null) {
      _printNetworkChannelList(context, union, effective);
      return;
    }
    await _pickNetworkChannel(context, scoped, union, effective, pick);
  }

  void _printNetworkChannelList(
    PluginContext context,
    DapMembershipUnion union,
    List<DapChannelMembership> effective,
  ) {
    for (final membership in effective) {
      context.io.writeln(_networkChannelLine(union, membership));
    }
  }

  String _networkChannelLine(
    DapMembershipUnion union,
    DapChannelMembership membership,
  ) {
    final scopes = union
        .scopesOf(membership.hubUrl, membership.channelId)
        .map((scope) => scope.name)
        .join('+');
    return '#${membership.channelId} [$scopes] @ ${membership.hubUrl}';
  }

  Future<void> _pickNetworkChannel(
    PluginContext context,
    DapScopedMemberships scoped,
    DapMembershipUnion union,
    List<DapChannelMembership> effective,
    PluginPickOption pick,
  ) async {
    final chosen = await pick('Channels', [
      for (final membership in effective)
        (
          membership.key,
          _networkChannelLine(union, membership).split(' @ ').first,
          membership.hubUrl,
        ),
    ]);
    if (chosen == null) return;
    final membership = effective.firstWhere((m) => m.key == chosen);
    await _networkChannelAction(context, scoped, union, membership, pick);
  }

  Future<void> _networkChannelAction(
    PluginContext context,
    DapScopedMemberships scoped,
    DapMembershipUnion union,
    DapChannelMembership membership,
    PluginPickOption pick,
  ) async {
    final action = await pick('#${membership.channelId}', [
      ('copy', 'Copy invite', 'Export the app-compatible invite string'),
      ('leave', 'Leave', 'Stop delivery at one scope'),
    ]);
    if (action == 'copy') {
      context.io.writeln(await scoped.copyInvite(membership));
      return;
    }
    if (action != 'leave') return;
    await _networkLeaveChannel(context, scoped, union, membership, pick);
  }

  Future<void> _networkLeaveChannel(
    PluginContext context,
    DapScopedMemberships scoped,
    DapMembershipUnion union,
    DapChannelMembership membership,
    PluginPickOption pick,
  ) async {
    final scopes = union.scopesOf(membership.hubUrl, membership.channelId);
    final scopeName = scopes.length == 1
        ? scopes.single.name
        : await pick('Leave which scope?', [
            for (final scope in scopes) (scope.name, scope.name, ''),
          ]);
    if (scopeName == null) return;
    await scoped.leave(
      membership.hubUrl,
      membership.channelId,
      DapChannelScope.values.firstWhere((scope) => scope.name == scopeName),
    );
    _runtimeSyncPending = true;
    context.io.writeln(
      'network: left #${membership.channelId} [$scopeName] — '
      'other scopes keep the channel',
    );
  }

  /// `/dap` — no args: the guided menu when the host is interactive
  /// (start / status / connect / master secret / about), a one-line
  /// status otherwise; `/dap start`: the one-step local bring-up;
  /// `/dap <host> [name] [channel]`: move the live connection to
  /// another hub.
  Future<void> _dapSlash(PluginContext context, List<String> args) async {
    final positional = args.where((arg) => arg.isNotEmpty).toList();
    if (positional.isEmpty) {
      await _dapDefault(context);
      return;
    }
    await _dapArgs(context, positional);
  }

  Future<void> _dapDefault(PluginContext context) async {
    final pick = context.pickOption;
    if (pick == null) {
      await _printStatus(context);
      return;
    }
    await _dapMenu(context, pick);
  }

  Future<void> _dapArgs(PluginContext context, List<String> positional) async {
    try {
      if (positional.first == 'start') {
        await _dapStart(context);
        return;
      }
      await _dapConnectArgs(context, positional);
    } on Object catch (error) {
      context.io.writeln('[hub] $error');
    }
  }

  Future<void> _dapConnectArgs(
    PluginContext context,
    List<String> positional,
  ) async {
    // Persist first (see _dapStart): a stale dead config makes the
    // boot-time start() churn against the dead URL, and connectTo needs
    // the repository up.
    try {
      await hub.persistDapConfig(
        url: positional[0],
        file: hub.defaultDapConfigFile(_home, _environment),
      );
      await _startHub().timeout(const Duration(seconds: 8));
    } on Object {
      // The connect below reports the real error.
    }
    final connection = await _hub.connectTo(
      positional[0],
      name: _positionalArg(positional, 1),
      channel: _positionalArg(positional, 2),
    );
    _printConnection(context, connection);
  }

  String? _positionalArg(List<String> args, int index) {
    return args.length > index ? args[index] : null;
  }

  void _printConnection(PluginContext context, hub.DapConnection connection) {
    context.io.writeln(
      'connected to ${connection.url} as ${connection.agentId} — '
      'channels: ${connection.channels.join(', ')}',
    );
  }

  /// `/dap start` — the one-step local bring-up: generates a session
  /// master secret when none is set, launches a local hub on the
  /// zero-config port when none answers `/healthz`, then connects
  /// (persisting the URL, so the next boot is online by itself).
  Future<void> _dapStart(PluginContext context) async {
    if (!_ensureDapSessionSecret(context)) return;
    final stateFile = defaultHubStateFile(
      home: _home,
      environment: _environment,
    );
    final promptedPassword = await _promptForHubPassword(context, stateFile);
    if (!await _ensureLocalHub(context)) return;
    await _applyHubPassword(context, stateFile, promptedPassword);
    await _persistLocalHubUrl();
    await _startLocalConnection(context);
    await _connectLocalHub(context);
  }

  bool _ensureDapSessionSecret(PluginContext context) {
    if (_dapEnabled) return true;
    try {
      _environment[hub.envMasterSecret] = _generateSessionSecret();
    } on Object {
      context.io.writeln(
        '[hub] this host\'s environment is read-only — export '
        'DAP_MASTER_SECRET before launching instead',
      );
      return false;
    }
    context.io.writeln(
      'master secret generated for this session — '
      'export DAP_MASTER_SECRET to make it permanent',
    );
    return true;
  }

  Future<String?> _promptForHubPassword(
    PluginContext context,
    File stateFile,
  ) async {
    // The one-button bring-up asks once, interactive hosts only. The answer
    // is persisted for the detached hub; empty keeps the hub open and asks
    // again next time.
    if (!await _shouldPromptForHubPassword(context, stateFile)) return null;
    final entered = await context.askLine!(
      'Set a password for the local hub (empty = keep it open):',
      secret: true,
    );
    final password = entered?.trim() ?? '';
    if (password.isEmpty) return null;
    await _persistHubPassword(context, stateFile, password);
    return password;
  }

  Future<bool> _shouldPromptForHubPassword(
    PluginContext context,
    File stateFile,
  ) async {
    if (context.askLine == null) return false;
    final configured =
        (_environment[envHubSecret] ?? '').isNotEmpty ||
        await stateFile.exists();
    return !configured;
  }

  Future<void> _persistHubPassword(
    PluginContext context,
    File stateFile,
    String password,
  ) async {
    try {
      if (!await stateFile.parent.exists()) {
        await stateFile.parent.create(recursive: true);
      }
      await stateFile.writeAsString(
        jsonEncode({'masterSecret': password, 'clients': <String, String>{}}),
      );
      await Process.run('chmod', ['600', stateFile.path]);
      context.io.writeln('hub password saved to ${stateFile.path}');
    } on Object catch (error) {
      context.io.writeln('[hub] could not persist the password: $error');
    }
  }

  Future<bool> _ensureLocalHub(PluginContext context) async {
    final port = Uri.parse(_localHubUrl).port;
    if (await _hubHealthProbe(port)) return true;
    context.io.writeln('starting a local hub on port $port…');
    if (!await _spawnLocalHub(context, port)) return false;
    return _waitForLocalHub(context, port);
  }

  Future<bool> _spawnLocalHub(PluginContext context, int port) async {
    try {
      await _hubSpawner(port);
      return true;
    } on Object catch (error) {
      context.io.writeln('[hub] could not start a local hub: $error');
      return false;
    }
  }

  Future<bool> _waitForLocalHub(PluginContext context, int port) async {
    if (await _pollLocalHub(port)) return true;
    context.io.writeln('[hub] the local hub did not come up on port $port');
    return false;
  }

  Future<bool> _pollLocalHub(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (await _hubHealthProbe(port)) return true;
    }
    return false;
  }

  Future<void> _applyHubPassword(
    PluginContext context,
    File stateFile,
    String? promptedPassword,
  ) async {
    // The client must hold the HUB's password, not the generated session
    // secret. Prompted now wins over a previously saved state password.
    final hubPassword = promptedPassword ?? _readHubPassword(stateFile);
    if (hubPassword == null || hubPassword.isEmpty) return;
    _environment[hub.envMasterSecret] = hubPassword;
    await _persistHubPasswordConfig(context, hubPassword);
  }

  String? _readHubPassword(File stateFile) {
    try {
      return readHubStateSecret(stateFile);
    } on Object {
      return null;
    }
  }

  Future<void> _persistHubPasswordConfig(
    PluginContext context,
    String hubPassword,
  ) async {
    try {
      await hub.persistDapConfig(
        url: _localHubUrl,
        clientSecret: hubPassword,
        file: hub.defaultDapConfigFile(_home, _environment),
      );
      context.io.writeln(
        'this session joined the protected hub — the password was '
        'applied to the connection',
      );
    } on Object {
      // Best-effort — the env master above already authorizes enroll.
    }
  }

  Future<void> _persistLocalHubUrl() async {
    // Point resolution at the live hub BEFORE start(), so a stale dead
    // config cannot make start() churn against the old URL. connectTo
    // persists the same URL again; this write just orders it first.
    try {
      await hub.persistDapConfig(
        url: _localHubUrl,
        file: hub.defaultDapConfigFile(_home, _environment),
      );
    } on Object {
      // Best-effort — connectTo below persists too.
    }
  }

  Future<void> _startLocalConnection(PluginContext context) async {
    // SHORT wait on purpose: connectTo below un-wedges an in-flight boot
    // start against a dead stale hub; waiting longer only stalls /dap start.
    try {
      await _startHub().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // The retarget in connectTo below un-wedges the boot start.
    } on Object catch (error) {
      context.io.writeln('[hub] start: $error');
    }
  }

  Future<void> _connectLocalHub(PluginContext context) async {
    try {
      final connection = await _hub.connectTo(_localHubUrl);
      context.io.writeln(
        'DAP is up — $_localHubUrl, you are ${connection.agentId}'
        '${connection.name != null ? ' (${connection.name})' : ''} '
        '— /agents to see peers',
      );
    } on Object catch (error) {
      context.io.writeln('[hub] $error');
    }
  }

  /// A random session-only master secret (16 bytes hex).
  static String _generateSessionSecret() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Default `/dap start` probe: GET `http://127.0.0.1:<port>/healthz`.
  static Future<bool> _defaultHubHealthProbe(int port) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      final response = await (await client.get(
        '127.0.0.1',
        port,
        '/healthz',
      )).close();
      await response.drain<void>();
      client.close();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// Default `/dap start` launcher: a detached `fa hub serve --port N`
  /// that outlives this CLI (other agents keep their hub when we exit).
  /// From a source checkout (`dart bin/fah.dart`) the script path is
  /// respawned through the VM; the installed bundle re-executes itself.
  static Future<void> _defaultHubSpawner(int port) async {
    final script = Platform.script;
    final String executable;
    final List<String> arguments;
    if (script.scheme == 'file' && script.path.endsWith('.dart')) {
      executable = Platform.executable;
      arguments = [script.toFilePath(), 'hub', 'serve', '--port', '$port'];
    } else {
      executable = Platform.resolvedExecutable;
      arguments = ['hub', 'serve', '--port', '$port'];
    }
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  /// Whether the plugin's kill switch is set (mirrors the hub plugin's
  /// own check, without throwing).
  bool get _dapEnabled => (_environment[hub.envMasterSecret] ?? '').isNotEmpty;

  /// The in-flight `_hub.start()`, shared between the boot-time background
  /// connect and the slash commands. The package's start() is NOT
  /// re-entrant: two concurrent calls race the identity-key generation
  /// (both write `key.tmp`, one rename wins, the loser's start() throws
  /// and the repository never exists — "plugin not started" forever).
  /// Cleared on completion so a failed start (dead hub) can be retried.
  Future<void>? _starting;

  /// Serialized `_hub.start()`: concurrent callers share one attempt.
  Future<void> _startHub() {
    final inFlight = _starting;
    if (inFlight != null) return inFlight;
    final future = _hub.start();
    _starting = future;
    // The tracked reference consumes the outcome: a caller that timed out
    // (`start().timeout(8s)`) drops its own subscription, and a later
    // failure — e.g. `StateError: retargeted` when connectTo moves the
    // in-flight boot connect — must not surface as an unhandled async
    // error in the host zone.
    final tracked = future.whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
    unawaited(tracked.then((_) {}, onError: (_) {}));
    return future;
  }

  /// The one-line status, friendly when DAP is disabled.
  Future<void> _printStatus(PluginContext context) async {
    if (!_dapEnabled) {
      _printDisabledStatus(context);
      return;
    }
    _printHubStatus(context, await _hub.status());
  }

  void _printDisabledStatus(PluginContext context) {
    context.io.writeln(
      'DAP disabled — no master secret. '
      'Run /dap start (it generates one and brings up a local hub), '
      'or export DAP_MASTER_SECRET before launching.',
    );
  }

  void _printHubStatus(PluginContext context, hub.HubStatus status) {
    if (!status.connected) {
      _printDisconnectedStatus(context, status);
      return;
    }
    context.io.writeln(
      'hub connected — '
      'agentId: ${status.agentId ?? '-'}, name: ${status.name ?? '-'}, '
      'url: ${status.url ?? '-'}',
    );
  }

  void _printDisconnectedStatus(PluginContext context, hub.HubStatus status) {
    // A disconnected status still carries the configured url (often a stale
    // loopback port from an old session) — say what to do next.
    context.io.writeln(
      'hub disconnected${status.url != null ? ' — ${status.url}' : ''}\n'
      'Run /dap start — it launches a local hub and connects in one step.',
    );
  }

  /// The guided `/dap` menu: every entry explains itself; inputs are
  /// interactive (masked for the secret). The leading row is
  /// STATE-DEPENDENT (issue #304 AC7): a stopped local hub offers
  /// "Start DAP locally (one step)", a running one swaps it for
  /// "Stop DAP" — same slot, so the arrow-walk for the other rows never
  /// shifts.
  Future<void> _dapMenu(PluginContext context, PluginPickOption pick) async {
    final port = Uri.parse(_localHubUrl).port;
    final hubRunning = await _hubHealthProbe(port);
    final choice = await pick(
      'DAP — Distributed Agents Platform: end-to-end-encrypted '
      'messaging between agents over a local hub'
      '${hubRunning ? ' — local hub RUNNING' : ''}',
      dapMenuOptions(hubRunning: hubRunning),
    );
    final actions = <String, Future<void> Function()>{
      'start': () => _dapStart(context),
      'stop': () => _dapStop(context),
      'status': () => _printStatus(context),
      'connect': () => _menuConnect(context),
      'secret': () => _menuSetSecret(context),
      'about': () async => context.io.writeln(_aboutText),
    };
    await actions[choice]?.call(); // null choice: cancelled, stay quiet
  }

  /// `/dap stop` — the graceful local-hub stop (issue #304 AC2/E4): the
  /// [DapHubController] names the connected peers (e.g. "Browser"),
  /// SIGTERMs the owning pid from the `~/.dap/hub.pid` state file —
  /// works from any CLI instance, exactly once — and this session's
  /// messaging fabric transparently falls back to its file inboxes
  /// (27.1: queued hub mail is forwarded when the hub returns).
  Future<void> _dapStop(PluginContext context) async {
    final ask = context.askLine;
    final stopper =
        hubStopper ??
        () => DapHubController(
          home: _home,
          environment: _environment,
          url: _localHubUrl,
          secretPrompt: ask == null
              ? null
              : (question) => ask(question, secret: true),
          out: context.io.writeln,
        ).stop();
    final code = await stopper(_localHubUrl);
    if (code != 0) {
      context.io.writeln('[hub] stop did not complete (exit $code)');
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
    if (context.askLine == null) return;
    // Beat the boot race: a dead initial hub must not wedge the menu; the
    // connect below reports the real error after this bounded start.
    await _startHubForMenu();
    await _menuConnectPrompted(context);
  }

  Future<void> _startHubForMenu() async {
    try {
      await _startHub().timeout(const Duration(seconds: 8));
    } on Object {
      // The connect below reports the real error.
    }
  }

  Future<void> _menuConnectPrompted(PluginContext context) async {
    final input = await _promptMenuConnection(context);
    if (input == null) return;
    await _prepareMenuConnection(input.host);
    await _connectMenuInput(context, input);
  }

  Future<({String host, String? name, String? channel})?> _promptMenuConnection(
    PluginContext context,
  ) async {
    final ask = context.askLine!;
    // Pre-fill the current hub url: reconnecting is an Enter away, and a
    // stale port is easy to edit in place.
    final currentUrl = (await _hub.status()).url;
    final host = await _promptMenuHost(ask, currentUrl);
    if (host == null) return null;
    // Do not use `(empty = X)` for these prompts: Enter means default, not
    // a literal display name or channel named "default".
    final name = await ask('display name (leave empty for the default): ');
    final channel = await ask('channel (leave empty for the default room): ');
    return (host: host, name: name, channel: channel);
  }

  Future<String?> _promptMenuHost(PluginAskLine ask, String? currentUrl) async {
    final hostInput = await ask(_menuHostQuestion(currentUrl));
    if (hostInput == null) return null; // cancelled
    return _defaultMenuHost(hostInput, currentUrl);
  }

  String _menuHostQuestion(String? currentUrl) {
    return currentUrl != null
        ? 'hub host (empty = $currentUrl): '
        : 'hub host (host:port or ws(s):// URL): ';
  }

  String? _defaultMenuHost(String hostInput, String? currentUrl) {
    final trimmed = hostInput.trim();
    // Empty keeps the configured default in both TUI and line mode.
    return _nonEmptyOrNull(trimmed.isEmpty ? currentUrl : trimmed);
  }

  String? _nonEmptyOrNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> _prepareMenuConnection(String host) async {
    try {
      // Persist first: the second start resolves the host the user chose,
      // rather than a stale dead URL from the earlier boot start.
      await hub.persistDapConfig(
        url: host,
        file: hub.defaultDapConfigFile(_home, _environment),
      );
      await _startHubForMenu();
    } on Object {
      // The connect below reports the real error.
    }
  }

  Future<void> _connectMenuInput(
    PluginContext context,
    ({String host, String? name, String? channel}) input,
  ) async {
    try {
      final connection = await _hub.connectTo(
        input.host,
        name: _nonEmptyOrNull(input.name),
        channel: _nonEmptyOrNull(input.channel),
      );
      _printConnection(context, connection);
    } on Object catch (error) {
      context.io.writeln('[hub] $error');
    }
  }

  /// Set master secret: masked input, session-only enable, then
  /// the zero-config start (default hub) so the agent comes online.
  Future<void> _menuSetSecret(PluginContext context) async {
    final secret = await _promptMasterSecret(context);
    if (secret == null) return;
    if (!_setSessionMasterSecret(context, secret)) return;
    context.io.writeln(
      'master secret set for this session — '
      'export DAP_MASTER_SECRET to make it permanent',
    );
    await _startAfterSettingSecret(context);
  }

  Future<String?> _promptMasterSecret(PluginContext context) async {
    final ask = context.askLine;
    if (ask == null) return null;
    final secret = await ask(
      'DAP master secret (session only): ',
      secret: true,
    );
    return _nonEmptyOrNull(secret);
  }

  bool _setSessionMasterSecret(PluginContext context, String secret) {
    try {
      _environment[hub.envMasterSecret] = secret;
      return true;
    } on Object {
      context.io.writeln(
        '[hub] this host\'s environment is read-only — export '
        'DAP_MASTER_SECRET before launching instead',
      );
      return false;
    }
  }

  Future<void> _startAfterSettingSecret(PluginContext context) async {
    try {
      await _startHub();
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
      // Session-scope replay lands here (the session JSONL is loaded after
      // registration): the first drain joins what boot could not see (AC3).
      await _syncRuntimeMemberships();
      final repository = _activeRepository;
      final selfId = repository?.client.agentId;
      final hubUrl = _connectedHubUrl;
      final inbound = await _inboundHubMail(repository, selfId);
      final accepted = await _filterHubMail(inbound, selfId, hubUrl);
      return _mapHubMail(accepted);
    } on Object {
      return const [];
    }
  }

  Future<List<hub.AgentMessage>> _inboundHubMail(
    hub.HubMessagingRepository? repository,
    String? selfId,
  ) async {
    if (repository == null) return _hub.externalSteeringSource();
    return [
      ...await repository.drain(selfId ?? ''),
      for (final channel in await joinedChannelsFor(_hub))
        ...await repository.drain('#$channel'),
    ];
  }

  Future<List<hub.AgentMessage>> _filterHubMail(
    List<hub.AgentMessage> inbound,
    String? selfId,
    String? hubUrl,
  ) async {
    final accepted = <hub.AgentMessage>[];
    for (final message in inbound) {
      if (await _acceptHubMail(message, selfId, hubUrl)) {
        accepted.add(message);
      }
    }
    return accepted;
  }

  Future<bool> _acceptHubMail(
    hub.AgentMessage message,
    String? selfId,
    String? hubUrl,
  ) async {
    if (_isOwnChannelMessage(message, selfId)) return false;
    return _acceptsRemoteHubMail(message, hubUrl);
  }

  bool _isOwnChannelMessage(hub.AgentMessage message, String? selfId) {
    return message.fromId == selfId && message.toId.startsWith('#');
  }

  Future<bool> _acceptsRemoteHubMail(
    hub.AgentMessage message,
    String? hubUrl,
  ) async {
    // Live LEAVE filter (AC4): leaving every scope stops delivery at once;
    // leaving one scope keeps the others. Non-channel mail always passes.
    final scoped = _scoped;
    if (scoped == null || !message.toId.startsWith('#')) return true;
    return scoped.acceptsChannel(
      hubUrl ?? scoped.defaultHubUrl,
      message.toId.substring(1),
    );
  }

  List<AgentMessage> _mapHubMail(List<hub.AgentMessage> inbound) {
    return [
      for (final message in inbound)
        AgentMessage(
          id: message.id,
          fromId: message.fromId,
          toId: message.toId,
          text: message.text,
          sentAt: message.sentAt,
          hops: message.hops,
        ),
    ];
  }

  /// Non-draining probe: unread mail in our own hub inbox AND every
  /// joined `#channel` inbox. Uses the ACTIVE (scoped) repository — the
  /// vendored one is null/dead in enrolled-credential mode, which used
  /// to silence the idle wake for all hub mail.
  Future<bool> _hasPendingHubMail() async {
    final repository = _activeRepository;
    final agentId = repository?.client.agentId;
    // No agentId yet (pre-welcome): peek the '' mailbox would report the
    // frames parked there forever and churn the wake loop — report empty.
    if (repository == null || agentId == null) return false;
    return _peekPendingHubMail(repository, agentId);
  }

  Future<bool> _peekPendingHubMail(
    hub.HubMessagingRepository repository,
    String agentId,
  ) async {
    try {
      return await _repositoryHasPendingMail(repository, agentId);
    } on Object {
      return false;
    }
  }

  Future<bool> _repositoryHasPendingMail(
    hub.HubMessagingRepository repository,
    String agentId,
  ) async {
    if ((await repository.peek(agentId)).isNotEmpty) return true;
    return _anyChannelHasPendingMail(repository);
  }

  Future<bool> _anyChannelHasPendingMail(
    hub.HubMessagingRepository repository,
  ) async {
    for (final channel in await joinedChannelsFor(_hub)) {
      if ((await repository.peek('#$channel')).isNotEmpty) return true;
    }
    return false;
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
      execute: _executeDapStatus,
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
      execute: _executeDapPeers,
    ),
    AgentTool(
      name: 'dap_dm',
      label: 'dap_dm',
      tier: ApprovalTier.exec,
      description:
          'Send an end-to-end encrypted direct message to a hub peer. '
          '`to` is the 16-hex agent id or a display name (run dap_peers '
          'first). Prefer agent_message for peers listed in '
          'agent_directory (issue #304: hub peers are first-class inbox '
          'agents) — use dap_dm only when the fabric is off or the peer '
          'is absent from the directory.',
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
      execute: _executeDapDm,
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
      execute: _executeDapInvite,
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
      execute: _executeDapConnect,
    ),
  ];

  Future<ToolExecutionResult> _executeDapStatus(
    Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
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
  }

  Future<ToolExecutionResult> _executeDapPeers(
    Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
    final peers = await _hub.peers();
    final text = peers.isEmpty
        ? 'no peers on the hub'
        : [
            for (final peer in peers)
              '${peer.agentId} ${peer.name ?? '-'}'
                  '${peer.self ? ' (self)' : ''}',
          ].join('\n');
    return ToolExecutionResult(content: [TextContent(text: text)]);
  }

  Future<ToolExecutionResult> _executeDapDm(
    Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
    final target = await _resolvePeer(arguments['to'] as String);
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
  }

  Future<ToolExecutionResult> _executeDapInvite(
    Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
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
  }

  Future<ToolExecutionResult> _executeDapConnect(
    Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
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
  }

  /// Resolves [to] to a peer agent id: an exact id wins, otherwise the
  /// display name must match exactly one online peer. Ambiguity and
  /// no-match errors list the online peers so the model can retry.
  Future<String> _resolvePeer(String to) async {
    final peers = await _hub.peers();
    final exact = _peerById(peers, to);
    if (exact != null) return to;
    return _resolvePeerName(to, peers);
  }

  hub.AgentInfo? _peerById(List<hub.AgentInfo> peers, String agentId) {
    for (final peer in peers) {
      if (peer.agentId == agentId) return peer;
    }
    return null;
  }

  String _resolvePeerName(String to, List<hub.AgentInfo> peers) {
    final byName = peers.where((peer) => peer.name == to).toList();
    if (byName.length == 1) return byName.single.agentId;
    throw _peerResolutionError(to, peers, byName);
  }

  StateError _peerResolutionError(
    String to,
    List<hub.AgentInfo> peers,
    List<hub.AgentInfo> byName,
  ) {
    final online = _onlinePeerList(peers);
    return StateError(
      byName.isEmpty
          ? 'no online peer matches "$to" — online peers:\n$online'
          : 'peer name "$to" is ambiguous — online peers:\n$online',
    );
  }

  String _onlinePeerList(List<hub.AgentInfo> peers) {
    return [
      for (final peer in peers)
        '${peer.agentId} ${peer.name ?? '-'}'
            '${peer.online ? '' : ' (offline)'}',
    ].join('\n');
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
