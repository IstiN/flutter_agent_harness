// e2e-only bridge server runner (issue #34 item 2): the playwright
// residency spec spawns this instead of reimplementing the wire protocol in
// node — same BridgeServer class `fa serve --bridge` uses.
//
// Usage: dart run browser_ext/e2e/bridge_server.dart <projectRoot> [port]
// Prints one ready line `{"url": …, "token": …}` (JSON) once listening, then
// blocks until killed. A fixed port + persistent root make restarts
// reconnectable: the token file at <root>/.fah/bridge/token survives.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';

import '../../bin/serve_bridge.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: bridge_server.dart <projectRoot> [port]');
    exitCode = 2;
    return;
  }
  final root = args[0];
  final port = args.length > 1 ? int.parse(args[1]) : 0;

  // Real fabric layout: <root>/proj/messages (never a bare <root>/messages —
  // the session root would swallow unrelated /tmp entries).
  final repo = FileMessagingRepository(
    env: LocalExecutionEnv(cwd: root),
    root: '$root/proj/messages',
  );
  final token = await BridgeTokenFile(root).ensure();
  final server = BridgeServer(
    messaging: repo,
    root: root,
    token: token,
    port: port,
    // Fast timers: the spec's wall time is dominated by Chrome, not here.
    pollInterval: const Duration(milliseconds: 40),
    heartbeatInterval: const Duration(milliseconds: 60),
    dispatchTimeout: const Duration(seconds: 2),
  );
  await server.start();
  stdout.writeln(jsonEncode({'url': server.url, 'token': server.token}));
  await stdout.flush();
  await server.done; // block until the process is killed
}
