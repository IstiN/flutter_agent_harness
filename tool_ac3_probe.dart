import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/local_hub.dart';

Future<void> main() async {
  final hub = LocalHub(relayAllowAnyHost: true, relayIdleTimeout: const Duration(seconds: 30));
  await hub.start();
  final port = hub.url.port;

  // SSE upstream: chunk every 100ms, forever.
  final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var upstreamDied = Completer<void>();
  upstream.forEach((req) {
    unawaited(() async {
      req.response.bufferOutput = false;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      try {
        for (var i = 0;; i++) {
          req.response.write('data: chunk-$i\n\n');
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } on Object {
        if (!upstreamDied.isCompleted) upstreamDied.complete();
      }
    }());
  });

  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/relay'));
  req.headers.contentType = ContentType.json;
  req.headers.set('Authorization', 'Bearer ${hub.relaySecret}');
  req.write(jsonEncode({'url': 'http://127.0.0.1:${upstream.port}/x'}));
  final res = await req.close();
  var chunks = 0;
  res.listen((_) => chunks++, onError: (Object _) {}, cancelOnError: false);

  await Future<void>.delayed(const Duration(seconds: 1));
  stderr.writeln('client force-closing after $chunks chunks...');
  client.close(force: true);

  for (var s = 1; s <= 5; s++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    stderr.writeln('t+${s}s: relayUpstreamAborts=${hub.relayUpstreamAborts} '
        'inFlight=${hub.relayInFlight} upstreamDied=${upstreamDied.isCompleted}');
  }
  stderr.writeln('RESULT: aborts=${hub.relayUpstreamAborts} died=${upstreamDied.isCompleted}');
  await hub.stop();
  await upstream.close(force: true);
}
