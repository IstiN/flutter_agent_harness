@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #97 residual — the original three defects were fixed in PR #98, but
/// the owner reopened the ticket after #109 surfaced prompt-frame rendering
/// defects. These tests pin the SECRET-sheet-specific residue on current main:
///
/// RT1 two consecutive `request_secret` sheets in one session — the second
///     (shorter) frame must fully replace the first: no leaked value dots, no
///     ghost rows of the first sheet's content, aligned borders.
/// RT2 the Enter-reason row grows then shrinks the frame — after it clears,
///     the vacated row must be gone (no ghost error text, aligned borders).
/// RT3 a name exactly as wide as the sheet interior — the frame must stay
///     intact (no torn or short-closed rows).
/// RT4 a multiline paste (PEM-style) — frame intact, value granted verbatim.
/// RT5 an over-wide paste — every frame row stays inside the terminal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  late _ResidualMock mock;
  late Directory tempHome;
  late FaCliHarness harness;

  setUp(() async {
    mock = _ResidualMock();
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

  /// Boots the REPL and sends a message whose scripted answer is the first
  /// `request_secret` tool call.
  Future<void> bootAndRequest() async {
    await harness.waitForBoot();
    harness.sendText('need the key');
    harness.sendEnter();
    await harness.waitForText(
      'Credential request',
      timeout: const Duration(seconds: 60),
    );
    await harness.waitForOutput(settleMs: 300);
  }

  /// Every rendered line must fit the terminal width, and every frame row
  /// (between ┌ and └ inclusive) must close with its border glyph at the
  /// ┌ row's right edge — no wrapped, torn, or short-closed rows.
  void expectFrameIntact() {
    final lines = harness.viewportLines
        .map((l) => l.replaceAll(RegExp(r'\x1b\[[0-9;?]*[a-zA-Z]'), ''))
        .toList();
    final top = lines.indexWhere((l) => l.startsWith('┌'));
    final bottom = lines.lastIndexWhere((l) => l.startsWith('└'));
    expect(top, isNonNegative, reason: 'no secret-sheet frame on screen');
    expect(bottom, greaterThan(top), reason: 'frame never closed');
    final expectedWidth = lines[top].trimRight().length;
    for (final row in lines.sublist(top, bottom + 1)) {
      final t = row.trimRight();
      expect(
        t.length,
        expectedWidth,
        reason: 'frame row "$t" is ${t.length} cols, expected $expectedWidth',
      );
      expect(
        t.endsWith('┐') ||
            t.endsWith('┤') ||
            t.endsWith('│') ||
            t.endsWith('┘'),
        isTrue,
        reason: 'frame row "$t" does not close with a border glyph',
      );
    }
  }

  test('RT1: a second, shorter sheet fully replaces the first', () async {
    await bootAndRequest();
    harness.sendText('s3cr3t-TOKEN-42');
    await harness.waitForText('•••••', timeout: const Duration(seconds: 10));
    harness.sendEnter(); // grant #1 -> mock turn 2 requests another secret
    await harness.waitForText(
      'OTHER_API_KEY',
      timeout: const Duration(seconds: 20),
    );
    await harness.waitForOutput(settleMs: 500);

    // The second sheet starts with an EMPTY value buffer: no dots from the
    // first sheet's secret may linger in the frame.
    expect(
      harness.screenText.contains('•'),
      isFalse,
      reason: 'the second sheet shows value dots from the first secret',
    );
    // The first sheet's reason text must be fully gone: the second frame is
    // shorter, so a stale row would survive BELOW or INSIDE it.
    expect(
      harness.screenText.contains('the upstream API'),
      isFalse,
      reason: 'ghost of the first sheet is still on screen',
    );
    expectFrameIntact();

    // And the second sheet is a live, submittable sheet.
    harness.sendText('second-secret');
    await harness.waitForText('•••••', timeout: const Duration(seconds: 10));
    harness.sendEnter();
    await harness.waitForText(
      'turn-complete',
      timeout: const Duration(seconds: 30),
    );
  });

  test(
    'RT2: the blocked-Enter reason row leaves no ghost when it clears',
    () async {
      await bootAndRequest();
      harness.sendEnter(); // blocked: the reason row appears (+1 frame row)
      await harness.waitForText(
        'Type the value first',
        timeout: const Duration(seconds: 10),
      );
      harness.sendText(
        'x',
      ); // value typed: the reason row clears (-1 frame row)
      await harness.waitForText('•', timeout: const Duration(seconds: 10));
      await harness.waitForOutput(settleMs: 500);

      expect(
        harness.screenText.contains('Type the value first'),
        isFalse,
        reason: 'the Enter reason row is still on screen after clearing',
      );
      expectFrameIntact();
    },
  );

  test(
    'RT3: a name exactly as wide as the sheet interior keeps borders aligned',
    () async {
      mock.nextName = 'A' * 76; // '▸ ' + name == inner width at an 80-col PTY
      await bootAndRequest();
      await harness.waitForOutput(settleMs: 500);
      expectFrameIntact();
      harness.sendEscape();
      await harness.waitForText(
        'turn-complete',
        timeout: const Duration(seconds: 30),
      );
    },
    skip:
        'exact-width frame arithmetic is issue #109 '
        '(fix on fix/109-tui-answer-clear); unskip after rebasing on it',
  );

  test(
    'RT4: a multiline paste keeps the frame intact and the value intact',
    () async {
      await bootAndRequest();
      // Bracketed paste: the PTY input path a password manager actually uses.
      harness.sendText(
        '\x1b[200~-----BEGIN KEY-----\nabc123\n-----END KEY-----\x1b[201~',
      );
      await harness.waitForText('•••••', timeout: const Duration(seconds: 10));
      await harness.waitForOutput(settleMs: 500);
      expectFrameIntact();
      // Masked mode: no byte of the secret may reach the screen or the raw
      // output (the input stream itself is not echoed).
      expect(harness.screenText.contains('BEGIN KEY'), isFalse);
      harness.sendEnter();
      // The mock scripts a second request (turn 2); decline it to finish.
      await harness.waitForText(
        'OTHER_API_KEY',
        timeout: const Duration(seconds: 20),
      );
      // End-to-end grant integrity: the turn-2 request carries the grant
      // CONFIRMATION - the transcript never carries the value itself
      // (redaction by design). CR must not survive anywhere near it.
      final turn2 = jsonDecode(mock.bodies[1]) as Map<String, dynamic>;
      final transcript = (turn2['messages'] as List)
          .map((m) => ((m as Map<String, dynamic>)['content'] ?? '').toString())
          .join(' ');
      expect(transcript, contains('Secret MY_SERVICE_TOKEN is available'));
      expect(
        transcript.contains('\r'),
        isFalse,
        reason: 'CR is a paste artifact',
      );
      harness.sendEscape();
      await harness.waitForText(
        'turn-complete',
        timeout: const Duration(seconds: 30),
      );
    },
  );

  test(
    'RT5: an over-wide paste keeps every frame row inside the terminal',
    () async {
      await bootAndRequest();
      harness.sendText('\x1b[200~${'k' * 200}\x1b[201~');
      await harness.waitForText('•••••', timeout: const Duration(seconds: 10));
      await harness.waitForOutput(settleMs: 500);
      expectFrameIntact();
      harness.sendEscape();
      await harness.waitForText(
        'turn-complete',
        timeout: const Duration(seconds: 30),
      );
    },
    skip:
        'exact-width frame arithmetic is issue #109 '
        '(fix on fix/109-tui-answer-clear); unskip after rebasing on it',
  );
}

Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_secret_res_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
  return tempHome;
}

/// OpenAI-compatible SSE mock. Turn 0: `request_secret` for MY_SERVICE_TOKEN
/// (long reason -> tall frame). Turn 1: `request_secret` for OTHER_API_KEY
/// (short reason -> shorter frame). Later turns: plain text.
final class _ResidualMock {
  HttpServer? _server;
  final List<String> bodies = [];

  /// Overrides the suggested secret name of the FIRST tool call.
  String? nextName;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
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
      final chunks = switch (n) {
        0 => _secretChunks(
          'call_1',
          nextName ?? 'MY_SERVICE_TOKEN',
          // Keep the reason short of the frame interior width: an
          // exactly-full wrapped chunk trips the #109 width bug, which is
          // pinned (and skipped) by RT3/RT5, not by the paste tests.
          'to call the upstream API and the nightly deploy job',
        ),
        1 => _secretChunks('call_2', 'OTHER_API_KEY', 'for the other service'),
        _ => _textChunks(),
      };
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

  static List<String> _secretChunks(
    String callId,
    String name,
    String reason,
  ) => [
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
                'id': callId,
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
                  'arguments': jsonEncode({'name': name, 'reason': reason}),
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
