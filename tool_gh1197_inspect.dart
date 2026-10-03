// gh-1197: attach a PTY to the RESUMED big-transcript session, dump screen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

Future<void> main() async {
  final home = '/tmp/fa1197rSHSERW';
  final project = '/tmp/fa1197rpCFGPZG';
  final pty = PseudoTerminal.start(
    'dart',
    [
      '${Directory.current.path}/bin/fah.dart',
      '--session',
      'pty1197resume',
    ],
    workingDirectory: project,
    environment: {
      'TERM': 'xterm-256color',
      'HOME': home,
      'FA_PROVIDER_TYPE': 'openai',
      'FA_PROVIDER_CONFIG': jsonEncode({
        'baseUrl': 'http://127.0.0.1:18119/v1',
        'model': 'fake-paced',
      }),
      'FA_KEY_127.0.0.1': 'test-key',
      'DAP_HUB_URL': 'ws://127.0.0.1:1/ws',
      'DAP_LOCAL_HUB_URL': 'ws://127.0.0.1:1/ws',
    },
    raw: true,
  );
  pty.resize(80, 24);
  final terminal = Terminal(maxLines: 3000);
  final sw = Stopwatch()..start();
  var received = 0;
  pty.out.listen((text) {
    received += text.length;
    terminal.write(text);
  });
  terminal.onOutput = pty.write;
  // Let it sit 25s — plenty for the boot of a fresh session.
  await Future<void>.delayed(const Duration(seconds: 25));
  stdout.writeln('bytes after 25s: $received');
  final buf = StringBuffer();
  final b = terminal.buffer;
  for (var i = b.scrollBack; i < b.lines.length; i++) {
    buf.writeln(b.lines[i].getText());
  }
  final screen = buf.toString();
  stdout.writeln('--- LAST 30 SCREEN ROWS ---');
  final rows = screen.split('\n');
  for (final r in rows.skip(rows.length > 30 ? rows.length - 30 : 0)) {
    stdout.writeln('│$r');
  }
  // CPU sample of the child for 3s.
  stdout.writeln("sampling fa dart processes...");
  await Process.run("/tmp/sample_cpu.sh", []).then((r) => stdout.write(r.stdout));
  pty.kill(ProcessSignal.sigkill);
}
