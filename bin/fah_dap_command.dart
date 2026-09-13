/// `fa dap start|stop|status` (issue #304) — the one-step local DAP hub:
///
/// * **start** probes the local port (`/healthz` + a `/ws` presence
///   handshake). Nothing there → spawn `fa hub serve` detached, prompt
///   for the master key ONCE (hidden input, only when a protected hub is
///   being created or joined), enroll per the `DAP_MASTER_SECRET` flow
///   and persist the hub-issued clientSecret (0600) into
///   `~/.dap/config.json` — from then on every later boot is online by
///   itself and hub peers are first-class `agent_directory` citizens.
///   Already running → attach, no prompts. A foreign server on the port
///   → a clear error naming the port, no enrollment (E1).
/// * **stop** names the connected peers (e.g. "Browser"), terminates the
///   owning pid from the `~/.dap/hub.pid` state file (works from EITHER
///   CLI instance, exactly once — E4) and leaves the messaging fabric on
///   its honest file-inbox fallback (27.1).
/// * **status** reports running/stopped, url, pid and peers.
///
/// Everything IO-bound lives here in `bin/` (dart:io); every effect is
/// an injectable seam so the integration tests drive real sockets but no
/// forked processes. `bin/fah_hub_plugin.dart` reuses the same controller
/// for the `/dap` menu's Start/Stop rows (AC7).
library;

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io';
import 'dart:math' show Random;

import 'package:fa_hub_client/fa_hub_client.dart' as client;
import 'package:flutter_agent_harness/io.dart'
    show defaultHubStateFile, readHubState, writeHubState;

import 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart';

export 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart';

/// The zero-config local hub URL (`ws://127.0.0.1:8787/ws`).
const String defaultDapLocalHubUrl = 'ws://127.0.0.1:8787/ws';

/// The pid/state file override env (`~/.dap/hub.pid` by default).
const String envHubPidFile = 'DAP_HUB_PID_FILE';

/// The local-hub url override env: the one-step start/stop/status
/// surface targets THIS url instead of the zero-config default (test
/// isolation; also a user running the hub on a fixed non-default port).
const String envLocalHubUrl = 'DAP_LOCAL_HUB_URL';

/// The effective local-hub url: `DAP_LOCAL_HUB_URL` > the zero-config
/// default.
String resolveDapLocalHubUrl(Map<String, String> environment) =>
    environment[envLocalHubUrl] ?? defaultDapLocalHubUrl;

/// What answered the local-port probe.
enum DapHubProbeKind {
  /// Nothing is serving HTTP there.
  down,

  /// A DAP hub (healthz + a presence answer over `/ws`).
  running,

  /// Something serves HTTP but is not a DAP hub (E1).
  foreign,
}

/// The probe outcome: the kind plus the ONLINE peer names when known.
typedef DapHubProbeResult = ({DapHubProbeKind kind, List<String> peers});

/// Spawn seam: bring up a hub for [url] (the resolved hub-side
/// [masterSecret], when one is set) and return its pid.
typedef DapSpawnSeam = Future<int> Function(String url, String? masterSecret);

/// Terminate seam: stop the hub owning [pid]; true when it is gone.
typedef DapTerminateSeam = Future<bool> Function(int pid);

/// Hidden-input master-key prompt (the provider-key-flow seam shape).
typedef DapSecretPrompt = Future<String?> Function(String question);

/// The one-step local-hub controller behind `fa dap` and the `/dap` menu.
class DapHubController {
  DapHubController({
    this.home,
    Map<String, String>? environment,
    String? url,
    DapSpawnSeam? spawnHub,
    DapTerminateSeam? terminateHub,
    this.secretPrompt,
    void Function(String line)? out,
  }) : environment = environment ?? Platform.environment,
       url = url ?? resolveDapLocalHubUrl(environment ?? Platform.environment),
       _spawnHub = spawnHub ?? _defaultSpawn,
       _terminateHub =
           terminateHub ??
           ((pid) => defaultDapTerminate(
             pid,
             url ?? resolveDapLocalHubUrl(environment ?? Platform.environment),
           )) {
    _out = out;
  }

  /// Home override for the `~/.dap` layout (test seam).
  final String? home;

  /// Injected environment (defaults to `Platform.environment`).
  final Map<String, String> environment;

  /// The local hub url (default `ws://127.0.0.1:8787/ws`).
  final String url;

  /// Hidden master-key prompt; null on non-interactive hosts.
  final DapSecretPrompt? secretPrompt;

  final DapSpawnSeam _spawnHub;
  final DapTerminateSeam _terminateHub;

  /// Everything the controller printed (tests assert on it; the
  /// production `out` echoes to stdout/terminal).
  final lines = <String>[];

  /// Set when an enroll dial actually persisted a hub-issued secret this
  /// session (the `enrolled` line reports reality, not optimism).
  bool _enrolledThisSession = false;

  void Function(String line)? _out;

  void say(String line) {
    lines.add(line);
    _out?.call(line);
  }

  // ---- paths ----

  String get _homeRoot =>
      home ?? environment['HOME'] ?? environment['USERPROFILE'] ?? '.';

  File get _stateFile =>
      defaultHubStateFile(home: home, environment: environment);

  String get _configPath => client.defaultDapConfigFile(home, environment);

  File get _pidFile =>
      File(environment[envHubPidFile] ?? dapHubPidFileFor(_homeRoot));

  Uri get _uri => Uri.parse(url);

  // ---- start ----

  /// The one-step start. Returns the process exit code.
  Future<int> start() async {
    final probe = await probeHub();
    switch (probe.kind) {
      case DapHubProbeKind.foreign:
        say(
          'port ${_uri.port} answers HTTP but is not a DAP hub — '
          'stop the other server or pass --port',
        );
        return 1;
      case DapHubProbeKind.running:
        say('DAP hub already running at $url — attached');
        final ok = await _ensureCredential(
          knownMaster: _readHubState().masterSecret,
        );
        return ok ? 0 : 1;
      case DapHubProbeKind.down:
        final master = await _resolveMasterSecret();
        final int pid;
        try {
          pid = await _spawnHub(url, master);
        } on Object catch (error) {
          say('could not start a local hub on port ${_uri.port}: $error');
          return 1;
        }
        if (!await _waitUntilUp()) {
          say(
            'the local hub did not come up on port ${_uri.port} '
            '(something else may hold it)',
          );
          return 1;
        }
        _writePidState(pid, _uri.port);
        say('DAP hub on $url (pid $pid)');
        final ok = await _ensureCredential(knownMaster: master);
        return ok ? 0 : 1;
    }
  }

  /// Resolves the hub-side master secret for a fresh spawn: the persisted
  /// `~/.dap/hub.json` password wins; otherwise an interactive host is
  /// asked ONCE for a master key (hidden; empty = open hub — anyone on
  /// this machine can join, the zero-config extension default), and the
  /// choice is remembered in the state file so it never nags again.
  /// Non-interactive hosts with no stored password start an open hub —
  /// zero-config is the default and nothing prompts (AC5).
  Future<String?> _resolveMasterSecret() async {
    final stateFile = _stateFile;
    final state = _readHubState();
    if (state.masterSecret != null) return state.masterSecret;
    final prompt = secretPrompt;
    if (prompt == null) return null;
    // A remembered explicit "open" choice (the file exists, password
    // null) is respected — the same never-nag-twice contract as
    // `fa hub serve`.
    if (await stateFile.exists()) return null;
    final entered = (await prompt(
      'DAP master key for the local hub '
      '(hidden; empty = open hub, anyone on this machine can join): ',
    ))?.trim();
    if (entered == null || entered.isEmpty) {
      await _rememberOpenChoice(stateFile, state.clients);
      return null;
    }
    await writeHubState(
      stateFile,
      masterSecret: entered,
      clients: state.clients,
    );
    return entered;
  }

  Future<void> _rememberOpenChoice(
    File stateFile,
    Map<String, String> clients,
  ) async {
    try {
      await writeHubState(stateFile, masterSecret: null, clients: clients);
    } on Object {
      // Best-effort persistence; the open hub serves regardless.
    }
  }

  /// Waits for `/healthz` on the local port (spawn settle), ≤8s.
  Future<bool> _waitUntilUp() async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (await healthzOk()) return true;
    }
    return false;
  }

  /// Ensures this CLI holds a working dial credential against the live
  /// hub and the next boot finds it: an existing clientSecret is VERIFIED
  /// (401 → dropped), then the master this start already resolved (the
  /// prompted key or `~/.dap/hub.json`) enrolls automatically, then a
  /// bare enroll covers open hubs — only when ALL of those fail does an
  /// interactive host prompt for the master key (up to 3×, E3). Success
  /// persists the hub-issued clientSecret (never a master key), 0600.
  Future<bool> _ensureCredential({String? knownMaster}) async {
    final cached = client.readDapConfig(_configPath)['clientSecret'];
    final cachedEnrolled = await _tryCredentialAttempts(
      _credentialAttempts(cachedSecret: cached, knownMaster: knownMaster),
      cached,
    );
    if (cachedEnrolled || await _promptMasterCredential()) return true;
    say(
      'could not enroll with this hub — manual recovery: set the hub '
      'password in ~/.dap/hub.json (masterSecret), or export '
      'DAP_MASTER_SECRET, then re-run fa dap start',
    );
    return false;
  }

  /// The dial attempts in precedence order: the cached clientSecret,
  /// the master this start resolved, the persisted state's master,
  /// then a bare open-hub enroll.
  List<(String?, bool)> _credentialAttempts({
    required Object? cachedSecret,
    String? knownMaster,
  }) => [
    if (cachedSecret is String && cachedSecret.isNotEmpty)
      (cachedSecret, false),
    if (knownMaster != null) (knownMaster, true),
    if (_readHubState().masterSecret case final master?)
      if (master != knownMaster) (master, true),
    (null, true), // open hub: bare dial + ceremonial enroll
  ];

  /// Runs the attempts in order until one dials; drops a stale cached
  /// clientSecret the hub 401-rejects ([cachedSecret], by identity) so
  /// it cannot win precedence forever.
  Future<bool> _tryCredentialAttempts(
    List<(String?, bool)> attempts,
    Object? cachedSecret,
  ) async {
    for (final (secret, enroll) in attempts) {
      final outcome = await _tryDial(secret, enroll: enroll);
      if (outcome.ok) {
        await _finishCredential();
        return true;
      }
      if (outcome.unauthorized && identical(secret, cachedSecret)) {
        await client.persistDapConfig(
          clearClientSecret: true,
          file: _configPath,
        );
      }
    }
    return false;
  }

  /// The interactive last resort: the user knows the hub's master key
  /// (up to 3 tries, E3); true when a prompted dial enrolls.
  Future<bool> _promptMasterCredential() async {
    final prompt = secretPrompt;
    if (prompt == null) return false;
    for (var attempt = 1; attempt <= 3; attempt++) {
      final outcome = await _promptedMasterDial(prompt);
      if (outcome == null) break;
      if (outcome.ok) {
        await _finishCredential();
        return true;
      }
      if (outcome.unauthorized && attempt < 3) {
        say('enrollment rejected (wrong master key) — try again');
      } else {
        break;
      }
    }
    return false;
  }

  /// One prompted master-key dial; null on an empty answer (give up).
  Future<({bool ok, bool unauthorized})?> _promptedMasterDial(
    DapSecretPrompt prompt,
  ) async {
    final entered = (await prompt(
      'DAP master key for $url (hidden): ',
    ))?.trim();
    if (entered == null || entered.isEmpty) return null;
    return _tryDial(entered, enroll: true);
  }

  /// Post-success bookkeeping: pin the url next to the credential and
  /// tighten the config file mode (0600 where chmod exists).
  Future<void> _finishCredential() async {
    try {
      await client.persistDapConfig(url: url, file: _configPath);
      await Process.run('chmod', ['600', _configPath]);
    } on Object {
      // Best-effort; the credential itself is already persisted.
    }
    if (_enrolledThisSession) {
      say('enrolled — client secret saved to $_configPath (0600)');
    }
    say(
      'fabric enabled — hub peers appear in agent_directory on the next '
      'fa session',
    );
  }

  /// One dial attempt with a FRESH client (each client escalates its own
  /// 401 at most once). `enroll: true` follows the `DAP_MASTER_SECRET`
  /// flow: welcome, `{"t":"enroll"}`, the hub-issued secret replaces the
  /// master in `~/.dap/config.json` (polled here — the client persists
  /// asynchronously once the `enrolled` frame lands).
  Future<({bool ok, bool unauthorized})> _tryDial(
    String? secret, {
    required bool enroll,
  }) async {
    client.HubClient? hubClient;
    try {
      final settings = client.resolveDapSettings(
        config: client.HubConfig(url: url),
        environment: environment,
        home: home,
      );
      hubClient = client.HubClient(
        config: client.HubConfig(url: url),
        identity: await client.HubIdentity.load(settings.keyPath),
        clientSecret: secret,
        enroll: enroll,
        configFile: _configPath,
        requestTimeout: const Duration(seconds: 5),
      );
      await hubClient.connect().timeout(const Duration(seconds: 8));
      if (enroll) {
        // The enrolled frame lands right after the welcome; wait for the
        // issued secret to reach the config (≤3s).
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline)) {
          final stored = client.readDapConfig(_configPath)['clientSecret'];
          if (stored is String && stored.isNotEmpty && stored != secret) {
            _enrolledThisSession = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return (ok: true, unauthorized: false);
    } on client.HubError catch (error) {
      return (ok: false, unauthorized: error.code == 'unauthorized');
    } on Object {
      return (ok: false, unauthorized: false);
    } finally {
      try {
        await hubClient?.disconnect();
      } on Object {
        // The dial is done; a failed teardown must not mask the outcome.
      }
    }
  }

  // ---- stop ----

  /// Graceful stop. Returns the process exit code.
  Future<int> stop() async {
    final probe = await probeHub();
    switch (probe.kind) {
      case DapHubProbeKind.down:
        _clearPidState();
        say('DAP hub is not running');
        return 0;
      case DapHubProbeKind.foreign:
        say(
          'port ${_uri.port} is held by a non-DAP server — '
          'nothing to stop here',
        );
        return 1;
      case DapHubProbeKind.running:
        if (probe.peers.isNotEmpty) {
          say(
            'stopping the DAP hub — ${probe.peers.length} peer(s) '
            'connected: ${probe.peers.join(', ')}',
          );
        } else {
          say('stopping the DAP hub');
        }
        var state = _readPidState();
        // Pid-recycling guard: a stale state file whose port does not
        // match this hub must never name an innocent process. Treat it
        // as absent (the honest manual hint below covers the rest).
        if (state != null && state.port != _uri.port) state = null;
        if (state == null) {
          say(
            'no pid state in ${_pidFile.path} — stop the hub process '
            'manually',
          );
          return 1;
        }
        final stopped = await _terminateHub(state.pid);
        if (!stopped) {
          say(
            'could not stop hub pid ${state.pid} — '
            'kill it manually: kill ${state.pid}',
          );
          return 1;
        }
        _clearPidState();
        say('DAP hub stopped');
        return 0;
    }
  }

  // ---- status ----

  /// The status report. Returns the process exit code.
  Future<int> status() async {
    final probe = await probeHub();
    switch (probe.kind) {
      case DapHubProbeKind.down:
        _clearStalePidStateWhenDown();
        say('DAP hub: not running');
        return 0;
      case DapHubProbeKind.foreign:
        say('port ${_uri.port}: held by a non-DAP server');
        return 1;
      case DapHubProbeKind.running:
        final state = _readPidState();
        final pid = state == null ? '-' : '${state.pid}';
        final peers = probe.peers.isEmpty
            ? 'no peers connected'
            : 'peers: ${probe.peers.join(', ')}';
        say('DAP hub: running at $url (pid $pid) — $peers');
        return 0;
    }
  }

  void _clearStalePidStateWhenDown() {
    // A down hub with a leftover state file (crash, kill -9): clear it so
    // the next stop is a calm no-op and no zombie pid survives (E4).
    _clearPidState();
  }

  // ---- probe ----

  /// Probes the local port: `/healthz`, then a `/ws` presence handshake
  /// (the upgrade + one `presence_query` answer) — that two-step is what
  /// separates OUR hub from a foreign server (E1). A 401 upgrade means a
  /// protected DAP hub; the hub-state credential names its peers when
  /// available.
  Future<DapHubProbeResult> probeHub() async {
    if (!await healthzOk()) {
      return (kind: DapHubProbeKind.down, peers: const <String>[]);
    }
    var sawUnauthorized = false;
    for (final credential in _probeCredentials()) {
      try {
        final peers = await _presenceProbe(credential);
        return (
          kind: DapHubProbeKind.running,
          peers: peers ?? const <String>[],
        );
      } on _WsUnauthorized {
        sawUnauthorized = true;
      } on _WsNotAHub {
        return (kind: DapHubProbeKind.foreign, peers: const <String>[]);
      }
    }
    // Every credential was rejected but the WS endpoint answers with the
    // DAP 401 shape: a protected hub we cannot list (still attachable).
    return (
      kind: sawUnauthorized ? DapHubProbeKind.running : DapHubProbeKind.foreign,
      peers: const <String>[],
    );
  }

  /// Credential candidates for the presence probe, cheapest first: bare
  /// (open hub), the persisted client config, the hub state file's
  /// master secret, then its enrolled client secrets.
  List<String?> _probeCredentials() {
    final hubState = _readHubState();
    return [
      null,
      client.readDapConfig(_configPath)['clientSecret'] as String?,
      hubState.masterSecret,
      ...hubState.clients.values,
    ];
  }

  /// One `/ws` presence handshake: upgrade, ask `presence_query`, read
  /// the roster answer. Null peers = the upgrade succeeded but no
  /// presence answer arrived (a DAP-shaped WS endpoint — running, roster
  /// unknown). Throws [_WsNotAHub] when the upgrade itself fails
  /// (foreign server) and [_WsUnauthorized] on a 401 upgrade.
  Future<List<String>?> _presenceProbe(String? credential) async {
    final ws = await _connectProbeSocket(credential);
    return _probeRoster(ws);
  }

  /// Connects the probe's `/ws` socket (3s budget): [_WsUnauthorized]
  /// on a 401 upgrade, [_WsNotAHub] on any other failure.
  Future<WebSocket> _connectProbeSocket(String? credential) async {
    try {
      return await WebSocket.connect(
        url,
        headers: {
          if (credential != null) 'Authorization': 'Bearer $credential',
        },
      ).timeout(const Duration(seconds: 3));
    } on WebSocketException catch (error) {
      if (error.httpStatusCode == HttpStatus.unauthorized) {
        throw _WsUnauthorized();
      }
      throw _WsNotAHub();
    } on Object {
      throw _WsNotAHub();
    }
  }

  /// Asks `presence_query` and awaits the roster answer (3s budget);
  /// null when no answer arrives — running, roster unknown.
  Future<List<String>?> _probeRoster(WebSocket ws) async {
    final answer = Completer<List<String>>();
    // The probe's frame id: the answer must echo it as `replyTo`
    // (protocol §presence). Matching on it keeps an unsolicited
    // presence PUSH (a broadcast racing the query answer) from
    // completing the probe with a partial roster.
    final probeId = 'fa-dap-probe-${_nonce()}';
    late final StreamSubscription sub;
    sub = ws.listen((dynamic data) => _onProbeFrame(answer, probeId, data));
    ws.add(jsonEncode({'op': 'presence_query', 'id': probeId}));
    try {
      final peers = await answer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();
      return peers;
    } on TimeoutException {
      // The WS upgrade worked — a DAP-shaped endpoint that does not (yet)
      // answer presence. Running, peers unknown.
      return null;
    } on Object {
      return null;
    } finally {
      await ws.close();
    }
  }

  /// Feeds one inbound frame into [answer] when it is THE presence
  /// answer (matched by `replyTo`, protocol §presence); anything else
  /// is ignored.
  void _onProbeFrame(
    Completer<List<String>> answer,
    String probeId,
    dynamic data,
  ) {
    try {
      final frame = jsonDecode(data as String);
      if (_isPresenceAnswer(frame, probeId) && !answer.isCompleted) {
        answer.complete(_onlineAgents(frame['agents']));
      }
    } on Object {
      // Not a presence frame — the timeout below downgrades to
      // "running, roster unknown" rather than guessing.
    }
  }

  /// Whether [frame] is the presence answer this probe asked for.
  static bool _isPresenceAnswer(dynamic frame, String probeId) =>
      frame is Map && frame['op'] == 'presence' && frame['replyTo'] == probeId;

  /// The online agent names in a presence answer ([agents] non-list or
  /// foreign shapes yield an empty roster, never a crash).
  static List<String> _onlineAgents(dynamic agents) => [
    if (agents is List)
      for (final agent in agents)
        if (agent is Map && agent['online'] == true && agent['name'] is String)
          agent['name'] as String,
  ];

  static String _nonce() {
    final random = Random();
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
        random.nextInt(1 << 32).toRadixString(36);
  }

  /// `GET /healthz` → 200.
  Future<bool> healthzOk() async {
    try {
      final http = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      final response = await (await http.get(
        _uri.host,
        _uri.port,
        '/healthz',
      )).close();
      await response.drain<void>();
      http.close();
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  // ---- state files ----

  ({String? masterSecret, Map<String, String> clients}) _readHubState() {
    try {
      return readHubState(_stateFile);
    } on Object {
      return (masterSecret: null, clients: const {});
    }
  }

  DapLocalHubState? _readPidState() {
    try {
      return parseDapLocalHubState(_pidFile.readAsStringSync());
    } on Object {
      return null;
    }
  }

  void _writePidState(int pid, int port) {
    try {
      final file = _pidFile;
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        renderDapLocalHubState((
          pid: pid,
          port: port,
          startedAt: DateTime.now().toUtc().toIso8601String(),
        )),
      );
    } on Object {
      // Best-effort: the probe remains the source of truth for "running".
    }
  }

  void _clearPidState() {
    try {
      if (_pidFile.existsSync()) _pidFile.deleteSync();
    } on Object {
      // A stuck state file never blocks the flow.
    }
  }

  // ---- default seams (production IO) ----

  /// Spawns a detached `fa hub serve --port N` that outlives this CLI
  /// (the serve command reads the hub password from `~/.dap/hub.json`).
  static Future<int> _defaultSpawn(String url, String? masterSecret) async {
    final port = Uri.parse(url).port;
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
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }
}

/// Whether the host can probe pid liveness the POSIX way (the
/// `kill -0` dance). Windows cannot — dart:io has no liveness probe
/// there — so the default terminate uses the port check instead (see
/// [defaultDapTerminate]).
bool get dapPidProbePosix => Platform.isLinux || Platform.isMacOS;

/// Whether anything still accepts connections on the hub port ([uri])
/// — a live hub answers; a terminated one releases its listener. This
/// is the stop path's liveness signal on hosts without a pid probe
/// (Windows).
Future<bool> dapPortAnswers(Uri uri) async {
  try {
    final socket = await Socket.connect(
      uri.host,
      uri.port,
      timeout: const Duration(milliseconds: 500),
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

/// Signals [pid] (SIGTERM, escalating to SIGKILL after [grace]) and
/// waits until [gone] reports the hub dead — ≤[grace] after the
/// SIGTERM, ≤[force] after the SIGKILL; true when it is gone. [gone]
/// is the host liveness probe and [kill] the signal seam (tests
/// inject recorders; production wires `Process.killPid`).
Future<bool> dapTerminateHub(
  int pid,
  Future<bool> Function() gone, {
  void Function(int pid, ProcessSignal signal)? kill,
  Duration grace = const Duration(seconds: 5),
  Duration force = const Duration(seconds: 2),
}) async {
  final killer = kill ?? Process.killPid;
  try {
    killer(pid, ProcessSignal.sigterm);
  } on Object {
    return false;
  }
  for (var i = 0; i < grace.inMilliseconds ~/ 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (await gone()) return true;
  }
  try {
    killer(pid, ProcessSignal.sigkill);
  } on Object {
    // Already gone, or unkillable — the liveness probe decides.
  }
  for (var i = 0; i < force.inMilliseconds ~/ 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (await gone()) return true;
  }
  return await gone();
}

/// The default terminate seam: stop the hub owning [pid] at [url] and
/// report whether it is gone. POSIX hosts probe the pid (`kill -0`);
/// hosts without a pid probe (Windows) watch the hub PORT drain —
/// there `Process.killPid` hard-terminates regardless of signal (the
/// SDK ignores the signal parameter on Windows) but no liveness probe
/// exists, so a pid-only check would report "alive" forever and
/// false-fail a stop that already worked (exit 1 + a stale pid file).
/// [pidProbePosix] pins the branch so tests drive the Windows path on
/// any OS; [kill]/[grace]/[force] are the remaining seams.
Future<bool> defaultDapTerminate(
  int pid,
  String url, {
  bool? pidProbePosix,
  void Function(int pid, ProcessSignal signal)? kill,
  Duration grace = const Duration(seconds: 5),
  Duration force = const Duration(seconds: 2),
}) {
  final posix = pidProbePosix ?? dapPidProbePosix;
  final uri = Uri.parse(url);
  return dapTerminateHub(
    pid,
    posix
        ? () async => !_pidAlive(pid)
        : () async => !await dapPortAnswers(uri),
    kill: kill,
    grace: grace,
    force: force,
  );
}

/// Whether [pid] is still a live process (signal 0 dance: Dart has no
/// kill(pid, 0), so we ask the shell — POSIX only; hosts without it
/// report alive and [defaultDapTerminate] uses the port check).
bool _pidAlive(int pid) {
  if (!Platform.isLinux && !Platform.isMacOS) return true;
  final result = Process.runSync('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

class _WsUnauthorized implements Exception {}

class _WsNotAHub implements Exception {}

/// One `fa dap <verb>` handler: runs the verb against [controller].
typedef DapSubcommand = Future<int> Function(DapHubController controller);

/// The `fa dap` verb table — start/stop/status. A map (not a switch)
/// keeps the dispatcher branch-free and each verb a one-line entry.
final Map<String, DapSubcommand> dapSubcommands = {
  'start': (controller) => controller.start(),
  'stop': (controller) => controller.stop(),
  'status': (controller) => controller.status(),
};

/// One parsed `fa dap` invocation: the resolved hub [url] plus whether
/// a flag set it explicitly (an explicit `--port`/`--url` beats
/// `DAP_LOCAL_HUB_URL`).
typedef DapInvocation = ({String url, bool explicit});

/// `--port N` → `ws://127.0.0.1:N/ws`; null on a missing/invalid N.
String? dapPortUrl(String? rawPort) {
  final port = rawPort == null ? null : int.tryParse(rawPort);
  if (port == null || port <= 0) return null;
  return 'ws://127.0.0.1:$port/ws';
}

/// One flag → the hub url it selects; null when [flag] is unknown or
/// its value is missing/invalid.
String? _dapFlagUrl(String flag, String? value) => switch (flag) {
  '--port' => dapPortUrl(value),
  '--url' => value,
  _ => null,
};

/// Parses the flags after the verb word; null on any bad flag.
DapInvocation? parseDapInvocation(List<String> flags) {
  var url = defaultDapLocalHubUrl;
  var explicit = false;
  for (var i = 0; i < flags.length; i++) {
    final flag = flags[i];
    final value = i + 1 < flags.length ? flags[i + 1] : null;
    final applied = _dapFlagUrl(flag, value);
    if (applied == null) return null;
    url = applied;
    explicit = true;
    if (value != null) i++;
  }
  return (url: url, explicit: explicit);
}

/// Builds the controller a dispatched verb runs with: the seams flow
/// through unchanged, and the CLI surface prints to stdout (tests
/// inject their own sink).
DapHubController buildDapController(
  DapInvocation invocation, {
  String? home,
  Map<String, String>? environment,
  DapSpawnSeam? spawnHub,
  DapTerminateSeam? terminateHub,
  DapSecretPrompt? secretPrompt,
  void Function(String line)? out,
}) {
  final effectiveEnv = environment ?? Platform.environment;
  return DapHubController(
    home: home,
    environment: effectiveEnv,
    url: invocation.explicit
        ? invocation.url
        : resolveDapLocalHubUrl(effectiveEnv),
    spawnHub: spawnHub,
    terminateHub: terminateHub,
    secretPrompt: secretPrompt ?? _stdinSecretPrompt,
    out: out ?? stdout.writeln,
  );
}

/// `fa dap <start|stop|status> [--port N] [--url URL]` — the CLI
/// entry: parse once, look the verb up in [dapSubcommands], run it.
Future<int> runDapCommand(
  List<String> args, {
  String? home,
  Map<String, String>? environment,
  DapSpawnSeam? spawnHub,
  DapTerminateSeam? terminateHub,
  DapSecretPrompt? secretPrompt,
  void Function(String line)? out,
}) async {
  const usage = 'usage: fa dap start [--port N] | fa dap stop | fa dap status';
  if (args.isEmpty) {
    stdout.writeln(usage);
    return 1;
  }
  final sub = dapSubcommands[args.first];
  final invocation = sub == null ? null : parseDapInvocation(args.sublist(1));
  if (invocation == null) {
    stderr.writeln(usage);
    return 1;
  }
  final controller = buildDapController(
    invocation,
    home: home,
    environment: environment,
    spawnHub: spawnHub,
    terminateHub: terminateHub,
    secretPrompt: secretPrompt,
    out: out,
  );
  return sub!(controller);
}

/// Hidden-input master-key prompt on a real terminal (the same
/// echoMode-off seam as the provider key flows; AC6 — never echoed).
Future<String?> _stdinSecretPrompt(String question) async {
  if (!stdin.hasTerminal) return null;
  stdout.write(question);
  String? line;
  try {
    stdin.echoMode = false;
    line = stdin.readLineSync();
  } finally {
    stdin.echoMode = true;
    stdout.writeln();
  }
  return line;
}
