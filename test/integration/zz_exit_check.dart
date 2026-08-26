import 'dart:async';
import 'dart:io';
import 'package:pty2/pty2.dart';

Future<Map<String, Object>> runScenario(
  String name,
  Future<void> Function(PseudoTerminal) act,
) async {
  final home = Platform.environment['HOME']!;
  final pty = PseudoTerminal.start(
    '$home/.local/bin/fa',
    const [],
    workingDirectory: '/tmp',
    environment: {'TERM': 'xterm-256color', 'HOME': home},
    raw: true,
  );
  pty.resize(90, 25);
  final raw = StringBuffer();
  final sub = pty.out.listen(raw.write);
  // wait for boot
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!raw.toString().contains('[Model]') &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await act(pty);
  await Future<void>.delayed(const Duration(seconds: 2));
  final code = await pty.exitCode.timeout(
    const Duration(seconds: 8),
    onTimeout: () => -99,
  );
  await sub.cancel();
  final out = raw.toString();
  return {
    'exitCode': code,
    'altScreenExit': out.contains('\x1b[?1049l'),
    'resumeHint': out.contains('resume this session with'),
    'tail': out.substring(out.length > 600 ? out.length - 600 : 0),
  };
}

Future<void> main() async {
  // /exit path
  final viaExit = await runScenario('exit', (pty) async {
    pty.write('/exit');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    pty.write('\r');
  });
  print('=== /exit: $viaExit');

  // Ctrl+C path (idle, TUI raw mode)
  final viaCtrlC = await runScenario('ctrl+c', (pty) async {
    pty.write('\x03');
  });
  print('=== ctrl+c: $viaCtrlC');
}
