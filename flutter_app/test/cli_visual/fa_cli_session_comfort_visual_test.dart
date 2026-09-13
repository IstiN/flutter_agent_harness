@Tags(['integration'])
@Timeout(Duration(minutes: 10))
/// Session-comfort goldens (issue #276 AC4): the real `dart bin/fah.dart`
/// in a PTY over a canned OpenAI-SSE endpoint — the `/compact` report block,
/// the clipboard image paste (chip + sent message), and the theme swap pair.
/// Same rendering pipeline as `fa_cli_visual_test.dart`: PNG through the real
/// Flutter [TerminalView], plus a `.txt` twin of the exact screen text.
///
/// Golden names use the `1NN_` range; `setUpAll` wipes only that range so a
/// rerun never leaves stale `1NN_*` files (and never touches the other
/// files' goldens).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;
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
    // Wipe only THIS file's goldens (exact stems — the 1NN range belongs
    // to fa_cli_visual_test too) so a rerun never leaves stale twins and
    // never touches the other suites' committed files.
    const stems = [
      '100_compact_report',
      '110_paste_chip',
      '111_paste_sent',
      '120_theme_catppuccin',
      '130_theme_dracula',
    ];
    for (final stem in stems) {
      for (final ext in const ['.png', '.txt']) {
        final file = File('$shotsDir/$stem$ext');
        if (file.existsSync()) file.deleteSync();
      }
    }
  });

  /// Spawns the CLI, binds the tester, pumps the TerminalView (which sizes
  /// the PTY to the real cell geometry) and waits for the boot banner.
  Future<CliVisualHarness> boot(
    WidgetTester tester, {
    Map<String, String>? extraEnv,
    Size size = const Size(1040, 600),
  }) async {
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(repoRoot: repoRoot, extraEnv: extraEnv),
    ))!;
    harness.attach(tester);
    await harness.pumpTerminalView(size: size);
    await harness.waitForBoot();
    return harness;
  }

  group('/compact report block', () {
    testWidgets('two big turns → forced /compact → report golden', (
      tester,
    ) async {
      final port = await _freePort(tester);
      final server = await _startServer(tester, port, _compactServerPy);
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:$port/v1');
      final harness = await boot(
        tester,
        extraEnv: {'HOME': tempHome.path},
        // Tall viewport: the report block plus the Turn Context panel need
        // ~30 rows — at the default 24 the header line scrolls off.
        size: const Size(1040, 900),
      );
      try {
        // Two turns whose replies each top `keepRecentTokens` (20000 tokens
        // at the catalog default window) — the backward token walk then cut
        // at the last reply, giving /compact a real region to summarize.
        harness.sendText('long turn one');
        harness.sendEnter();
        await harness.liveWaitForText(
          'TAIL-ONE',
          timeout: const Duration(seconds: 90),
        );
        await harness.settle(settleMs: 400);
        harness.sendText('long turn two');
        harness.sendEnter();
        await harness.liveWaitForText(
          'TAIL-TWO',
          timeout: const Duration(seconds: 90),
        );
        await harness.settle(settleMs: 400);

        await harness.runSlashCommand('/compact');
        // The TUI repaints with cursor-address sequences, so only body
        // rows are reliably greppable in the raw buffer.
        await harness.liveWaitForText(
          'records:',
          timeout: const Duration(seconds: 90),
        );
        await harness.settle(settleMs: 400);

        // The report block: before → after tokens, records, fenced summary.
        expect(harness.screenText, contains('tokens:'));
        expect(harness.screenText, contains('records:'));
        expect(harness.screenText, contains('summary:'));
        await harness.screenshot(shotsDir, '100_compact_report');
      } finally {
        await harness.close();
        tempHome.deleteSync(recursive: true);
        await _stopServer(tester, server);
      }
    });
  });

  group('clipboard image paste', () {
    testWidgets('ctrl+v → chip in composer → sent with the message', (
      tester,
    ) async {
      final port = await _freePort(tester);
      final server = await _startServer(
        tester,
        port,
        _answerServerPy,
        'Got the image — the teal square came through clearly.',
      );
      final png = _writeFixturePng();
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:$port/v1');
      final harness = await boot(
        tester,
        extraEnv: {'HOME': tempHome.path, 'FA_FAKE_PASTEBOARD': png.path},
      );
      try {
        // Ctrl+V (raw PTY byte 0x16) reads the fake pasteboard off the UI
        // loop; the chip renders above the input frame.
        harness.sendText('\x16');
        await harness.liveWaitForText(
          '[image: clipboard-1.png',
          timeout: const Duration(seconds: 20),
        );
        await harness.settle(settleMs: 400);
        expect(harness.screenText, contains('chips send with your next'));
        await harness.screenshot(shotsDir, '110_paste_chip');

        // The next plain submit consumes the chips — the image rides the
        // user message as ImageContent and the reply confirms the turn.
        harness.sendText('what is in the clipboard?');
        harness.sendEnter();
        await harness.liveWaitForText(
          'Got the image',
          timeout: const Duration(seconds: 60),
        );
        await harness.settle(settleMs: 400);
        expect(harness.screenText, isNot(contains('[image: clipboard-1.png')));
        await harness.screenshot(shotsDir, '111_paste_sent');
      } finally {
        await harness.close();
        tempHome.deleteSync(recursive: true);
        png.deleteSync();
        await _stopServer(tester, server);
      }
    });
  });

  group('hot theme swap', () {
    testWidgets('/theme catppuccin → /theme dracula on the same screen', (
      tester,
    ) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      try {
        await harness.runSlashCommand('/theme catppuccin');
        await harness.liveWaitForText(
          'theme: catppuccin',
          timeout: const Duration(seconds: 20),
        );
        await harness.settle(settleMs: 500);
        expect(
          File('${tempHome.path}/.fah/theme.yaml').readAsStringSync(),
          contains('catppuccin'),
        );
        await harness.screenshot(shotsDir, '120_theme_catppuccin');

        await harness.runSlashCommand('/theme dracula');
        await harness.liveWaitForText(
          'theme: dracula',
          timeout: const Duration(seconds: 20),
        );
        await harness.settle(settleMs: 500);
        expect(
          File('${tempHome.path}/.fah/theme.yaml').readAsStringSync(),
          contains('dracula'),
        );
        await harness.screenshot(shotsDir, '130_theme_dracula');
      } finally {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      }
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

/// Creates a temp HOME whose endpoint URL is given (e.g. a test HTTP server
/// on loopback).
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

/// Creates a temp HOME with the default config (dead endpoint, yolo mode).
Directory _tempHome() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
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

/// Writes the committed-in-code 32×32 teal PNG to a temp file and returns
/// it — the `FA_FAKE_PASTEBOARD` target (99 real bytes, valid PNG magic).
/// Fully SYNC: async file I/O freezes in the widget test's fake zone.
File _writeFixturePng() {
  final dir = Directory.systemTemp.createTempSync('fa_paste_golden');
  return File('${dir.path}/fixture.png')..writeAsBytesSync(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nO3NQQkAAAgE'
      'sEtqalOYwhQ+hMH+S02fikAgEAgEAoFAIPgSLDN4cHmusw2eAAAAAElFTkSuQmCC',
    ),
  );
}

/// Canned SSE endpoint for the paste golden: every POST is answered with
/// [answer] as a single text delta.
const _answerServerPy = r'''
import http.server, json, sys

ANSWER = sys.argv[1]
PORT = int(sys.argv[2])

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        deltas = [
            {'choices': [{'delta': {'content': ANSWER}}]},
            {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
        ]
        body = ''.join('data: %s\n\n' % json.dumps(c) for c in deltas)
        body += 'data: [DONE]\n\n'
        encoded = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *a):
        pass

http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
''';

/// Canned SSE endpoint for the compaction golden. Turn replies are keyed on
/// the LAST user message text (never a counter — the CLI fires hidden model
/// requests too); the compaction summarizer is recognized by its system
/// prompt (`summary_system.md`), the durable-facts extractor by
/// `extract_durable.md` — which gets a JSON-empty reply. Requests log to
/// /tmp/fa_compact_server.log while the golden is being dialed in.
const _compactServerPy = r'''
import http.server, json, sys

PORT = int(sys.argv[1])

def big(tag):
    lines = ['line %04d: %s' % (i, 'x' * 30) for i in range(2000)]
    lines.append('TAIL-' + tag)
    return '\n'.join(lines)

SUMMARY = (
    'SUMMARY-CONTEXT-CHECKPOINT\n'
    '## Goal\n'
    '- golden screenshot of the compaction report block\n\n'
    '## Progress\n'
    '### Done\n'
    '- [x] two long turns summarized\n\n'
    '## Next Steps\n'
    '1. eyeball the report block'
)

def last_user_text(raw):
    messages = json.loads(raw).get('messages', [])
    for m in reversed(messages):
        if m.get('role') == 'user':
            c = m.get('content')
            return c if isinstance(c, str) else json.dumps(c)
    return ''

def reply_for(raw):
    if 'context checkpoint assistant' in raw:
        return SUMMARY
    if 'mine a conversation span' in raw:
        return '[]'
    last_user = last_user_text(raw)
    with open('/tmp/fa_compact_server.log', 'a') as log:
        log.write('LAST_USER[%d]: %r\n' % (len(last_user), last_user[:300]))
    if 'turn one' in last_user:
        return big('ONE')
    if 'turn two' in last_user:
        return big('TWO')
    return 'Ready.'

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        content = reply_for(raw.decode('utf-8', 'replace'))
        deltas = [
            {'choices': [{'delta': {'content': content}}]},
            {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
        ]
        payload = ''.join('data: %s\n\n' % json.dumps(c) for c in deltas)
        payload += 'data: [DONE]\n\n'
        encoded = payload.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *a):
        pass

http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
''';

/// Starts a canned server script on [port] and waits until it accepts
/// connections. Process I/O runs in the real-async zone (see the harness
/// docs on fake-zone timers).
Future<Process> _startServer(
  WidgetTester tester,
  int port,
  String script, [
  String? arg,
]) async {
  final file = File('${Directory.systemTemp.path}/fa_golden_server_$port.py')
    ..writeAsStringSync(script);
  final server = (await tester.runAsync(
    () => Process.start('python3', [file.path, ?arg, '$port']),
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
  if (up != true) throw StateError('canned server did not start on $port');
  return server;
}

/// Stops a canned server (best-effort).
Future<void> _stopServer(WidgetTester tester, Process server) async {
  await tester.runAsync(() async {
    server.kill();
    await server.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  });
}

/// Grabs a free loopback port — leaked servers from crashed runs must never
/// wedge a rerun by answering on a stale port.
Future<int> _freePort(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();
    return port;
  }))!;
}
