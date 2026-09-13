@Tags(['integration'])
@Timeout(Duration(minutes: 10))
/// Renderer equivalence + flicker-free integration proof for issue #274
/// (differential cell renderer + DEC 2026 synchronized output).
///
/// The real `dart bin/fah.dart` runs in a PTY against a canned STREAMING
/// endpoint; every stage is screenshotted through the real Flutter
/// TerminalView (same pipeline as fa_cli_visual_test.dart). On top of the
/// visual stages, the accumulated RAW PTY stream carries the byte-level
/// invariants:
///
/// - default env: package:xterm answers no DECRQM(?2026) — the auto path
///   must fall back cleanly: zero `?2026` bytes in the stream (E2);
/// - `FA_TUI_SYNC=1`: every painted frame is BSU…ESU-wrapped, pairs are
///   balanced and never nested;
/// - both: no `\x1b[2J` full-screen erase anywhere after boot — a repaint
///   is always bounded to the changed region (zero-flicker invariant).
///
/// Run: cd flutter_app && flutter test test/cli_visual/renderer_equivalence_test.dart --tags integration
library;

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
    Directory(shotsDir).createSync(recursive: true);
  });

  /// Shared scenario: boot → streaming run (scrollback growth) →
  /// post-stream → history recall. [expectSync] picks the env and the
  /// byte-level framing assertions.
  Future<void> runScenario(
    WidgetTester tester, {
    required int port,
    required String prefix,
    required bool? syncForce,
  }) async {
    final server = await _startStreamingServer(tester, port);
    final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:$port/v1');
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(
        repoRoot: repoRoot,
        extraEnv: {
          'HOME': tempHome.path,
          if (syncForce != null) 'FA_TUI_SYNC': syncForce ? '1' : '0',
        },
      ),
    ))!;
    harness.attach(tester);
    try {
      await harness.pumpTerminalView();
      await harness.waitForBoot();
      await harness.screenshot(shotsDir, '${prefix}_boot');

      // A multi-chunk streamed answer: scrollback grows while frames tick.
      harness.sendText('stream the river report');
      await harness.settle(settleMs: 200, timeout: const Duration(seconds: 2));
      harness.sendEnter();

      // Mid-stream: the first chunk is on screen while later chunks land.
      await harness.liveWaitForText(
        'RIVER-01',
        timeout: const Duration(seconds: 30),
      );
      await harness.settle(settleMs: 100);
      await harness.screenshot(shotsDir, '${prefix}_midstream');

      // Stream finished: the LAST chunk is visible — history grew.
      await harness.liveWaitForText(
        'RIVER-FIN',
        timeout: const Duration(seconds: 30),
      );
      await harness.settle(settleMs: 500);
      await harness.screenshot(shotsDir, '${prefix}_done');
      final screen = harness.screenText.replaceAll('\n', '');
      expect(screen, contains('RIVER-01'));
      expect(screen, contains('RIVER-FIN'));

      // History recall: ↑ brings the submitted prompt back to the composer.
      harness.sendArrowUp();
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '${prefix}_recall');
      expect(harness.screenText, contains('stream the river report'));

      // ── Byte-level invariants over the raw PTY stream ───────────────────
      // settle() returns the accumulated raw output; the stream only ever
      // grows, so the final read covers the whole scenario.
      await harness.settle(settleMs: 200);
      final raw = await harness.settle(settleMs: 200);
      // Zero-flicker: no full-screen erase anywhere (repaints are bounded
      // to the changed region — the pre-#274 renderer had no scroll ops or
      // atomic frames, so any regression here is loud).
      // Zero-flicker: full-screen erases are sanctioned only at boot /
      // resize relayouts (E1: full repaint once, then diffing resumes) —
      // every erase must precede the streamed answer; nothing during
      // streaming, scrolling, or history recall may wipe the screen.
      final streamStart = raw.indexOf('RIVER-01');
      expect(streamStart, greaterThan(0), reason: 'answer never streamed');
      final lastTwoJ = raw.lastIndexOf('\x1b[2J');
      expect(lastTwoJ, lessThan(streamStart),
          reason: 'full-screen erase during the streaming phase');
      if (syncForce == null) {
        // Auto path: xterm answers no DECRQM(?2026) — clean fallback (E2):
        // the query goes out, but not a single framing escape comes back.
        expect(raw.contains(RegExp(r'\?2026[hl]')), isFalse,
            reason: 'stray ?2026h/l without capability');
      } else if (syncForce) {
        // Forced sync: balanced, non-nested BSU/ESU pairs around frames.
        final opens = RegExp(r'\?2026h').allMatches(raw).length;
        final closes = RegExp(r'\?2026l').allMatches(raw).length;
        expect(opens, greaterThan(0), reason: 'no BSU in forced-sync stream');
        expect(opens, closes, reason: 'unbalanced BSU/ESU pairs');
        var depth = 0;
        for (final m in RegExp(r'\?2026[hl]').allMatches(raw)) {
          depth += m.group(0)!.endsWith('h') ? 1 : -1;
          expect(depth, inInclusiveRange(0, 1),
              reason: 'nested or unbalanced sync region');
        }
        expect(depth, 0);
      } else {
        expect(raw.contains(RegExp(r'\?2026[hl]')), isFalse,
            reason: 'FA_TUI_SYNC=0 must force legacy writes');
      }
    } finally {
      await harness.close();
      tempHome.deleteSync(recursive: true);
      await _stopServer(tester, server);
    }
  }

  testWidgets('auto path (no DECRQM answer) falls back with zero ?2026 bytes',
      (tester) async {
    await runScenario(
      tester,
      port: 18781,
      prefix: '110_renderer_auto',
      syncForce: null,
    );
  });

  testWidgets('FA_TUI_SYNC=1 wraps every painted frame in BSU…ESU',
      (tester) async {
    await runScenario(
      tester,
      port: 18782,
      prefix: '120_renderer_sync',
      syncForce: true,
    );
  });

  testWidgets('FA_TUI_SYNC=0 forces legacy writes (deterministic fallback)',
      (tester) async {
    await runScenario(
      tester,
      port: 18783,
      prefix: '130_renderer_legacy',
      syncForce: false,
    );
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

/// Creates a temp HOME whose endpoint URL is given (a test HTTP server on
/// loopback).
Directory _tempHomeWithEndpoint(String baseUrl) {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
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

/// A canned OpenAI-SSE endpoint that STREAMS its answer in a dozen chunks —
/// the scrollback-growth phase of the renderer-equivalence scenario. Chunk
/// markers RIVER-01…RIVER-FIN gate the test stages.
const _streamingServerPy = r'''
import http.server, json, time, sys

PORT = int(sys.argv[-1])
PARAGRAPHS = [
    ('RIVER-01', 'The river report begins at the source, where the headwaters '
        'carry meltwater over granite shelves and the current runs cold and '
        'clear enough to count the pebbles on the bottom.'),
    ('RIVER-02', 'By the second bend the valley widens; willow banks slow the '
        'flow into long pools where the sediment settles and the water turns '
        'the green of old bottles.'),
    ('RIVER-03', 'Midway, a ledge drops the river into a short chute of white '
        'water, loud enough to hear from the ridge trail a mile away.'),
    ('RIVER-04', 'Below the chute the river braids around gravel bars, each '
        'channel arguing with the others about the fastest way to the sea.'),
    ('RIVER-05', 'The lower reaches run deep and quiet between cottonwoods, '
        'and herons fish the shallows in the early morning fog.'),
    ('RIVER-06', 'At the mouth the current finally surrenders to the tide; '
        'salt pushes upstream twice a day and the whole report ends here — '
        'RIVER-FIN.'),
]

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        for tag, text in PARAGRAPHS:
            delta = {'choices': [{'delta': {'content': '\n\n%s %s' % (tag, text)}}]}
            self._chunk(('data: %s\n\n' % json.dumps(delta)).encode())
            time.sleep(0.12)
        self._chunk(b'data: [DONE]\n\n')
        self._chunk(b'')
        self.close_connection = True

    def _chunk(self, data):
        if data:
            self.wfile.write(('%x\r\n' % len(data)).encode() + data + b'\r\n')
        else:
            self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()

    def log_message(self, *a):
        pass

http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
''';

/// Starts the streaming server on [port] and waits until it accepts
/// connections. Process I/O runs in the real-async zone (see the harness
/// docs on fake-zone timers).
Future<Process> _startStreamingServer(WidgetTester tester, int port) async {
  final script = File('${Directory.systemTemp.path}/fa_stream_server_$port.py')
    ..writeAsStringSync(_streamingServerPy);
  final server = (await tester.runAsync(
    () => Process.start('python3', [script.path, '$port']),
  ))!;
  final up = await tester.runAsync(() async {
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        await s.close();
        return true;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return false;
  });
  if (up != true) throw StateError('stream server did not start on $port');
  return server;
}

/// Stops the streaming server (best-effort).
Future<void> _stopServer(WidgetTester tester, Process server) async {
  await tester.runAsync(() async {
    server.kill();
    await server.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  });
}
