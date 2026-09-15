/// `fa hub serve [--port N] [--secret S] [--bind lan]` — runs a local DAP/1 hub
/// (`package:flutter_agent_harness/io.dart` `LocalHub`, docs/dap.md §8.1)
/// in the foreground until killed. `/dap start` spawns this detached so
/// the hub outlives the CLI that launched it; other zero-config clients
/// (the default URL is `ws://127.0.0.1:8787/ws`) find it on their own.
///
/// Password protection: the hub's master secret resolves as
/// `--secret` > `DAP_HUB_SECRET` > the persisted `~/.dap/hub.json`. When
/// none is set AND stdin is an interactive terminal, the command offers
/// to set one (empty answer = open loopback hub, the old behavior); an
/// entered password is persisted so the next start stops asking.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/hub/dap_local_hub_state.dart';

import 'fah_dap_command.dart' show envHubPidFile;

/// The well-known zero-config port (mirrors the client default
/// `ws://127.0.0.1:8787/ws`).
const defaultHubServePort = 8787;

/// The injected seams a `fa hub` subcommand runs with: [environment]
/// and [home] relocate the `~/.dap` layout (tests), [serveLoop] cuts
/// the eternal serve wait short, [secretPrompt] replaces the terminal
/// password prompt. All null in production.
typedef HubServeDeps = ({
  Map<String, String>? environment,
  String? home,
  Future<void> Function(LocalHub hub, File pidFile)? serveLoop,
  Future<String?> Function(File stateFile)? secretPrompt,
});

/// One `fa hub <verb>` handler: the flags after the verb word plus the
/// injected deps.
typedef HubSubcommand =
    Future<int> Function(List<String> flags, HubServeDeps deps);

/// The `fa hub` verb table — `serve` today. A map (not a switch) keeps
/// the dispatcher branch-free and each verb a one-line entry.
final Map<String, HubSubcommand> hubSubcommands = {'serve': _hubServe};

/// Runs the `hub` command; returns the process exit code.
Future<int> runHubCommand(
  List<String> args, {
  Map<String, String>? environment,
  String? home,
  Future<void> Function(LocalHub hub, File pidFile)? serveLoop,
  Future<String?> Function(File stateFile)? secretPrompt,
}) async {
  final verb = args.isEmpty ? null : hubSubcommands[args.first];
  if (verb == null) {
    stderr.writeln('usage: fa hub serve [--port N] [--secret S] [--bind lan]');
    return 1;
  }
  return verb(args.sublist(1), (
    environment: environment,
    home: home,
    serveLoop: serveLoop,
    secretPrompt: secretPrompt,
  ));
}

/// `fa hub serve`: parse the flags, resolve the master secret, run the
/// hub ([hubServe]).
Future<int> _hubServe(List<String> flags, HubServeDeps deps) async {
  final spec = parseHubServeSpec(flags);
  final stateFile = defaultHubStateFile(
    home: deps.home,
    environment: deps.environment ?? Platform.environment,
  );
  final secret = await resolveHubServeSecret(
    stateFile,
    flagSecret: spec.flagSecret,
    environment: deps.environment,
    prompt: deps.secretPrompt,
  );
  return hubServe(
    spec,
    stateFile: stateFile,
    pidFile: hubPidFileFor(environment: deps.environment, home: deps.home),
    secret: secret,
    serveLoop: deps.serveLoop,
  );
}

/// The parsed `fa hub serve` flags: the [port] (a bad `--port` value
/// keeps the zero-config default, as the old hand-rolled loop did), the
/// `--secret` override and the `--bind` scope (`lan` = all interfaces,
/// issue #402 AC4; anything else = loopback, the default).
typedef HubServeSpec = ({int port, String? flagSecret, String? flagBind});

/// Collapses `--flag value` pairs; later duplicates win (the same
/// sequential-overwrite shape the hand-rolled loop had).
Map<String, String> parseFlagValues(List<String> args) {
  final values = <String, String>{};
  for (var i = 0; i + 1 < args.length; i++) {
    if (!args[i].startsWith('--')) continue;
    values[args[i]] = args[i + 1];
    i++;
  }
  return values;
}

/// Parses `fa hub serve`'s `--port`/`--secret`; unknown flags are
/// ignored, as before.
HubServeSpec parseHubServeSpec(List<String> flags) {
  final values = parseFlagValues(flags);
  return (
    port: int.tryParse(values['--port'] ?? '') ?? defaultHubServePort,
    flagSecret: values['--secret'],
    flagBind: values['--bind'],
  );
}

/// The hub pid/state file: `DAP_HUB_PID_FILE` > `~/.dap/hub.pid` for
/// the effective home.
File hubPidFileFor({Map<String, String>? environment, String? home}) {
  final env = environment ?? Platform.environment;
  return File(
    env[envHubPidFile] ??
        dapHubPidFileFor(home ?? env['HOME'] ?? env['USERPROFILE'] ?? '.'),
  );
}

/// The hub master secret: `--secret` > `DAP_HUB_SECRET` > the
/// persisted hub state > the one-time interactive prompt (first start
/// on a terminal only). [prompt] is the seam; production prompts on
/// the real terminal.
Future<String?> resolveHubServeSecret(
  File stateFile, {
  String? flagSecret,
  Map<String, String>? environment,
  Future<String?> Function(File stateFile)? prompt,
}) {
  final stored = _storedHubSecret(
    stateFile,
    flagSecret: flagSecret,
    environment: environment,
  );
  return _orPromptHubSecret(stored, stateFile, prompt: prompt);
}

String? _storedHubSecret(
  File stateFile, {
  String? flagSecret,
  Map<String, String>? environment,
}) =>
    flagSecret ??
    (environment ?? Platform.environment)[envHubSecret] ??
    readHubStateSecret(stateFile);

/// The prompt applies only when nothing is stored AND the terminal
/// shape allows it ([hubSecretPromptApplies]).
Future<String?> _orPromptHubSecret(
  String? stored,
  File stateFile, {
  Future<String?> Function(File stateFile)? prompt,
}) async {
  if (stored != null || !hubSecretPromptApplies(stateFile)) return stored;
  return await (prompt ?? _promptForHubPassword)(stateFile);
}

/// Whether the one-time password prompt applies: an interactive
/// terminal (a detached hub has none) and no recorded choice yet.
bool hubSecretPromptApplies(File stateFile) =>
    stdin.hasTerminal && !stateFile.existsSync();

/// Serves the hub: idempotent against a live one, pid-state
/// bookkeeping for `fa dap stop`, then the serve loop ([serveLoop] is
/// the seam tests cut short; production blocks until killed).
Future<int> hubServe(
  HubServeSpec spec, {
  required File stateFile,
  required File pidFile,
  String? secret,
  Future<void> Function(LocalHub hub, File pidFile)? serveLoop,
}) async {
  // Idempotent: a second `fa hub serve` against a live hub is a no-op,
  // not a bind error — `/dap start` probes first, but a manual double
  // start should be just as calm.
  if (await hubHealthz(spec.port)) {
    stdout.writeln('DAP hub already running on ws://127.0.0.1:${spec.port}/ws');
    return 0;
  }
  final hub = LocalHub(
    port: spec.port,
    bind: spec.flagBind ?? 'loopback',
    masterSecret: secret,
    stateFile: stateFile,
  );
  try {
    await hub.start();
  } on SocketException catch (error) {
    stderr.writeln(
      'hub: cannot bind 127.0.0.1:${spec.port} ($error) — '
      'something else holds the port',
    );
    return 1;
  }
  // The pid/state file (issue #304): lets `fa dap stop` work from ANY
  // CLI instance (not just the spawner) exactly once, with no zombie
  // pid — the serve loop owns the cleanup on a graceful exit.
  _writePidState(pidFile, pid, spec.port);
  stdout.writeln(
    'DAP hub on ${hub.url}${hub.isProtected ? ' (password-protected)' : ''}',
  );
  if (spec.flagBind == 'lan') {
    // The pairing surface (issue #402 AC4): a LAN peer enters one of
    // these URLs (plus the password) by hand — no scanning magic.
    for (final interface in await NetworkInterface.list()) {
      for (final addr in interface.addresses) {
        if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
        stdout.writeln(
          'LAN: ws://${addr.address}:${hub.url.port}/ws${hub.isProtected ? ' + password' : ''}',
        );
      }
    }
  }
  await (serveLoop ?? _serveUntilKilled)(hub, pidFile);
  return 0;
}

/// The graceful-termination wiring: SIGINT (Ctrl-C) is watched on every
/// host; SIGTERM only where the platform offers it —
/// `ProcessSignal.sigterm.watch()` is "Not available on Windows"
/// (dart:io `ProcessSignal` docs), and listening there raises
/// `SignalException` as an unhandled stream error that kills the hub
/// mid-serve. Windows reaches the same graceful exit via Ctrl-C, and
/// `fa dap stop` hard-terminates the pid (see `defaultDapTerminate`).
///
/// [sigtermWatchable] is the per-platform guard, injectable so tests
/// pin the Windows shape (`false`) on any OS. Returns the live
/// subscriptions — the terminate path cancels them before `exit(0)`.
List<StreamSubscription<ProcessSignal>> watchHubTerminateSignals(
  void Function() onTerminate, {
  bool? sigtermWatchable,
}) {
  final watchSigterm =
      sigtermWatchable ?? (Platform.isLinux || Platform.isMacOS);
  final subscriptions = <StreamSubscription<ProcessSignal>>[
    // Ctrl-C in the foreground still goes through the graceful path —
    // SIGINT is watchable everywhere, Windows included.
    ProcessSignal.sigint.watch().listen((_) => onTerminate()),
  ];
  if (watchSigterm) {
    subscriptions.add(
      ProcessSignal.sigterm.watch().listen((_) => onTerminate()),
    );
  }
  return subscriptions;
}

/// The handler a wired terminate signal runs: the graceful exit,
/// fire-and-forget (the signal stream must not await it).
void Function() hubTerminateHandler(
  LocalHub hub,
  File pidFile,
  List<StreamSubscription<ProcessSignal>> signalSubs, {
  void Function(int code) exitProcess = exit,
}) =>
    () => unawaited(
      hubGracefulExit(hub, pidFile, signalSubs, exitProcess: exitProcess),
    );

/// Wires the terminate signals to [hubTerminateHandler]; returns the
/// live subscriptions so a caller's teardown can cancel them.
List<StreamSubscription<ProcessSignal>> wireHubTerminate(
  LocalHub hub,
  File pidFile, {
  void Function(int code) exitProcess = exit,
}) {
  final signalSubs = <StreamSubscription<ProcessSignal>>[];
  signalSubs.addAll(
    watchHubTerminateSignals(
      hubTerminateHandler(hub, pidFile, signalSubs, exitProcess: exitProcess),
    ),
  );
  return signalSubs;
}

/// Blocks serving until killed: the wired terminate signals run
/// [hubGracefulExit]; nothing else ever completes `done`.
Future<void> _serveUntilKilled(LocalHub hub, File pidFile) async {
  final done = Completer<void>();
  wireHubTerminate(hub, pidFile);
  await done.future; // run until killed
}

/// Graceful termination: cancel the signal watches, stop the server,
/// remove the pid state, and exit 0 (a detached hub has no terminal —
/// signals are how `fa dap stop` reaches it). [exitProcess] is the
/// seam so tests observe instead of dying.
Future<void> hubGracefulExit(
  LocalHub hub,
  File pidFile,
  List<StreamSubscription<ProcessSignal>> signalSubs, {
  void Function(int code) exitProcess = exit,
}) async {
  for (final sub in signalSubs) {
    try {
      await sub.cancel();
    } on Object {
      // A stuck signal subscription never blocks shutdown.
    }
  }
  await hub.stop();
  _clearPidState(pidFile);
  exitProcess(0);
}

void _writePidState(File pidFile, int pid, int port) {
  try {
    if (!pidFile.parent.existsSync()) {
      pidFile.parent.createSync(recursive: true);
    }
    pidFile.writeAsStringSync(
      renderDapLocalHubState((
        pid: pid,
        port: port,
        startedAt: DateTime.now().toUtc().toIso8601String(),
      )),
    );
  } on Object {
    // Best-effort: `fa dap stop` still works via its own probe.
  }
}

void _clearPidState(File pidFile) {
  try {
    if (pidFile.existsSync()) pidFile.deleteSync();
  } on Object {
    // A stuck pid file never blocks shutdown.
  }
}

/// First-start password prompt: the one-button bring-up (`/dap start` or
/// a bare `fa hub serve`) asks ONCE on an interactive terminal; the
/// answer is persisted into the hub state file (0600) so later starts —
/// including detached spawns with no terminal — stop asking. Empty =
/// stay open, and that choice is remembered too (the file exists).
Future<String?> _promptForHubPassword(File stateFile) async {
  stdout.writeln(
    'No hub password set. Anyone on this machine can join an open '
    'loopback hub.',
  );
  stdout.write('Set a hub password (empty = keep it open): ');
  final password = ((await _readHiddenLine()) ?? '').trim();
  await persistHubSecretChoice(stateFile, password);
  return _orNullIfEmpty(password);
}

/// One hidden-input line (echo off), restoring the echo either way.
Future<String?> _readHiddenLine() async {
  try {
    stdin.echoMode = false;
    return stdin.readLineSync();
  } finally {
    stdin.echoMode = true;
    stdout.writeln();
  }
}

/// null for an empty choice (stay open), the choice itself otherwise.
String? _orNullIfEmpty(String choice) => choice.isEmpty ? null : choice;

/// Persists the first-start answer so the prompt never nags twice: a
/// chosen password is stored (0600), an explicit empty choice is
/// recorded as `{"masterSecret": null}`. Best-effort — the in-memory
/// password still serves when persistence fails.
Future<void> persistHubSecretChoice(File stateFile, String password) async {
  try {
    if (!stateFile.parent.existsSync()) {
      stateFile.parent.createSync(recursive: true);
    }
    stateFile.writeAsStringSync(
      jsonEncode({
        'masterSecret': _orNullIfEmpty(password),
        'clients': <String, String>{},
      }),
    );
    if (password.isNotEmpty) {
      await Process.run('chmod', ['600', stateFile.path]);
    }
  } on Object {
    // Persistence is best-effort; the in-memory password still serves.
  }
}

/// Whether a hub already answers `/healthz` on [port] (the idempotent
/// double-start check).
Future<bool> hubHealthz(int port) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
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
