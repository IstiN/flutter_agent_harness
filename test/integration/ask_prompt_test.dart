@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #109 — the TUI ask prompt did not clear the previous answer when a
/// new question opened, and the answer box borders tore apart whenever a
/// body/input row exceeded the terminal width (one over-wide row wraps in
/// the real terminal and desyncs the diff renderer). These tests drive the
/// REAL binary over a PTY against a fake openai-completions endpoint
/// scripted to emit a two-question `ask` tool call, type a long free-text
/// answer, and assert the frame stays inside the terminal at every step.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('TUI ask prompt (issue #109)', () {
    late _AskMock mock;
    late Directory tempHome;
    late FaCliHarness harness;

    setUp(() async {
      mock = _AskMock();
      await mock.start();
      tempHome = _tempHomeForMock(mock.port);
      harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
      );
    });

    tearDown(() async {
      await harness.close();
      if (!Platform.environment.containsKey('FA_KEEP_HOME')) {
        tempHome.deleteSync(recursive: true);
      }
      await mock.close();
    });

    /// Boots the REPL and sends a message whose scripted answer is the
    /// two-question `ask` tool call, leaving question 1 open.
    Future<void> openAsk() async {
      await harness.waitForBoot();
      harness.sendText('ask me two things');
      harness.sendEnter();
      await harness.waitForText(
        'Question 1 of 2',
        // The first PTY boot in the suite pays the VM warm-up.
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 300);
    }

    /// The long free-text answer typed into question 1 (owner-style: a
    /// sentence far longer than the 80-column terminal).
    final longAnswer =
        'только flutter app, extension в cli такого не делаем, там надо '
        'будет думать другую форму и ещё немного текста чтобы переливаться '
        'через правую границу рамки ввода ответа';
    // Row-sized fragments: the frame hard-wraps the buffer, so whole-answer
    // containment never holds on a wrapped screen and even a 40-char phrase
    // can straddle a wrap boundary.
    final answerHead = 'только flutter app, extension';
    final answerTail = 'рамки ввода ответа';

    test(
      'IT-stale: question 2 opens with an empty, intact answer box',
      () async {
        await openAsk();
        // Free-text a LONG answer into question 1 and submit it.
        harness.sendText(' ');
        await harness.waitForText('Type your answer');
        harness.sendText(longAnswer);
        await harness.waitForOutput(settleMs: 300);
        expect(
          harness.screenText.contains(answerTail),
          isTrue,
          reason: 'precondition: the typed answer is visible before submit',
        );
        harness.sendEnter();
        await harness.waitForText('Question 2 of 2');
        await harness.waitForOutput(settleMs: 300);

        // The previous answer is gone from the whole screen — the new
        // question's frame repainted every row it covers.
        expect(
          harness.screenText.contains(answerHead) ||
              harness.screenText.contains(answerTail),
          isFalse,
          reason: 'the previous answer stayed visible in the new prompt',
        );
        // …and the new frame is intact: a bordered box with an empty input.
        final lines = harness.screenLines;
        final question2 = lines.indexWhere(
          (l) => l.contains('Question 2 of 2'),
        );
        expect(question2, greaterThanOrEqualTo(0));
        final frame = lines.sublist(question2);
        expect(
          frame.any((l) => l.trim().startsWith('└') && l.trim().endsWith('┘')),
          isTrue,
          reason: 'the answer box lost its bottom border',
        );
        // The input zone opens EMPTY: a plain cursor row, not the previous
        // answer (question 2 opens in single-select mode, so the hint row
        // names navigation, not typing).
        expect(
          frame.any((l) => l.contains('↑/↓ navigate')),
          isTrue,
          reason: 'the select-mode hint row is missing',
        );
        expect(
          frame.any((l) => l.contains(answerHead)),
          isFalse,
          reason: 'the new prompt prefilled the previous answer',
        );
      },
    );

    test('IT-borders: a long answer stays inside the frame', () async {
      await openAsk();
      harness.sendText(' ');
      await harness.waitForText('Type your answer');
      harness.sendText(longAnswer);
      await harness.waitForOutput(settleMs: 300);

      // Every rendered row fits the 80-column terminal: an over-wide row
      // wraps and tears the borders (the issue screenshot).
      for (final line in harness.viewportLines) {
        expect(
          line.length,
          lessThanOrEqualTo(harness.columns),
          reason: 'row overflows the terminal: "$line"',
        );
      }
      final lines = harness.screenLines;
      final question1 = lines.indexWhere((l) => l.contains('Question 1 of 2'));
      // Start one row up: the top border line sits right above the header.
      final frame = lines.sublist((question1 - 1).clamp(0, lines.length - 1));
      expect(
        frame.any((l) => l.trim().startsWith('┌') && l.trim().endsWith('┐')),
        isTrue,
        reason: 'the ask box lost its top border',
      );
      expect(
        frame.any((l) => l.trim().startsWith('└') && l.trim().endsWith('┘')),
        isTrue,
        reason: 'the ask box lost its bottom border',
      );
      // The tail of the long answer stays visible INSIDE the box.
      expect(frame.join('\n'), contains(answerTail));
    });

    test('IT-roundtrip: both answers reach the mocked LLM', () async {
      await openAsk();
      harness.sendText(' '); // free text for question 1
      await harness.waitForText('Type your answer');
      harness.sendText('сначала приложение');
      harness.sendEnter();
      await harness.waitForText('Question 2 of 2');
      harness.sendText('2'); // digit-pick option 2 for question 2
      await harness.waitForText(
        'turn-complete',
        timeout: const Duration(seconds: 30),
      );

      // Background calls interleave; select the REAL chat turns (they carry
      // the Fa system prompt).
      final realTurns = mock.bodies
          .where((b) => b.contains('You are Fa, a coding agent'))
          .toList();
      expect(realTurns.length, greaterThanOrEqualTo(2));
      final followUp = jsonDecode(realTurns[1]) as Map<String, dynamic>;
      final messages = followUp['messages'] as List;
      final transcript = messages
          .map((m) => (m as Map<String, dynamic>)['content'])
          .join(' ');
      expect(transcript, contains('сначала приложение'));
      expect(transcript, contains('CLI only'));
    });
  });
}

/// Creates a temp HOME pointing at the local mock with yolo approval.
Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_ask_');
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
/// a scripted two-question `ask` tool call, every later one with plain text.
final class _AskMock {
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
      // Content-aware routing: the boot fires background LLM calls (the
      // durable-memory summarizer) that must not consume the scripted ask
      // turn, and the follow-up turn already carries the tool result.
      final isBackgroundCall = body.contains('Read the memory records');
      final hasAskResult = body.contains('User answers:');
      final chunks = !isBackgroundCall && !hasAskResult
          ? _askToolCallChunks()
          : _textChunks();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      // Scripted answers contain Cyrillic: HttpResponse.write rejects
      // non-Latin-1 strings, so the SSE frames go out as UTF-8 bytes.
      for (final chunk in chunks) {
        request.response.add(utf8.encode('data: $chunk\n\n'));
      }
      request.response.add(utf8.encode('data: [DONE]\n\n'));
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  static List<String> _askToolCallChunks() => [
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
                'function': {'name': 'ask', 'arguments': ''},
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
                    'questions': [
                      {
                        'question':
                            'Какую поверхность поддерживаем в первой версии?',
                        'options': [
                          {
                            'label': 'Flutter app + extension',
                            'description':
                                'Виджеты живут в чат-аппи и панели расширения; '
                                'в CLI динамическое сообщение деградирует в '
                                'текстовое представление (та же data-модель, '
                                'плоский рендер) и это нормально для '
                                'текстового терминала без интерактива.',
                          },
                          {'label': 'CLI only'},
                        ],
                        'recommended': 0,
                      },
                      {
                        'question': 'Что делаем следующим шагом?',
                        'options': [
                          {'label': 'Wireframe'},
                          {'label': 'CLI only'},
                        ],
                      },
                    ],
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
