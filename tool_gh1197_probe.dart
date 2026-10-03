// gh-1197 reproduction probe v2 (temporary, not committed).
// Local SSE fake provider streams PACED reasoning/text deltas (the real
// streaming shape) + bash tool calls; the probe samples PTY output bytes
// and reports any gap > 5s while the run is still in flight (fa.log busy).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

final _requestLog = <String>[];

Future<HttpServer> _startServer(int port) async {
  var served = 0;
  final server = await HttpServer.bind('127.0.0.1', port);
  server.listen((req) async {
      if (req.uri.path.endsWith('/chat/completions')) {
        final index = served++;
        _requestLog.add('req#$index');
        req.response.headers
          ..contentType = ContentType('text', 'event-stream')
          ..set('Cache-Control', 'no-cache');
        final sink = req.response;
        Future<void> chunk(Map<String, dynamic> json) async {
          sink.write('data: ${jsonEncode(json)}\n\n');
          await sink.flush();
        }

        Future<void> paced(String field, String text, Duration pace,
            {int chunkChars = 12}) async {
          for (var i = 0; i < text.length; i += chunkChars) {
            final piece = text.substring(
              i,
              (i + chunkChars).clamp(0, text.length),
            );
            await chunk({
              'choices': [
                {'delta': {field: piece}, 'finish_reason': null},
              ],
            });
            await Future<void>.delayed(pace);
          }
        }

        try {
          if (index >= 9) {
            // Final turn: a thinking burst (~3s paced), then a text answer.
            await paced(
              'reasoning_content',
              'Wrapping up the run. ' * 60,
              const Duration(milliseconds: 25),
            );
            await paced(
              'content',
              'Final answer: the essay concludes here with prose. ' * 40,
              const Duration(milliseconds: 20),
            );
            await chunk({
              'choices': [
                {'delta': {}, 'finish_reason': 'stop'},
              ],
            });
          } else {
            // A bash tool call (3s sleep) per turn until the last.
            await paced(
              'reasoning_content',
              'Running the probe tool for step $index. ' * 10,
              const Duration(milliseconds: 25),
            );
            await chunk({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_$index',
                        'type': 'function',
                        'function': {'name': 'bash', 'arguments': ''},
                      },
                    ],
                  },
                  'finish_reason': null,
                },
              ],
            });
            await chunk({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'function': {
                          'arguments': '{"command": "sleep 3 && echo step-$index"}',
                        },
                      },
                    ],
                  },
                  'finish_reason': null,
                },
              ],
            });
            await chunk({
              'choices': [
                {'delta': {}, 'finish_reason': 'tool_calls'},
              ],
            });
          }
          sink.write('data: [DONE]\n\n');
          await sink.flush();
          await sink.close();
        } on Object {
          // client gone — nothing to serve
        }
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  return server;
}

Future<void> main(List<String> args) async {
  final server = await _startServer(18119);
  final home = await Directory('/tmp').createTemp('fa1197h');
  final project = await Directory('/tmp').createTemp('fa1197p');
  File('${home.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('tui:\n  classic: true\n');

  final env = <String, String>{
    'TERM': 'xterm-256color',
    'HOME': home.path,
    'FA_PROVIDER_TYPE': 'openai',
    'FA_PROVIDER_CONFIG': jsonEncode({
      'baseUrl': 'http://127.0.0.1:18119/v1',
      'model': 'fake-paced',
    }),
    'FA_KEY_127.0.0.1': 'test-key',
    'DAP_HUB_URL': 'ws://127.0.0.1:1/ws',
    'DAP_LOCAL_HUB_URL': 'ws://127.0.0.1:1/ws',
  };

  final pty = PseudoTerminal.start(
    'dart',
    ['${Directory.current.path}/bin/fah.dart', '--session', 'pty1197'],
    workingDirectory: project.path,
    environment: env,
    raw: true,
  );
  pty.resize(80, 24);
  final terminal = Terminal(maxLines: 400);
  final chunkLog = File('/tmp/gh1197_chunks.log').openWrite();
  final rawSink = File('/tmp/gh1197_raw.log').openWrite();
  final sw = Stopwatch()..start();
  var received = 0;
  pty.out.listen((text) {
    received += text.length;
    chunkLog.writeln('${sw.elapsedMilliseconds}\t${text.length}');
    rawSink.write(text);
    terminal.write(text);
  });
  terminal.onOutput = pty.write;

  // Wait for boot bytes, then submit.
  final bootDeadline = DateTime.now().add(const Duration(seconds: 90));
  while (received == 0 && DateTime.now().isBefore(bootDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  pty.write('write the essay');
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final submitAt = sw.elapsedMilliseconds;
  pty.write('\r');
  stdout.writeln('submitted at +$submitAt ms');

  // Sample until the process exits or 240s pass.
  final start = DateTime.now();
  final deadline = start.add(const Duration(seconds: 240));
  var lastBytes = 0;
  var lastChangeMs = sw.elapsedMilliseconds;
  var exitCode = -2;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (received != lastBytes) {
      final gapMs = sw.elapsedMilliseconds - lastChangeMs;
      if (gapMs > 5000) {
        stdout.writeln(
          'MID-RUN GAP: ${(gapMs / 1000).toStringAsFixed(1)}s ending at '
          '+${sw.elapsedMilliseconds}ms (+${received - lastBytes} bytes)',
        );
      }
      lastBytes = received;
      lastChangeMs = sw.elapsedMilliseconds;
    }
    exitCode = await pty.exitCode
        .timeout(const Duration(milliseconds: 5), onTimeout: () => -2);
    if (exitCode != -2) {
      stdout.writeln(
        'process exited($exitCode) at +${sw.elapsedMilliseconds}ms',
      );
      break;
    }
  }
  final tailGap = sw.elapsedMilliseconds - lastChangeMs;
  stdout.writeln(
    'requests served: ${_requestLog.length}; last request at '
    '${_requestLog.isEmpty ? '-' : _requestLog.last}',
  );
  stdout.writeln('total bytes: $received; final quiet: ${tailGap}ms');
  await chunkLog.flush();
  await chunkLog.close();
  await rawSink.flush();
  await rawSink.close();
  stdout.writeln('home kept at ${home.path}');
  pty.kill(ProcessSignal.sigkill);
  await pty.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  await server.close(force: true);
}
