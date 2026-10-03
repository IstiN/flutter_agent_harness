// gh-1197 probe v3: RESUME a session with a large transcript, then run a
// long paced stream on top of it. Reports mid-run output gaps.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

Future<FaRun> spawnFa({
  required String home,
  required String project,
  required String session,
  List<String> extraArgs = const [],
}) async {
  final pty = PseudoTerminal.start(
    'dart',
    [
      '${Directory.current.path}/bin/fah.dart',
      '--session',
      session,
      ...extraArgs,
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
  final terminal = Terminal(maxLines: 2000);
  final sw = Stopwatch()..start();
  final chunks = <({int ms, int bytes})>[];
  var received = 0;
  pty.out.listen((text) {
    received += text.length;
    chunks.add((ms: sw.elapsedMilliseconds, bytes: text.length));
    terminal.write(text);
  });
  terminal.onOutput = pty.write;
  return FaRun(pty, terminal, sw, chunks, () => received);
}

final class FaRun {
  FaRun(this.pty, this.terminal, this.sw, this.chunks, this.bytes);
  final PseudoTerminal pty;
  final Terminal terminal;
  final Stopwatch sw;
  final List<({int ms, int bytes})> chunks;
  final int Function() bytes;

  Future<void> waitScreen(String pattern, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final buf = StringBuffer();
      final b = terminal.buffer;
      for (var i = b.scrollBack; i < b.lines.length; i++) {
        buf.writeln(b.lines[i].getText());
      }
      if (buf.toString().contains(pattern)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('no "$pattern" on screen');
  }

  void submit(String text) {
    pty.write(text);
    Future<void>.delayed(const Duration(milliseconds: 120)).then((_) {
      pty.write('\r');
    });
  }

  void sendKey(String k) => pty.write(k);
}

Future<void> main() async {
  final home = await Directory('/tmp').createTemp('fa1197r');
  final project = await Directory('/tmp').createTemp('fa1197rp');
  final session = 'pty1197resume';

  // --- Phase 1: build a BIG transcript (10 fat turns), then exit.
  final build = await spawnFa(home: home.path, project: project.path, session: session);
  await build.waitScreen('[Model]', const Duration(seconds: 90));
  await Future<void>.delayed(const Duration(milliseconds: 800));
  build.submit('build the big transcript');
  // 10 tool turns x ~3s + text = ~60s; wait for the final answer.
  await build.waitScreen('all-done-final', const Duration(seconds: 180));
  await Future<void>.delayed(const Duration(seconds: 2));
  stdout.writeln(
    'phase 1 done: ${build.bytes()} bytes; killing and resuming',
  );
  build.pty.kill(ProcessSignal.sigkill);

  // --- Phase 2: RESUME the same session; the boot replays the transcript.
  final run = await spawnFa(home: home.path, project: project.path, session: session);
  await run.waitScreen('[Model]', const Duration(seconds: 90));
  // Let the replay settle.
  await Future<void>.delayed(const Duration(seconds: 3));
  stdout.writeln('phase 2 booted: ${run.bytes()} bytes');
  run.submit('write the essay');
  stdout.writeln('phase 2 submitted');

  // Sample for gaps while the long stream runs.
  final start = DateTime.now();
  final deadline = start.add(const Duration(seconds: 220));
  var lastBytes = run.bytes();
  var lastChangeMs = run.sw.elapsedMilliseconds;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final now = run.bytes();
    if (now != lastBytes) {
      final gapMs = run.sw.elapsedMilliseconds - lastChangeMs;
      if (gapMs > 5000) {
        stdout.writeln(
          'MID-RUN GAP: ${(gapMs / 1000).toStringAsFixed(1)}s ending at '
          '+${run.sw.elapsedMilliseconds}ms (+${now - lastBytes} bytes)',
        );
      }
      lastBytes = now;
      lastChangeMs = run.sw.elapsedMilliseconds;
    }
    final exited = await run.pty.exitCode
        .timeout(const Duration(milliseconds: 5), onTimeout: () => -2);
    if (exited != -2) {
      stdout.writeln('exited($exited) at +${run.sw.elapsedMilliseconds}ms');
      break;
    }
  }
  final tailGap = run.sw.elapsedMilliseconds - lastChangeMs;
  stdout.writeln('total: ${run.bytes()} bytes; final quiet: $tailGap ms');
  stdout.writeln('home kept at ${home.path}');
  run.pty.kill(ProcessSignal.sigkill);
}
