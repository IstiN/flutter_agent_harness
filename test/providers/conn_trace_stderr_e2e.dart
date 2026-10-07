// The stderr half of gh-1395 AC2 (run as a CHILD PROCESS by
// stall_repro_floor_test.dart with FA_CONN_DEBUG=1): one scripted
// alive-but-silent request through the production stack; the [conn-trace]
// lines land on this process's stderr in the pinned order.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/providers/conn_trace_io.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart';
import 'package:http/http.dart';

Future<void> main() async {
  installProviderStallForensics(); // io seams: env + stderr + observed client
  providerTimeoutsOverride = const ProviderTimeoutsOverride(
    connect: Duration(milliseconds: 800),
    streamIdle: Duration(milliseconds: 400),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.bufferOutput = false;
    request.response.headers.contentType = ContentType.parse(
      'text/event-stream',
    );
    request.response.add(utf8.encode('data: {"delta":"first"}\n\n'));
    await request.response.flush();
    await Completer<void>().future; // alive but silent
  });
  final response = await sendProviderRequest(
    sharedProviderHttpClient(),
    Request('POST', Uri.parse('http://127.0.0.1:${server.port}/v1/chat'))
      ..headers['content-type'] = 'application/json'
      ..body = '{"model":"stderr-e2e","stream":true}',
    null,
  );
  final iterator = createSseIterator(response, null);
  try {
    while (await iterator.moveNext()) {}
  } on TimeoutException {
    // expected — the idle watchdog's fire IS the trace's last line
  }
  server.close(force: true);
}
