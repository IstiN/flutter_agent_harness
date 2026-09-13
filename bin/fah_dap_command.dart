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
       _terminateHub = terminateHub ?? _defaultTerminate {
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

  String get _configPath =>
      client.defaultDapConfigFile(home, environment);

  File get _pidFile => File(
    environment[envHubPidFile] ?? dapHubPidFileFor(_homeRoot),
  );

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
    ))
        ?.trim();
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
    final config = client.readDapConfig(_configPath);
    final attempts = <(String?, bool)>[
      if (config['clientSecret'] is String &&
          (config['clientSecret'] as String).isNotEmpty)
        (config['clientSecret'] as String, false),
      if (knownMaster != null) (knownMaster, true),
      if (_readHubState().masterSecret case final master?)
        if (master != knownMaster) (master, true),
      (null, true), // open hub: bare dial + ceremonial enroll
    ];
    for (final (secret, enroll) in attempts) {
      final outcome = await _tryDial(secret, enroll: enroll);
      if (outcome.ok) {
        await _finishCredential();
        return true;
      }
      if (outcome.unauthorized &&
          identical(secret, config['clientSecret'])) {
        // A stale cached secret the hub rejects must not win precedence
        // forever — drop it (the hub-issued flow below re-arms it).
        await client.persistDapConfig(
          clearClientSecret: true,
          file: _configPath,
        );
      }
    }
    // Interactive last resort: the user knows the hub's master key.
    for (var attempt = 1; attempt <= 3; attempt++) {
      final prompt = secretPrompt;
      if (prompt == null) break;
      final entered = (await prompt(
        'DAP master key for $url (hidden): ',
      ))
          ?.trim();
      if (entered == null || entered.isEmpty) break;
      final outcome = await _tryDial(entered, enroll: true);
      if (outcome.ok) {
        await _finishCredential();
        return true;
      }
      if (outcome.unauthorized && attempt < 3) {
        say('enrollment rejected (wrong master key) — try again');
        continue;
      }
      break;
    }
    say(
      'could not enroll with this hub — manual recovery: set the hub '
      'password in ~/.dap/hub.json (masterSecret), or export '
      'DAP_MASTER_SECRET, then re-run fa dap start',
    );
    return false;
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
          if (stored is String &&
              stored.isNotEmpty &&
              stored != secret) {
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
        final state = _readPidState();
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
      return (
        kind: DapHubProbeKind.down,
        peers: const <String>[],
      );
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
        return (
          kind: DapHubProbeKind.foreign,
          peers: const <String>[],
        );
      }
    }
    // Every credential was rejected but the WS endpoint answers with the
    // DAP 401 shape: a protected hub we cannot list (still attachable).
    return (
      kind: sawUnauthorized
          ? DapHubProbeKind.running
          : DapHubProbeKind.foreign,
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
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(
        url,
        headers: {
          if (credential != null)
            'Authorization': 'Bearer $credential',
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
    try {
      final answer = Completer<List<String>>();
      late final StreamSubscription sub;
      sub = ws.listen((dynamic data) {
        try {
          final frame = jsonDecode(data as String);
          if (frame is Map && frame['op'] == 'presence') {
            final agents = frame['agents'];
            answer.complete([
              if (agents is List)
                for (final agent in agents)
                  if (agent is Map &&
                      agent['online'] == true &&
                      agent['name'] is String)
                    agent['name'] as String,
            ]);
          }
        } on Object {
          // Not a presence frame — the timeout below downgrades to
          // "running, roster unknown" rather than guessing.
        }
      });
      ws.add(jsonEncode({
        'op': 'presence_query',
        'id': 'fa-dap-probe-${_nonce()}',
      }));
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

  static String _nonce() {
    final random = Random();
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
        random.nextInt(1 << 32).toRadixString(36);
  }

  /// `GET /healthz` → 200.
  Future<bool> healthzOk() async {
    try {
      final http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
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

  /// SIGTERM the owning pid, wait for the port to drain (≤5s), then
  /// SIGKILL. True when the hub is gone.
  static Future<bool> _defaultTerminate(int pid) async {
    try {
      Process.killPid(pid, ProcessSignal.sigterm);
    } on Object {
      return false;
    }
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!_pidAlive(pid)) return true;
    }
    try {
      Process.killPid(pid, ProcessSignal.sigkill);
    } on Object {
      // Already gone, or unkillable — the liveness check decides.
    }
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!_pidAlive(pid)) return true;
    }
    return !_pidAlive(pid);
  }

  /// Whether [pid] is still a live process (signal 0 dance: Dart has no
  /// kill(pid, 0), so we ask the shell — POSIX only; non-POSIX hosts
  /// report alive and rely on the port check).
  static bool _pidAlive(int pid) {
    if (!Platform.isLinux && !Platform.isMacOS) return true;
    final result = Process.runSync('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  }
}

class _WsUnauthorized implements Exception {}

class _WsNotAHub implements Exception {}

/// `fa dap <start|stop|status> [--port N] [--url URL]` — the CLI entry.
Future<int> runDapCommand(
  List<String> args, {
  String? home,
  Map<String, String>? environment,
  DapSpawnSeam? spawnHub,
  DapTerminateSeam? terminateHub,
  DapSecretPrompt? secretPrompt,
  void Function(String line)? out,
}) async {
  const usage =
      'usage: fa dap start [--port N] | fa dap stop | fa dap status';
  if (args.isEmpty) {
    stdout.writeln(usage);
    return 1;
  }
  var url = defaultDapLocalHubUrl;
  var portSeen = false;
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      final port = int.tryParse(args[++i]);
      if (port == null || port <= 0) {
        stderr.writeln('fa dap: bad --port "${args[i]}"');
        return 1;
      }
      url = 'ws://127.0.0.1:$port/ws';
      portSeen = true;
    } else if (args[i] == '--url' && i + 1 < args.length) {
      url = args[++i];
      portSeen = true;
    } else {
      stderr.writeln(usage);
      return 1;
    }
  }
  final effectiveEnv = environment ?? Platform.environment;
  final controller = DapHubController(
    home: home,
    environment: effectiveEnv,
    url: portSeen ? url : resolveDapLocalHubUrl(effectiveEnv),
    spawnHub: spawnHub,
    terminateHub: terminateHub,
    secretPrompt: secretPrompt ?? _stdinSecretPrompt,
    // The CLI surface prints to stdout (tests inject their own sink).
    out: out ?? stdout.writeln,
  );
  switch (args.first) {
    case 'start':
      return controller.start();
    case 'stop':
      return controller.stop();
    case 'status':
      return controller.status();
    default:
      stderr.writeln(usage);
      return 1;
  }
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
