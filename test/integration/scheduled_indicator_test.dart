@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #115: the CLI interactive mode (TUI) visualizes pending scheduled
/// follow-up messages (`schedule_message`) on top of the "Working…" row —
/// and keeps showing them while idle until they fire.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test('a scheduled follow-up shows on top of the working row, persists '
      'while idle, and clears when it fires', () async {
    final mock = _SchedulingMock();
    await mock.start();
    final tempHome = _tempHomeForMock(mock.port);
    final harness = await FaCliHarness.spawn(
      extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
      await mock.close();
    });
    // Turn 1: the scripted answer schedules a follow-up 20s out — long
    // enough that the idle-persistence assert below always lands BEFORE
    // the fire, even on a cold run.
    harness.sendText('set a reminder');
    harness.sendEnter();

    // The pending indicator appears as soon as the record exists — while
    // the run is still streaming.
    await harness.waitForText(
      '⏰ 1 scheduled',
      timeout: const Duration(seconds: 30),
    );
    await harness.waitForText(
      'turn-complete',
      timeout: const Duration(seconds: 30),
    );

    // The run settled; the indicator persists while idle (the reminder has
    // not fired yet — its whole point is to stay visible).
    await harness.waitForOutput(settleMs: 300);
    expect(harness.screenText, contains('⏰ 1 scheduled'));

    // The record fires; the wake turn carries the [scheduled] mail.
    await harness.waitForText(
      '[sched] fired:',
      timeout: const Duration(seconds: 45),
    );

    expect(
      mock.bodies.any((b) => b.contains('[scheduled]')),
      isTrue,
      reason: 'the fired reminder must reach the model as mail',
    );

    // Delivery consumes the record: the indicator clears.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (harness.screenText.contains('⏰') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      harness.screenText,
      isNot(contains('⏰')),
      reason: 'a fired follow-up must not stay on the indicator',
    );
  });
}

/// Temp HOME pointing at the local mock; yolo so the `schedule_message`
/// write-tier call executes without an approval prompt.
Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_sched_');
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

/// A tiny OpenAI-compatible SSE server: the first chat request answers
/// with a scripted `schedule_message` tool call (3s delay), every later
/// one with a plain text answer.
final class _SchedulingMock {
  HttpServer? _server;
  final List<String> bodies = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      // The boot-time model-cache refresh must not consume a scripted
      // chat turn.
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
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final chunks = bodies.length == 1 ? _scheduleCallChunks() : _textChunks();
      for (final chunk in chunks) {
        // A blank line terminates each SSE event — without it the decoder
        // concatenates every data line into one unreadable payload.
        request.response.write('data: $chunk\n\n');
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  static List<String> _scheduleCallChunks() => [
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
                'function': {'name': 'schedule_message', 'arguments': ''},
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
                  'arguments': '{"text": "check the build", "delay": "20s"}',
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
