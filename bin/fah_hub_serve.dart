/// `fa hub serve [--port N] [--secret S]` — runs a local DAP/1 hub
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

/// The well-known zero-config port (mirrors the client default
/// `ws://127.0.0.1:8787/ws`).
const defaultHubServePort = 8787;

/// Runs the `hub` subcommand; returns the process exit code.
Future<int> runHubCommand(List<String> args) async {
  if (args.isEmpty || args.first != 'serve') {
    stderr.writeln('usage: fa hub serve [--port N] [--secret S]');
    return 1;
  }
  var port = defaultHubServePort;
  String? flagSecret;
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[++i]) ?? port;
    } else if (args[i] == '--secret' && i + 1 < args.length) {
      flagSecret = args[++i];
    }
  }
  final stateFile = defaultHubStateFile();
  var secret =
      flagSecret ??
      Platform.environment[envHubSecret] ??
      readHubStateSecret(stateFile);
  if (secret == null && stdin.hasTerminal && !stateFile.existsSync()) {
    secret = await _promptForHubPassword(stateFile);
  }
  // Idempotent: a second `fa hub serve` against a live hub is a no-op,
  // not a bind error — `/dap start` probes first, but a manual double
  // start should be just as calm.
  if (await _healthz(port)) {
    stdout.writeln('DAP hub already running on ws://127.0.0.1:$port/ws');
    return 0;
  }
  final hub = LocalHub(port: port, masterSecret: secret, stateFile: stateFile);
  try {
    await hub.start();
  } on SocketException catch (error) {
    stderr.writeln(
      'hub: cannot bind 127.0.0.1:$port ($error) — '
      'something else holds the port',
    );
    return 1;
  }
  stdout.writeln(
    'DAP hub on ${hub.url}${hub.isProtected ? ' (password-protected)' : ''}',
  );
  await Completer<void>().future; // run until killed
  return 0;
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
  String? line;
  try {
    stdin.echoMode = false;
    line = stdin.readLineSync();
  } finally {
    stdin.echoMode = true;
    stdout.writeln();
  }
  final password = line?.trim() ?? '';
  try {
    if (!stateFile.parent.existsSync()) {
      stateFile.parent.createSync(recursive: true);
    }
    // A chosen password is stored; an explicit empty choice is recorded
    // as {"masterSecret": null} so the prompt never nags twice.
    stateFile.writeAsStringSync(
      jsonEncode({
        'masterSecret': password.isEmpty ? null : password,
        'clients': <String, String>{},
      }),
    );
    if (password.isNotEmpty) {
      await Process.run('chmod', ['600', stateFile.path]);
    }
  } on Object {
    // Persistence is best-effort; the in-memory password still serves.
  }
  return password.isEmpty ? null : password;
}

Future<bool> _healthz(int port) async {
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
