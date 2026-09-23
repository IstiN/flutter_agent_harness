import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/local_hub.dart';

/// Cap hit then the client STALLS (sends cap+1 byte, then waits).
Future<void> main() async {
  final hub = LocalHub(
    relayAllowAnyHost: true,
    relayMaxBodyBytes: 64 * 1024,
    relayIdleTimeout: const Duration(seconds: 30),
  );
  await hub.start();
  final port = hub.url.port;
  final socket = await Socket.connect('127.0.0.1', port);
  final received = BytesBuilder(copy: false);
  final done = Completer<String>();
  socket.listen((data) {
    received.add(data);
    final s = utf8.decode(received.takeBytes(), allowMalformed: true);
    if (!done.isCompleted && s.contains('\r\n\r\n')) done.complete(s);
  }, onDone: () {
    if (!done.isCompleted) done.complete(utf8.decode(received.takeBytes(), allowMalformed: true));
  }, onError: (Object _) {});
  socket.write(
    'POST /relay HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Authorization: Bearer ${hub.relaySecret}\r\n'
    'Content-Type: application/json\r\n'
    'Transfer-Encoding: chunked\r\n\r\n',
  );
  // 65 KiB in ONE chunk (crosses the 64 KiB cap immediately), then stall.
  final big = List.filled(66 * 1024, 'x').join();
  socket.write('${big.length.toRadixString(16)}\r\n$big\r\n');
  final sw = Stopwatch()..start();
  final head = await done.future.timeout(const Duration(seconds: 8), onTimeout: () {
    stderr.writeln('no answer in 8s');
    return '';
  });
  stderr.writeln('answer @${sw.elapsedMilliseconds}ms: ${head.isEmpty ? '(nothing, socket closed)' : head.split('\r\n').first}');
  socket.destroy();
  await hub.stop();
}
