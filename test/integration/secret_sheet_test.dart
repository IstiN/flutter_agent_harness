@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
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
      await harness.waitForBoot();
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
        final nameLine = harness.screenLines.singleWhere(
          (l) => l.contains('MY_SERVICE_TOKEN'),
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

    test('IT-mask: the secret is masked from the first keystroke', () async {
      await openSheet();
      harness.sendText('s3cr3t-TOKEN-42');
      await harness.waitForText('•••••', timeout: const Duration(seconds: 10));
      await harness.waitForOutput(settleMs: 300);
      // The security pin: no rendered frame — raw or on-screen — may ever
      // carry the secret's bytes.
      expect(
        harness.rawOutput.contains('s3cr3t-TOKEN-42'),
        isFalse,
        reason: 'the secret bytes appeared in the raw PTY output',
      );
      expect(harness.screenText.contains('s3cr3t-TOKEN-42'), isFalse);
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
        harness.sendText('s3cr3t-TOKEN-42');
        await harness.waitForText(
          '•••••',
          timeout: const Duration(seconds: 10),
        );
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
        harness.sendText('s3cr3t-TOKEN-42');
        await harness.waitForText(
          '•••••',
          timeout: const Duration(seconds: 10),
        );
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
