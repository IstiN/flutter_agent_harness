@TestOn('vm')
@Tags(['integration'])
// gh-1283: the 180s boot budget in openSheet needs a proportionate
// backstop (10 min, like the steering suite's heavy leg) — at the old
// 5-minute cap a slow boot would starve the assertion waits of budget.
@Timeout(Duration(minutes: 10))
/// Issue #97 — the TUI secret sheet drove users into a trap: focus started
/// on the prefilled name, the typed secret echoed in cleartext in that row,
/// and Enter was a silent no-op. These tests drive the REAL binary over a
/// PTY against a fake openai-completions endpoint scripted to emit a
/// `request_secret` tool call.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('TUI secret sheet (issue #97)', () {
    late _SecretSheetMock mock;
    late Directory tempHome;
    late FaCliHarness harness;

    setUp(() async {
      mock = _SecretSheetMock();
      await mock.start();
      tempHome = _tempHomeForMock(mock.port);
      harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
      );
    });

    tearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
      await mock.close();
    });

    /// Boots the REPL and sends a message whose scripted answer is the
    /// `request_secret` tool call, leaving the secret sheet open.
    Future<void> openSheet() async {
      // gh-1283: the 90s harness default loses on loaded CI runners — a
      // JIT boot painted the [Model] banner only at the deadline (run
      // 37268915954), and the Dart CFE can stall the compile outright
      // (run 37297674933; its one-liner `File not formatted as yaml: .`
      // is the SDK's own boot error). Explicit boot budget, same as
      // job_card_heredoc_pty_test.dart (#604); 180s boot + the waits
      // below (≈ 286s worst case) sit well inside the file's 10-minute
      // per-test cap.
      await harness.waitForBoot(timeout: const Duration(seconds: 180));
      harness.sendText('need the key');
      harness.sendEnter();
      await harness.waitForText(
        'Credential request',
        // The first PTY boot in the suite pays the VM warm-up.
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 300);
    }

    test(
      'IT-focus: opens on the value field; the name is a placeholder',
      () async {
        await openSheet();
        // The session history also renders a tool row (`• request_secret
        // · MY_SERVICE_TOKEN`) above the sheet — the sheet's own name row
        // is the frame-closed one.
        final nameLine = harness.screenLines.firstWhere(
          (l) => l.contains('MY_SERVICE_TOKEN') && l.trimRight().endsWith('│'),
        );
        expect(
          nameLine.contains('>'),
          isFalse,
          reason: 'the name row must not hold focus on open',
        );
        expect(
          harness.screenLines.where((l) => l.contains('>')),
          isNotEmpty,
          reason: 'the focused (value) row carries the focus marker',
        );
      },
    );

    /// Types [secret] into the sheet's value field and synchronizes on
    /// STABLE markers only (gh-1244): the full masked value row on the
    /// painted SCREEN, then the masking property. Never waits on an exact
    /// transient bullet count — under CI timing the PTY paints past the
    /// checkpoint before the wait evaluates, and on the raw wire the
    /// focused row's cursor cell is wrapped in inverse-video escapes, so
    /// N consecutive `•` need never exist in the STREAM at all.
    ///
    /// The anchor is the screen, not raw quiescence (gh-1244 review
    /// thread): while the sheet is open the pending turn keeps the TUI
    /// repainting (spinner/elapsed rows), so the raw buffer NEVER reaches
    /// byte quiescence — a `waitForOutput` settle always expires silently
    /// and a snapshot read afterwards can still catch a mid-echo frame
    /// (e.g. 13 of 15 bullets). Bullets are append-only while typing, so
    /// the full N-bullet row is a monotone, stable synchronization
    /// point: `waitForScreen` holds until it is painted (or fails loudly
    /// with the screen dump), and the returned anchored screen is what
    /// the assertions read — never a fresh re-sample (gh-1049 family).
    Future<void> typeSecret(String secret) async {
      harness.sendText(secret);
      var screen = await harness.waitForScreen(
        '•' * secret.length,
        timeout: const Duration(seconds: 30),
      );
      // The anchored frame can still predate the value row's closing
      // border by one repaint; re-anchor once on the current screen
      // before failing (review thread: tolerate a short-lived
      // intermediate frame by re-settling once on mismatch).
      if (maskedValueRow(screen) == null) {
        screen = await harness.waitForScreen(
          '•' * secret.length,
          timeout: const Duration(seconds: 30),
        );
      }
      // (b) The security pin, asserted BEFORE the row-dependent (a) —
      // it is race-free: rawOutput is append-only, and by now every frame
      // the typing could ever paint has been captured (the screen wait
      // proves the last keystroke's frame landed). The plaintext bytes
      // must never appear in ANY captured frame: rawOutput is the whole
      // PTY transcript — every screen the emulator ever rendered derives
      // from it — so scanning it covers raced intermediates a
      // current-screen-only check would miss.
      expect(
        harness.rawOutput.contains(secret),
        isFalse,
        reason: 'the secret bytes appeared in the raw PTY output',
      );
      expect(screen.contains(secret), isFalse);
      // (a) The frame-closed value row carries exactly one bullet per
      // typed char — masking held from the first keystroke through the
      // last. The history's tool row (`• request_secret · …`) is not
      // frame-closed, so the `│` guard pins this to the sheet's own row.
      final row = maskedValueRow(screen);
      if (row == null) {
        throw StateError(
          'the value row must render the masked secret; screen:\n$screen',
        );
      }
      expect(
        row.split('•').length - 1,
        secret.length,
        reason: 'every typed char must be masked (one bullet per char)',
      );
    }

    test('IT-mask: the secret is masked from the first keystroke', () async {
      await openSheet();
      // Asserts the masking property after quiescence (bullet count ==
      // typed length, zero plaintext frames) — no raced transient anchor.
      await typeSecret('s3cr3t-TOKEN-42');
    });

    test(
      'IT-enter: blocked Enter shows the reason, then Enter submits',
      () async {
        await openSheet();
        // Enter on an empty value must not be a silent no-op (F3).
        harness.sendEnter();
        await harness.waitForText(
          'Type the value first',
          timeout: const Duration(seconds: 10),
        );
        await typeSecret('s3cr3t-TOKEN-42');
        harness.sendEnter();
        await harness.waitForText(
          'turn-complete',
          timeout: const Duration(seconds: 30),
        );
        expect(mock.bodies.length, greaterThanOrEqualTo(2));
        expect(harness.rawOutput.contains('s3cr3t-TOKEN-42'), isFalse);
      },
    );

    test(
      'IT-regression: the trapped production sequence now submits',
      () async {
        await openSheet();
        await typeSecret('s3cr3t-TOKEN-42');
        harness.sendEnter();
        await harness.waitForText(
          'turn-complete',
          timeout: const Duration(seconds: 30),
        );
        // The follow-up request carries the GRANT under the suggested name
        // (the name field was never touched), not a decline.
        final second = jsonDecode(mock.bodies[1]) as Map<String, dynamic>;
        final messages = second['messages'] as List;
        final transcript = messages
            .map((m) => (m as Map<String, dynamic>)['content'])
            .join(' ');
        expect(transcript, contains('Secret MY_SERVICE_TOKEN is available'));
        expect(harness.rawOutput.contains('s3cr3t-TOKEN-42'), isFalse);
      },
    );

    test(
      'IT-placeholder: a typed name char replaces the suggestion; Esc cancels',
      () async {
        await openSheet();
        harness.sendText('\t'); // focus the name field
        await harness.waitForOutput(settleMs: 300);
        harness.sendText('K');
        await harness.waitForText('> K', timeout: const Duration(seconds: 10));
        // Replaced wholesale — no leftover concat with the suggestion.
        expect(harness.screenText.contains('MY_SERVICE_TOKENK'), isFalse);
        harness.sendEscape();
        await harness.waitForText(
          'turn-complete',
          timeout: const Duration(seconds: 30),
        );
        // Esc declined the request: the follow-up carries the decline.
        expect(mock.bodies[1], contains('declined'));
      },
    );
  });
}

/// Creates a temp HOME pointing at the local mock with yolo approval (the
/// `request_secret` call itself must reach the sheet ungated).
Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_secret_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: yolo
allowedTools: []
tui:
  classic: true  # pins the classic chrome this suite asserts (#97); band redesign #805-#807
''');
  return tempHome;
}

/// A tiny OpenAI-compatible SSE server: the first chat request answers with
/// a scripted `request_secret` tool call, every later one with plain text.
final class _SecretSheetMock {
  HttpServer? _server;
  final List<String> bodies = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      // The boot-time model-cache refresh must not consume a scripted turn.
      if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'object': 'list', 'data': []}));
        await request.response.close();
        return;
      }
      if (request.method != 'POST' ||
          !request.uri.path.endsWith('/chat/completions')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      bodies.add(body);
      final n = bodies.length - 1;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final chunks = n == 0 ? _secretToolCallChunks() : _textChunks();
      for (final chunk in chunks) {
        request.response.write('data: $chunk\n\n');
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  static List<String> _secretToolCallChunks() => [
    jsonEncode({
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'request_secret', 'arguments': ''},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'function': {
                  'arguments':
                      '{"name": "MY_SERVICE_TOKEN", "reason": "to call the '
                      'upstream API"}',
                },
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
      ],
    }),
  ];

  static List<String> _textChunks() => [
    jsonEncode({
      'id': 'chatcmpl-2',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'turn-complete'},
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
      ],
    }),
  ];
}
