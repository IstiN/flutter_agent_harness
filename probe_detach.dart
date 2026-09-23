import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal dart:io question: does HttpResponse.detachSocket() let us
/// hand-write an answer when the request body was never consumed (and
/// the client keeps pumping / then stalls)?
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(server.forEach((req) async {
    // NOT reading the body. Try the raw answer.
    try {
      final raw = await req.response.detachSocket();
      raw.write(
        'HTTP/1.1 413 Payload Too Large\r\n'
        'Content-Length: 21\r\nConnection: close\r\n\r\n'
        '{"error":"raw answer"}',
      );
      await raw.flush();
      await raw.close();
      stderr.writeln('detach+write OK');
    } on Object catch (e) {
      stderr.writeln('detach+write FAILED: $e');
      try {
        await req.response.close();
      } on Object {}
    }
  }));
  final port = server.port;

  // Client A: keeps pumping past the cap.
  final a = await Socket.connect('127.0.0.1', port);
  final aGot = BytesBuilder(copy: false);
  final aDone = Completer<String>();
  a.listen((d) {
    aGot.add(d);
    if (!aDone.isCompleted) {
      aDone.complete(utf8.decode(aGot.takeBytes(), allowMalformed: true));
    }
  }, onDone: () {
    if (!aDone.isCompleted) aDone.complete('');
  }, onError: (Object _) {});
  a.write('POST /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n');
  final chunk = List.filled(32 * 1024, 'x').join();
  final pump = Timer.periodic(const Duration(milliseconds: 10), (t) {
    try {
      a.write('${chunk.length.toRadixString(16)}\r\n$chunk\r\n');
    } on Object {
      t.cancel();
    }
  });
  final ra = await aDone.future.timeout(const Duration(seconds: 3), onTimeout: () => '(timeout)');
  stderr.writeln('PUMPING client answer: ${ra.isEmpty ? '(nothing, closed)' : ra.split('\r\n').first}');
  pump.cancel();
  a.destroy();

  // Client B: declares Content-Length, sends 100 of 100000 bytes, stalls.
  final b = await Socket.connect('127.0.0.1', port);
  final bGot = BytesBuilder(copy: false);
  final bDone = Completer<String>();
  b.listen((d) {
    bGot.add(d);
    if (!bDone.isCompleted) {
      bDone.complete(utf8.decode(bGot.takeBytes(), allowMalformed: true));
    }
  }, onDone: () {
    if (!bDone.isCompleted) bDone.complete('');
  }, onError: (Object _) {});
  b.write('POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 100000\r\n\r\n');
  b.write('{"url":"x');
  final rb = await bDone.future.timeout(const Duration(seconds: 3), onTimeout: () => '(timeout)');
  stderr.writeln('STALLED client answer: ${rb.isEmpty ? '(nothing, closed)' : rb.split('\r\n').first}');
  b.destroy();
  await server.close(force: true);
}
