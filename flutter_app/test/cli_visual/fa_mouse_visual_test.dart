@Tags(['integration'])
@Timeout(Duration(minutes: 10))
/// Mouse hit-region visual tests for the Fa CLI (issue #278, AC3): the
/// real `dart bin/fah.dart` runs in a PTY, synthetic mouse events (SGR
/// 1006 and legacy X10 bytes) are injected as raw input, and every step
/// is screenshotted through the real Flutter TerminalView. The assertions
/// read the live xterm buffer (caret cell, screen text) — what the PNG
/// shows is what a user sees.
///
/// Excluded from the default `flutter test` gate (integration tag); run
/// manually with:
///   cd flutter_app && flutter test test/cli_visual/fa_mouse_visual_test.dart \
///     --tags integration
library;


import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import '../golden/golden_test_helper.dart';
import 'cli_visual_harness.dart';

void main() {
  late String repoRoot;
  late String shotsDir;

  setUpAll(() async {
    await ensureGoldenFonts();
    repoRoot = _findRepoRoot();
    shotsDir = '$repoRoot/test/integration/screenshots';
    final dir = Directory(shotsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // NOTE: no wipe here — the base fa_cli_visual_test regenerates its own
    // NN_* goldens; this file only ever overwrites its own 1NN_* names.
  });

  /// Spawns the CLI, binds the tester, pumps the TerminalView and waits
  /// for the boot banner.
  Future<CliVisualHarness> boot(
    WidgetTester tester, {
    Map<String, String>? extraEnv,
  }) async {
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(repoRoot: repoRoot, extraEnv: extraEnv),
    ))!;
    harness.attach(tester);
    await harness.pumpTerminalView();
    await harness.waitForBoot();
    return harness;
  }

  /// Synthetic SGR 1006 click (press + release) at 0-based [col]/[row].
  void clickAt(CliVisualHarness harness, int col, int row) {
    final seq = '\x1b[<0;${col + 1};${row + 1}';
    harness.sendText('${seq}M${seq}m');
  }

  /// Synthetic legacy X10 click (modes 9/1000 terminals): `ESC [ M` plus
  /// the three 32-offset payload bytes.
  void clickX10(CliVisualHarness harness, int col, int row) {
    harness.sendText(
      '\x1b[M'
      '${String.fromCharCode(32)}'
      '${String.fromCharCode(32 + col + 1)}'
      '${String.fromCharCode(32 + row + 1)}',
    );
  }

  /// The 0-based screen cell of [needle] on the current frame.
  (int, int) cellOf(CliVisualHarness harness, String needle) {
    final lines = harness.viewportLines;
    final row = lines.indexWhere((l) => l.contains(needle));
    expect(row, greaterThanOrEqualTo(0), reason: 'no "$needle" on screen');
    final col = lines[row].indexOf(needle);
    return (col, row);
  }

  group('mouse hit-regions (issue #278)', () {
    testWidgets('SGR click on the composer moves the caret', (tester) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('caret-click-test');
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '100_composer_before_click');

      final (col, row) = cellOf(harness, 'caret');
      expect(harness.terminal.buffer.cursorY, row);
      // The caret sits after the typed text; clicking "caret" must home it
      // onto the clicked cell.
      clickAt(harness, col + 2, row);
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '101_composer_after_click');

      expect(harness.terminal.buffer.cursorX, col + 2);
      expect(harness.terminal.buffer.cursorY, row);

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('legacy X10 click decodes and moves the caret', (tester) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('x10-payload-check');
      await harness.settle(settleMs: 400);

      final (col, row) = cellOf(harness, 'x10');
      // Before: caret at the end of the line.
      final beforeX = harness.terminal.buffer.cursorX;
      expect(beforeX, greaterThan(col));
      clickX10(harness, col + 1, row);
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '102_x10_click');

      // Without the X10 decoder the payload bytes would leak through as
      // keypresses (mojibake into the input); with it the caret moves.
      expect(harness.terminal.buffer.cursorX, col + 1);
      expect(harness.terminal.buffer.cursorY, row);
      expect(harness.screenText, contains('x10-payload-check'));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('model picker: golden table, click a row to switch', (
      tester,
    ) async {
      final tempHome = _tempHomeWithModels();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      await harness.runSlashCommand('/model');
      await harness.liveWaitForText(
        'Select model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '103_model_picker_table');
      // The golden table over the seeded fixtures: three real rows, the
      // current marker on the boot model, and the footer hint.
      expect(harness.screenText, contains('test-mini'));
      expect(harness.screenText, contains('test-max'));
      expect(harness.screenText, contains('omega'));
      expect(harness.screenText, contains('●'));

      // The footer hint row marks the bottom of the table; the model row
      // right above it is the click target.
      final lines = harness.viewportLines;
      final hintRow = lines.indexWhere((l) => l.contains('enter switch'));
      expect(hintRow, greaterThan(0), reason: 'picker footer hint not shown');
      final targetLine = lines[hintRow - 1].trim();
      // The selection cursor (▸) / current marker (●) prefixes the label;
      // model ids are single tokens (the id column can butt the provider
      // column with a single space when the id fills the width).
      final idToken = targetLine
          .replaceFirst(RegExp(r'^[^\w\s]\s*'), '')
          .split(RegExp(r'\s+'))
          .first;
      expect(idToken, isNotEmpty, reason: 'no model id in "$targetLine"');

      final col = lines[hintRow - 1].indexOf(idToken);
      clickAt(harness, col + 1, hintRow - 1);
      await harness.settle(settleMs: 600);
      await harness.liveWaitForText(
        'switched model to omega',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '104_model_switched_by_click');

      // The picker closed and the clicked model is the live one.
      expect(harness.screenText, isNot(contains('enter switch')));
      expect(harness.screenText, contains(idToken));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('busy queue: click a queued row to drop it', (tester) async {
      // A hanging endpoint keeps the turn busy so the next message queues.
      // The port is picked free at runtime: fixed test ports collide with
      // stale answer-server processes from other visual test files.
      final port = (await tester.runAsync(() async {
        final socket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final picked = socket.port;
        await socket.close();
        return picked;
      }))!;
      final serverScript = File(
        '${Directory.systemTemp.path}/fa_mouse_slow_server.py',
      )..writeAsStringSync('''
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        time.sleep(120)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", $port), H).serve_forever()
''');
      final server = (await tester.runAsync(
        () => Process.start('python3', [serverScript.path]),
      ))!;
      final up = await tester.runAsync(() async {
        for (var i = 0; i < 50; i++) {
          try {
            final socket = await Socket.connect('127.0.0.1', port);
            await socket.close();
            return true;
          } on Object {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        return false;
      });
      if (up != true) throw StateError('slow server did not start');
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:$port/v1');
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      // First message hangs the turn busy; the second queues (❯ row).
      harness.sendText('first');
      await harness.settle(settleMs: 300, timeout: const Duration(seconds: 2));
      harness.sendEnter();
      // The turn is queue-eligible only once the request is in flight —
      // wait for the busy row first (matches the base queue test).
      await harness.liveWaitForText(
        'Working',
        timeout: const Duration(seconds: 30),
      );
      harness.sendText('mouse-drop-me');
      await harness.settle(settleMs: 300, timeout: const Duration(seconds: 2));
      harness.sendEnter();
      await harness.liveWaitForText(
        '❯ mouse-drop-me',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '105_queue_row');

      final (col, row) = cellOf(harness, 'mouse-drop-me');
      clickAt(harness, col, row);
      await harness.settle(settleMs: 500);
      await harness.screenshot(shotsDir, '106_queue_dropped_by_click');

      expect(harness.screenText, isNot(contains('❯ mouse-drop-me')));

      await harness.close();
      await tester.runAsync(() async {
        server.kill();
        await server.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      });
      tempHome.deleteSync(recursive: true);
    });
  });
}

/// Walks up from the CWD until a directory containing `bin/fah.dart` is
/// found — the flutter_agent repo root regardless of where the test runner
/// was started from.
String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/bin/fah.dart').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('flutter_agent repo root not found from $dir');
    }
    dir = parent;
  }
}

/// Creates a temp HOME with default config (yolo mode, dead endpoint).
Directory _tempHome() {
  final tempHome = Directory.systemTemp.createTempSync('fa_mouse_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
  return tempHome;
}
/// Creates a temp HOME whose boot model is the fixture `test-mini` and
/// whose persisted model cache seeds the fixture models the golden
/// picker table shows (`test-mini`, `test-max`, `omega`) — the CLI
/// trusts a fresh `~/.fah/model_cache.json` at boot.
Directory _tempHomeWithModels() {
  final tempHome = Directory.systemTemp.createTempSync('fa_mouse_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-mini
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
  File('${tempHome.path}/.fah/model_cache.json').writeAsStringSync(
    jsonEncode({
      'openai': {
        'ids': ['test-mini', 'test-max', 'omega'],
        'fetchedAtMs': DateTime.now().millisecondsSinceEpoch,
      },
    }),
  );
  return tempHome;
}

/// Creates a temp HOME whose endpoint URL is given (e.g. a test HTTP
/// server on loopback).
Directory _tempHomeWithEndpoint(String baseUrl) {
  final tempHome = Directory.systemTemp.createTempSync('fa_mouse_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: $baseUrl
mode: code
approvalMode: yolo
allowedTools: []
''');
  return tempHome;
}
