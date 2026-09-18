@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #367 — a foreground bash command that hits a password ask
/// (`[sudo] password for user:`) opens the TUI's masked prompt; the typed
/// value streams to the live process stdin and never reaches any rendered
/// frame or the session transcript. Drives the REAL binary over a PTY
/// against a fake openai-completions endpoint scripted to emit a `bash`
/// tool call whose command prints the ask and blocks reading a stdin line.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('TUI password prompt (issue #367)', () {
    late _PasswordAskMock mock;
    late Directory tempHome;
    late FaCliHarness harness;

    setUp(() async {
      mock = _PasswordAskMock();
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

    test(
      'IT-e2e: ask opens the masked prompt, stdin feeds the process, '
      'no secret bytes anywhere',
      () async {
        await harness.waitForBoot();
        harness.sendText('install the thing');
        harness.sendEnter();
        // The bash command prints the ask on stderr, then blocks on `head`
        // until the detector fired, the answer was typed, and the value
        // was written to the live process stdin.
        await harness.waitForText(
          'Password',
          timeout: const Duration(seconds: 60),
        );
        const secret = 'pt-E2E-secret-9';
        harness.sendText(secret);
        await harness.waitForText('•••••', timeout: const Duration(seconds: 10));
        // Security pin: no rendered frame — raw or on-screen — may carry
        // the password bytes.
        expect(harness.rawOutput.contains(secret), isFalse);
        expect(harness.screenText.contains(secret), isFalse);
        harness.sendEnter();
        // The write unblocks `head`; the command finishes and the turn
        // completes on the scripted follow-up.
        await harness.waitForText(
          'PWD-FED-OK',
          timeout: const Duration(seconds: 60),
        );
        await harness.waitForText(
          'turn-complete',
          timeout: const Duration(seconds: 60),
        );
        // The follow-up request (tool result + transcript) never carries
        // the secret either — only the command's own output marker.
        final followUp = mock.bodies[1];
        expect(followUp.contains('PWD-FED-OK'), isTrue);
        expect(followUp.contains(secret), isFalse);
        expect(harness.rawOutput.contains(secret), isFalse);
      },
    );
  });
}

Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_password_');
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
/// a scripted `bash` tool call that prints a sudo ask and blocks on stdin,
/// every later one with plain text.
final class _PasswordAskMock {
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
      final chunks = n == 0 ? _bashToolCallChunks() : _textChunks();
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

  static List<String> _bashToolCallChunks() => [
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
                'function': {'name': 'bash', 'arguments': ''},
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
                  'arguments': jsonEncode({
                    'command':
                        "printf '[sudo] password for user: ' >&2; "
                        'head -n 1 >/dev/null; echo PWD-FED-OK',
                  }),
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
