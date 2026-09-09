/// `fa hub serve [--port N]` — runs a local DAP/1 hub
/// (`package:flutter_agent_harness/io.dart` `LocalHub`, docs/dap.md §8.1)
/// in the foreground until killed. `/dap start` spawns this detached so
/// the hub outlives the CLI that launched it; other zero-config clients
/// (the default URL is `ws://127.0.0.1:8787/ws`) find it on their own.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart';

/// The well-known zero-config port (mirrors the client default
/// `ws://127.0.0.1:8787/ws`).
const defaultHubServePort = 8787;

/// Runs the `hub` subcommand; returns the process exit code.
Future<int> runHubCommand(List<String> args) async {
  if (args.isEmpty || args.first != 'serve') {
    stderr.writeln('usage: fa hub serve [--port N]');
    return 1;
  }
  var port = defaultHubServePort;
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[++i]) ?? port;
    }
  }
  // Idempotent: a second `fa hub serve` against a live hub is a no-op,
  // not a bind error — `/dap start` probes first, but a manual double
  // start should be just as calm.
  if (await _healthz(port)) {
    stdout.writeln('DAP hub already running on ws://127.0.0.1:$port/ws');
    return 0;
  }
  final hub = LocalHub(port: port);
  try {
    await hub.start();
  } on SocketException catch (error) {
    stderr.writeln(
      'hub: cannot bind 127.0.0.1:$port ($error) — '
      'something else holds the port',
    );
    return 1;
  }
  stdout.writeln('DAP hub on ${hub.url}');
  await Completer<void>().future; // run until killed
  return 0;
}

Future<bool> _healthz(int port) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final response = await (await client.get('127.0.0.1', port, '/healthz'))
        .close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } on Object {
    return false;
  }
}
