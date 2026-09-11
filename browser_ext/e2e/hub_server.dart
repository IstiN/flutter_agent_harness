/// Standalone DAP/1 hub for the Playwright e2e: the Dart FakeHub (the same
/// in-memory hub the VM integration tests use) bound to an ephemeral
/// loopback port, with a JSON-lines control protocol on stdout so the Node
/// spec can watch the wire.
///
/// Protocol (one JSON object per line):
///   → {"type":"ready","url":"ws://127.0.0.1:PORT/ws"}     (first line)
///   → {"type":"hello","agentId":"…"}                       (welcome sent)
///   → {"type":"relayed","frame":{…}}                       (a DM was routed)
///   → {"type":"delivered","to":"…"}                        (msg delivered)
/// The process exits when stdin closes (the spec kills it in afterAll).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../test/hub/fake_hub.dart';

Future<void> main() async {
  // DAP_E2E_HUB_SECRET — stand the hub up PASSWORD-PROTECTED (the spec
  // sets it for the protected-join tests). Never echoed back: the ready
  // line only reports THAT it is protected.
  final secret = Platform.environment['DAP_E2E_HUB_SECRET'];
  final hub = FakeHub(masterSecret: secret);
  await hub.start();
  stdout.writeln(
    jsonEncode({
      'type': 'ready',
      'url': hub.url.toString(),
      'protected': secret != null && secret.isNotEmpty,
    }),
  );

  var hellosSeen = 0;
  var relayedSeen = 0;
  var deliveredSeen = 0;
  var agentsSeen = 0;
  final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final agents = hub.agentIds;
    for (; agentsSeen < agents.length; agentsSeen++) {
      stdout.writeln(
        jsonEncode({'type': 'agent', 'agentId': agents[agentsSeen]}),
      );
    }
    for (; relayedSeen < hub.relayed.length; relayedSeen++) {
      stdout.writeln(
        jsonEncode({'type': 'relayed', 'frame': hub.relayed[relayedSeen]}),
      );
    }
    for (; deliveredSeen < hub.deliveredTo.length; deliveredSeen++) {
      stdout.writeln(
        jsonEncode({'type': 'delivered', 'to': hub.deliveredTo[deliveredSeen]}),
      );
    }
    for (; hellosSeen < hub.hellosSeen; hellosSeen++) {
      stdout.writeln(jsonEncode({'type': 'hello'}));
    }
  });

  // The spec kills the process; stdin close is the graceful path.
  await stdin.drain<void>();
  ticker.cancel();
  await hub.stop();
}
