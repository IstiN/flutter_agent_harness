// Throwaway PTY smoke test for the integrated fa TUI. Run:
//   dart run example/tui_smoke.dart
// Deletes nothing; safe to re-run. Not part of the test suite.
import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';

Future<void> main() async {
  // FA_SMOKE_BIN=/path/to/fa tests a compiled binary instead of `dart run`.
  final bin = Platform.environment['FA_SMOKE_BIN'];
  final pty = bin != null
      ? PseudoTerminal.start(
          bin,
          const [],
          workingDirectory: Directory.current.path,
          raw: true,
        )
      : PseudoTerminal.start(
          'dart',
          ['run', 'bin/fah.dart'],
          workingDirectory: Directory.current.path,
          raw: true,
        );
  pty.resize(100, 30);
  final buf = StringBuffer();
  final sub = pty.out.listen(buf.write);

  Future<bool> waitFor(Pattern p, Duration t) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < t) {
      if (buf.toString().contains(p)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  var failures = 0;
  void check(String name, bool ok) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}: $name');
    if (!ok) failures++;
  }

  // 1. Starts: banner + status visible. The banner must be inside the
  // alternate screen (after the 1049h enter sequence), not just printed to
  // stdout before the TUI took over.
  check(
    'banner+status shown',
    await waitFor('[Model]', const Duration(seconds: 30)),
  );
  final altStart = buf.toString().indexOf('?1049h');
  check(
    'banner inside alt screen',
    altStart >= 0 && buf.toString().substring(altStart).contains('[Model]'),
  );

  // 2. Typing echoes into the input line.
  pty.write('hello');
  check(
    'typed text visible',
    await waitFor('hello', const Duration(seconds: 3)),
  );

  // 3. Shift+Enter via Core Graphics cannot be simulated here; check Ctrl+O
  // inserts a newline instead (multi-line input renders two rows).
  pty.write('\x0f');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  pty.write('world');
  check('multi-line input', await waitFor('world', const Duration(seconds: 3)));

  // 4. Clear input ('hello\nworld' = 11 chars; send extra backspaces to be
  // safe), open slash menu.
  for (var i = 0; i < 20; i++) {
    pty.write('\x7f');
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  pty.write('/');
  check(
    'slash menu opens',
    await waitFor('[Commands]', const Duration(seconds: 3)),
  );

  // 5. Filter the menu by typing 'ex', accept with Enter (input must become
  // exactly '/exit'), submit, expect 'bye' and a clean quit.
  final marker = buf.length;
  pty.write('ex');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  pty.write('\r'); // accept item into input
  await Future<void>.delayed(const Duration(milliseconds: 500));
  // The input line is bare text between rules — no `fa> ` prefix. The
  // renderer cursor-addresses rows, so assert the column-1 write of the
  // accepted command (menu items render as '▸ /exit' or '  /exit').
  final accepted = buf.toString().substring(marker);
  check('menu accept fills input', accepted.contains(';1H/exit'));
  pty.write('\r'); // submit
  await Future<void>.delayed(const Duration(seconds: 2));
  check('/exit quits', buf.toString().substring(marker).contains('bye'));

  await sub.cancel();
  pty.kill();
  if (failures > 0) {
    final text = buf.toString();
    final tail = text.length > 3000 ? text.substring(text.length - 3000) : text;
    stdout.writeln('--- buffer tail ---');
    stdout.writeln(tail.replaceAll('\x1b', '<ESC>'));
    stdout.writeln('-------------------');
  }
  stdout.writeln(failures == 0 ? 'SMOKE OK' : 'SMOKE FAILURES: $failures');
  exit(failures == 0 ? 0 : 1);
}
