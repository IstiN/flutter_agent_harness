// StallSentinel (gh-1395 AC3): on watchdog fire, the outbound payload of
// the silent request is dumped to the trial dir BEFORE the abort lands,
// byte-identically replayable via scripts/replay_hang.sh (same stall
// signature → exit 2).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/providers/conn_trace.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart';
import 'package:flutter_agent_harness/src/providers/stall_sentinel.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('dump serialization (UT)', () {
    late Directory trial;
    setUp(() {
      trial = Directory.systemTemp.createTempSync('sentinel-ut');
      stallDumpDirectoryOverride = trial.path;
      connTraceOverride = false;
      resetConnTraceForTest();
    });
    tearDown(() {
      stallDumpDirectoryOverride = null;
      trial.deleteSync(recursive: true);
    });

    test('payload bytes byte-identical; auth header masked in meta', () async {
      final body = utf8.encode(
        '{"model":"t","messages":[{"role":"user","content":"secret-turn"}]}',
      );
      final record = stallRecordOfRequest(
        http.Request('POST', Uri.parse('https://gw.test/v1/chat'))
          ..headers['authorization'] = 'Bearer sk-live-9999'
          ..headers['content-type'] = 'application/json'
          ..bodyBytes = body,
      );
      final file = await dumpStalledRequest(
        record: record,
        watchdog: 'stream-idle',
        idleTimeout: const Duration(seconds: 300),
      );
      expect(file, isNotNull);
      final metaFile = file!;
      // The dump carries payload.bin (byte-identical body) + meta.json.
      final payload = File(
        '${metaFile.parent.path}${Platform.pathSeparator}payload.bin',
      );
      expect(payload.readAsBytesSync(), body);
      final meta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      expect(meta['method'], 'POST');
      expect(meta['url'], 'https://gw.test/v1/chat');
      expect(meta['watchdog'], 'stream-idle');
      expect(meta['bodySha256'], isNotEmpty);
      final headers = meta['headers'] as Map<String, dynamic>;
      expect(headers['authorization'], isNot(contains('sk-live-9999')));
      expect(headers['authorization'], contains('REDACTED'));
      expect(headers['content-type'], 'application/json');
    });

    test(
      'no record (unwrapped client): metadata-only dump, never throws',
      () async {
        final file = await dumpStalledRequest(
          record: null,
          watchdog: 'stream-idle',
          idleTimeout: const Duration(seconds: 5),
        );
        expect(file, isNotNull);
        final meta =
            jsonDecode(await file!.readAsString()) as Map<String, dynamic>;
        expect(meta['payload'], 'unavailable');
        expect(meta['watchdog'], 'stream-idle');
      },
    );

    test(
      'the dump line is emitted even with the trace off (AC3 signal)',
      () async {
        final events = <ConnTraceEvent>[];
        connTraceSink = events.add;
        await dumpStalledRequest(
          record: stallRecordOfRequest(
            http.Request('POST', Uri.parse('https://gw.test/v1')),
          ),
          watchdog: 'connect',
          idleTimeout: const Duration(seconds: 180),
        );
        expect(events.map((e) => e.kind), contains(ConnTraceKind.stallDumped));
        expect(events.last.line, startsWith('stall payload dumped to '));
        connTraceSink = null;
      },
    );
  });

  group('AC3 IT — dump before abort on the production stack', () {
    late HttpServer server;
    late Directory trial;
    late Completer<void> holdOpen;

    setUp(() {
      trial = Directory.systemTemp.createTempSync('sentinel-it');
      stallDumpDirectoryOverride = trial.path;
      connTraceOverride = null; // the production path, knob unset
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(milliseconds: 800),
        streamIdle: Duration(milliseconds: 300),
      );
    });
    tearDown(() async {
      providerTimeoutsOverride = null;
      stallDumpDirectoryOverride = null;
      server.close(force: true);
      trial.deleteSync(recursive: true);
    });

    Future<Uri> startSilentServer() async {
      holdOpen = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType.parse(
          'text/event-stream',
        );
        request.response.add(utf8.encode('data: {"delta":"first"}\n\n'));
        await request.response.flush();
        await holdOpen.future; // alive but silent from here on
      });
      return Uri.parse('http://127.0.0.1:${server.port}/v1/chat');
    }

    test('idle watchdog fire dumps the outbound payload first', () async {
      final url = await startSilentServer();
      final response = await sendProviderRequest(
        sharedProviderHttpClient(),
        http.Request('POST', url)
          ..headers['content-type'] = 'application/json'
          ..body = '{"model":"sentinel-it","stream":true}',
        null,
      );
      final iterator = createSseIterator(response, null);
      Object? failure;
      try {
        while (await iterator.moveNext()) {}
      } on TimeoutException catch (e) {
        failure = e;
      }
      expect(failure, isNotNull, reason: 'the idle watchdog must fire');
      await pumpEventQueue();
      final dumps = trial
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('meta.json'));
      expect(dumps, isNotEmpty, reason: 'the dump exists once the abort lands');
      final meta =
          jsonDecode(dumps.first.readAsStringSync()) as Map<String, dynamic>;
      expect(meta['watchdog'], 'stream-idle');
      expect(meta['bodySha256'], isNotEmpty);
      final payload = File(
        '${dumps.first.parent.path}${Platform.pathSeparator}payload.bin',
      );
      expect(utf8.decode(payload.readAsBytesSync()), contains('"sentinel-it"'));
    });
  });

  group('replay script — byte-identical replay, same stall signature', () {
    late Directory trial;
    setUp(() {
      trial = Directory.systemTemp.createTempSync('sentinel-replay');
      stallDumpDirectoryOverride = trial.path;
    });
    tearDown(() {
      stallDumpDirectoryOverride = null;
      trial.deleteSync(recursive: true);
    });

    Future<Uri> startServer(bool wedged) async {
      final completer = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!wedged) {
          request.response.add(utf8.encode('data: {"delta":"ok"}\n\n'));
          await request.response.close();
          return;
        }
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType.parse(
          'text/event-stream',
        );
        request.response.add(utf8.encode('data: {"delta":"first"}\n\n'));
        await request.response.flush();
        await completer.future;
      });
      return Uri.parse('http://127.0.0.1:${server.port}/v1/chat');
    }

    Future<(File, Uri)> dumpAgainst(Uri url) async {
      final file = await dumpStalledRequest(
        record: stallRecordOfRequest(
          http.Request('POST', url)
            ..headers['content-type'] = 'application/json'
            ..body = '{"model":"replay-it","stream":true}',
        ),
        watchdog: 'stream-idle',
        idleTimeout: const Duration(seconds: 1),
      );
      // Point the meta at the live server before replaying.
      final meta =
          jsonDecode(await file!.readAsString()) as Map<String, dynamic>;
      meta['url'] = url.toString();
      await file.writeAsString(jsonEncode(meta));
      return (file, url);
    }

    test('wedged endpoint → exit 2 (stall signature)', () async {
      final url = await startServer(true);
      final (dump, _) = await dumpAgainst(url);
      final result = await Process.run('bash', [
        'scripts/replay_hang.sh',
        dump.path,
      ]);
      // ignore: avoid_print
      print(
        'replay wedged: ${result.exitCode} ${result.stdout} '
        '${result.stderr}',
      );
      expect(result.exitCode, 2, reason: 'the stall signature reproduces');
      expect(result.stdout, contains('stalled'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('healthy endpoint → exit 0 (stall exonerated downstream)', () async {
      final url = await startServer(false);
      final (dump, _) = await dumpAgainst(url);
      final result = await Process.run('bash', [
        'scripts/replay_hang.sh',
        dump.path,
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('replayed'));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
