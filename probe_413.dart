import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/local_hub.dart';

Future<void> main() async {
  final hub = LocalHub(
    relayAllowAnyHost: true,
    relayMaxBodyBytes: 64 * 1024,
    relayIdleTimeout: const Duration(seconds: 30),
  );
  await hub.start();
  final port = hub.url.port;
  const chunkPayloadLen = 32 * 1024;
  final payload = List.filled(chunkPayloadLen, 'x').join();
  const prefix = '{"url":"http://127.0.0.1:1/x","pad":"';
  const totalChunks = (4 * 1024 * 1024) ~/ chunkPayloadLen;

  final socket = await Socket.connect('127.0.0.1', port);
  final answer = Completer<String>();
  final head = StringBuffer();
  var inBody = false;
  socket.listen((data) {
    final s = utf8.decode(data);
    if (!inBody) {
      head.write(s);
      if (head.toString().contains('\r\n\r\n')) {
        inBody = true;
        if (!answer.isCompleted) answer.complete(head.toString());
      }
    }
  }, onError: (Object _) {}, onDone: () {
    if (!answer.isCompleted) answer.complete(head.toString());
  });

  socket.write(
    'POST /relay HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Authorization: Bearer ${hub.relaySecret}\r\n'
    'Content-Type: application/json\r\n'
    'Transfer-Encoding: chunked\r\n\r\n',
  );
  void httpChunk(String s) =>
      socket.write('${s.length.toRadixString(16)}\r\n$s\r\n');
  httpChunk(prefix);

  final sw = Stopwatch()..start();
  var sent = 0;
  var uploadDone = false;
  var freedAtMs = -1;
  final poll = Timer.periodic(const Duration(milliseconds: 10), (t) {
    if (freedAtMs < 0 && hub.relayInFlight == 0) {
      freedAtMs = sw.elapsedMilliseconds;
      stderr.writeln(
        'worker freed at ${sw.elapsedMilliseconds} ms '
        '(uploadDone=$uploadDone, chunksSent=$sent/$totalChunks)',
      );
      t.cancel();
    }
  });
  final pump = Timer.periodic(const Duration(milliseconds: 20), (t) {
    if (sent >= totalChunks) {
      socket.write('2\r\n"}\r\n0\r\n\r\n');
      uploadDone = true;
      t.cancel();
      return;
    }
    httpChunk(payload);
    sent++;
  });

  final headStr = await answer.future.timeout(const Duration(seconds: 20));
  stderr.writeln(
    'answer head at ${sw.elapsedMilliseconds} ms: '
    '${headStr.split('\r\n').first} '
    '(uploadDone=$uploadDone, chunksSent=$sent/$totalChunks)',
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
  poll.cancel();
  pump.cancel();
  socket.destroy();
  await hub.stop();
}
