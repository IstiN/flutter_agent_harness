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
  final received = BytesBuilder(copy: false);
  final done = Completer<String>();
  socket.listen((data) {
    received.add(data);
    final s = utf8.decode(received.takeBytes(), allowMalformed: true);
    stderr.writeln('RECV @${s.length}B');
    if (!done.isCompleted && s.contains('\r\n\r\n')) {
      done.complete(s);
    }
  }, onDone: () {
    stderr.writeln('SOCKET CLOSED by hub');
    if (!done.isCompleted) done.complete(utf8.decode(received.takeBytes(), allowMalformed: true));
  }, onError: (Object e) {
    stderr.writeln('socket error: $e');
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

  var sent = 0;
  final pump = Timer.periodic(const Duration(milliseconds: 20), (t) {
    if (sent >= totalChunks) {
      socket.write('2\r\n"}\r\n0\r\n\r\n');
      t.cancel();
      return;
    }
    try {
      httpChunk(payload);
      sent++;
    } on Object catch (e) {
      stderr.writeln('pump stopped at chunk $sent: $e');
      t.cancel();
    }
  });

  final sw = Stopwatch()..start();
  final headStr = await done.future.timeout(const Duration(seconds: 10),
      onTimeout: () {
    stderr.writeln('NO ANSWER within 10s');
    return '';
  });
  stderr.writeln(
      'answer @${sw.elapsedMilliseconds}ms status=${headStr.isEmpty ? '(none)' : headStr.split('\r\n').first}');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  pump.cancel();
  socket.destroy();
  await hub.stop();
}
