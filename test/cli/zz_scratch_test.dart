import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:test/test.dart';

import '../../bin/self_manage.dart';

void main() {
  const chunk = 409600;
  const archiveUrl =
      'https://github.com/IstiN/flutter_agent_harness/releases/'
      'download/v9.9.9/fa-test.tar.gz';

  List<int> filler(int size, [int seed = 0]) =>
      List<int>.generate(size, (i) => (i + seed) & 0xFF);

  Stream<List<int>> resetsAfter(List<List<int>> chunks) async* {
    for (final piece in chunks) {
      yield piece;
    }
    throw http.ClientException('connection closed while receiving');
  }

  test('scratch: bounded trace', () async {
    var requests = 0;
    final client = MockClient.streaming((request, _) async {
      requests++;
      stdout.writeln('--- request $requests: range=${request.headers['range']}');
      return http.StreamedResponse(
        resetsAfter([filler(chunk)]),
        200,
        contentLength: chunk * 99,
      );
    });
    final lines = <String>[];
    final outcome = await downloadArchiveBody(
      client,
      Uri.parse(archiveUrl),
      log: lines.add,
      stallTimeout: const Duration(seconds: 5),
      maxResumeAttempts: 3,
    );
    stdout.writeln('requests=$requests ok=${outcome.ok}');
    stdout.writeln('msg=${outcome.failureMessage}');
    for (final l in lines) {
      stdout.writeln('log: $l');
    }
  });
}
