// gh-1197 reproduction probe (temporary, not committed).
// Drives the real CLI in a PTY through a scripted long run (streamed text
// + slow bash tool calls) and reports every output-byte gap > 2s, like the
// ticket's python pty.fork probe.
import 'dart:convert';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

Future<void> main() async {
  final home = await Directory('/tmp').createTemp('fa1197h');
  final project = await Directory('/tmp').createTemp('fa1197p');
  File('${home.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('tui:\n  classic: true\n');

  // ~40KB of streamed text per text step, several turns, slow bash calls.
  String bigText(String tag) {
    final line = 'paragraph $tag lorem ipsum dolor sit amet consectetur 0123 ';
    return List.filled(700, line).join();
  }

  final turns = [
    [
      {'text': bigText('t1a')},
      {'text': bigText('t1b')},
      {
        'tool_call': {
          'id': 'c1',
          'name': 'bash',
          'arguments': {'command': 'sleep 8 && echo done-c1'},
        },
      },
    ],
    [
      {'text': bigText('t2a')},
      {
        'tool_call': {
          'id': 'c2',
          'name': 'bash',
          'arguments': {'command': 'sleep 8 && echo done-c2'},
        },
      },
    ],
    [
      {'text': bigText('t3-final')},
    ],
  ];
  final turnsFile = File('${home.path}/turns.json')
    ..writeAsStringSync(jsonEncode(turns));

  final env = <String, String>{
    'TERM': 'xterm-256color',
    'HOME': home.path,
    'FA_TEST_STREAM_SCRIPT': turnsFile.path,
    'FA_PROVIDER_TYPE': 'openai',
    'FA_PROVIDER_CONFIG': jsonEncode({
      'baseUrl': 'http://127.0.0.1:9',
      'model': 'pty-scripted',
    }),
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
  final terminal = Terminal(maxLines: 200);
  final chunks = <({int ms, int bytes})>[];
  final rawLog = File('/tmp/gh1197_raw.log');
  final rawSink = rawLog.openWrite();
  final chunkLog = File('/tmp/gh1197_chunks.log').openWrite();
  final sw = Stopwatch()..start();
  var received = 0;
  pty.out.listen((text) {
    received += text.length;
    chunks.add((ms: sw.elapsedMilliseconds, bytes: text.length));
    chunkLog.writeln('${sw.elapsedMilliseconds}\t${text.length}');
    rawSink.write(text);
    terminal.write(text);
  });
  terminal.onOutput = pty.write;

  // Wait for boot ([Model] marker), then submit.
  Future<bool> waitForText(String pattern, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final buf = StringBuffer();
      for (var i = terminal.buffer.scrollBack;
          i < terminal.buffer.lines.length;
          i++) {
        buf.writeln(terminal.buffer.lines[i].getText());
      }
      if (buf.toString().contains(pattern) || received > 0) {
        // fallthrough to raw check below
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (chunks.isNotEmpty) break;
    }
    return true;
  }

  await waitForText('[Model]', const Duration(seconds: 90));
  // settle
  await Future<void>.delayed(const Duration(milliseconds: 800));
  pty.write('write the essay');
  await Future<void>.delayed(const Duration(milliseconds: 100));
  pty.write('\r');
  stdout.writeln('submitted at +${sw.elapsedMilliseconds}ms');

  // Sample for 100s or until the process exits.
  var lastBytes = 0;
  var lastChangeMs = sw.elapsedMilliseconds;
  final start = DateTime.now();
  final deadline = start.add(const Duration(seconds: 100));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (received != lastBytes) {
      if (sw.elapsedMilliseconds - lastChangeMs > 2000) {
        stdout.writeln(
          'GAP: ${(sw.elapsedMilliseconds - lastChangeMs) / 1000}s of '
          'silence ending at +${sw.elapsedMilliseconds}ms '
          '(resumed with ${received - lastBytes} bytes)',
        );
      }
      lastBytes = received;
      lastChangeMs = sw.elapsedMilliseconds;
    }
    final exited = await pty.exitCode
        .timeout(const Duration(milliseconds: 5), onTimeout: () => -2);
    if (exited != -2) {
      stdout.writeln(
        'process exited with $exited at +${sw.elapsedMilliseconds}ms',
      );
      break;
    }
  }
  final gap = sw.elapsedMilliseconds - lastChangeMs;
  if (gap > 2000) {
    stdout.writeln(
      'STILL SILENT at end: ${gap / 1000}s gap at +$lastChangeMs..${sw.elapsedMilliseconds}ms',
    );
  }
  stdout.writeln('total bytes: $received');
  stdout.writeln('home kept at ${home.path}');
  await rawSink.flush();
  await rawSink.close();
  await chunkLog.flush();
  await chunkLog.close();
  pty.kill(ProcessSignal.sigkill);
}
