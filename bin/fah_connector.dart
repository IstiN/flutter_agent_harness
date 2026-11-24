part of 'fah.dart';

/// `fa connector run|status|stop` — single-per-machine Machine Connector daemon
/// (`docs/fa_network_connector.md` §3 / §10).
///
/// One daemon owns the single upstream WebSocket to `fa_network` for this
/// enrolled `deviceId` and multiplexes every local CLI session and desktop app
/// process over loopback (`~/.fah/network/connector.json`).
Future<int> _runConnectorCommand(List<String> args) async {
  final verb = args.isEmpty ? 'status' : args.first;
  switch (verb) {
    case 'run':
      return _runConnectorDaemon(args.sublist(1));
    case 'status':
      return _connectorDaemonStatus();
    case 'stop':
      return _stopConnectorDaemon();
    default:
      stderr.writeln('usage: fa connector run|status|stop [--port N]');
      return 64;
  }
}

Future<int> _runConnectorDaemon(List<String> args) async {
  var port = 0;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[++i]) ?? 0;
    }
  }
  final home = _homeDir();
  final store = FileNetworkCredentialStore(home);
  final device = await store.readDevice();
  if (device == null) {
    stderr.writeln('fa connector: device not enrolled; run fa network enroll');
    return 1;
  }
  final stateFile = connectorDaemonStateFile(home);
  final existing = await readConnectorDaemonState(stateFile);
  if (existing != null &&
      await probeConnectorDaemon(existing, expectedDeviceId: device.deviceId)) {
    stdout.writeln(
      'fa connector already running (pid=${existing.pid} port=${existing.port})',
    );
    return 0;
  }

  final baseUrl = _networkRelayBaseUrl();
  final httpClient = http.Client();
  final devices = DeviceEnrollmentClient(httpClient: httpClient);
  final env = LocalExecutionEnv(cwd: Directory.current.path);
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: _defaultSessionRoot());
  final host = MultiSessionConnectorHost(
    device: device,
    baseUrl: baseUrl,
    ticketProvider: () =>
        devices.wsTicket(baseUrl: baseUrl, deviceToken: device.deviceToken),
    transport: const IoConnectorTransport(),
    rosterClient: devices,
    catalogStore: JsonlSessionCatalogStore(repo: repo),
    dmKeyStore: store,
    wakeLauncher: ({required cwd, required sessionId, sessionName}) =>
        launchMailboxWake(
          env: env,
          cwd: cwd,
          sessionId: sessionId,
          sessionName: sessionName,
          wakeExecutable: wakeExecutable(),
        ),
  );
  final server = ConnectorDaemonServer(
    host: host,
    stateFile: stateFile,
    port: port,
  );
  await server.start();
  stdout.writeln(
    'fa connector listening on 127.0.0.1:${server.boundPort} '
    '(pid=$pid device=${device.deviceId})',
  );
  final done = Completer<void>();
  StreamSubscription<ProcessSignal>? sigInt;
  StreamSubscription<ProcessSignal>? sigTerm;
  void shutdown(ProcessSignal _) {
    if (!done.isCompleted) done.complete();
  }

  sigInt = ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    sigTerm = ProcessSignal.sigterm.watch().listen(shutdown);
  }
  await done.future;
  await sigInt.cancel();
  await sigTerm?.cancel();
  await server.stop();
  httpClient.close();
  return 0;
}

Future<int> _connectorDaemonStatus() async {
  final stateFile = connectorDaemonStateFile(_homeDir());
  final state = await readConnectorDaemonState(stateFile);
  if (state == null || !await probeConnectorDaemon(state)) {
    stdout.writeln('fa connector: stopped');
    return 1;
  }
  stdout.writeln(
    'fa connector: running (pid=${state.pid} port=${state.port} '
    'device=${state.deviceId})',
  );
  return 0;
}

Future<int> _stopConnectorDaemon() async {
  final stateFile = connectorDaemonStateFile(_homeDir());
  final state = await readConnectorDaemonState(stateFile);
  if (state == null || !await probeConnectorDaemon(state)) {
    stdout.writeln('fa connector: already stopped');
    return 0;
  }
  Process.killPid(state.pid);
  stdout.writeln('fa connector: stopped (pid=${state.pid})');
  return 0;
}

/// Ensures the single per-machine `fa connector run` daemon is alive, spawning
/// a detached background instance when none is running, and returns its state.
Future<ConnectorDaemonState?> _ensureConnectorDaemonRunning({
  required String homeDirectory,
  required String deviceId,
}) async {
  final stateFile = connectorDaemonStateFile(homeDirectory);
  final existing = await readConnectorDaemonState(stateFile);
  if (existing != null &&
      await probeConnectorDaemon(existing, expectedDeviceId: deviceId)) {
    return existing;
  }
  final exe = wakeExecutable();
  if (exe == null || exe.isEmpty) return null;
  try {
    await Process.start(exe, const [
      'connector',
      'run',
    ], mode: ProcessStartMode.detached);
  } on Object {
    return null;
  }
  // Wait briefly for the spawned daemon to bind loopback and write its state.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final state = await readConnectorDaemonState(stateFile);
    if (state != null &&
        await probeConnectorDaemon(state, expectedDeviceId: deviceId)) {
      return state;
    }
  }
  return null;
}
