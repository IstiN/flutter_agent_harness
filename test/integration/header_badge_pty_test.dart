@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #438 AC3 — the over-window badge: a mid-run auto-compaction that
/// frees the window shows «[auto-compacted · continuing]» in the TUI
/// status row while the run continues, and it clears when the turn
/// settles. A fresh follow-up run starts badge-free (E1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'pty_harness.dart';

void main() {
  test('a mid-run fold badges the status row until the turn settles', () async {
    final mock = _FoldingMock();
    await mock.start();
    final tempHome = _tempHomeForMock(mock.port);
    // Eight fat reads in one scripted turn (~21k estimated tokens of tool
    // results) blow the 16384-token capped window at the second request —
    // the guard refuses, the compaction folds the older results, the
    // retry continues the turn.
    final workspace = Directory.systemTemp.createTempSync('fa_badge_ws_');
    for (var i = 1; i <= 8; i++) {
      File(
        '${workspace.path}/big$i.txt',
      ).writeAsStringSync(List.filled(300, 'x' * 40).join('\n'));
    }
    final harness = await FaCliHarness.spawn(
      workingDirectory: workspace.path,
      extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
      await mock.close();
    });

    harness.sendText('count the words');
    harness.sendEnter();

    // The fold prints its receipt — and the badge must ride the status
    // row while the continuation turn streams (the slow final reply
    // widens the window so the frame is always catchable).
    await harness.waitForText(
      '● auto-compacted',
      timeout: const Duration(seconds: 60),
    );
    await harness.waitForText(
      '[auto-compacted · continuing]',
      timeout: const Duration(seconds: 30),
    );

    // Settled: the badge clears from the status row (the receipt stays).
    await harness.waitForText(
      'done: recovered',
      timeout: const Duration(seconds: 30),
    );
    await harness.waitForOutput(
      settleMs: 600,
      timeout: const Duration(seconds: 20),
    );
    expect(
      harness.screenText,
      isNot(contains('[auto-compacted · continuing]')),
      reason: 'the badge must clear when the turn settles',
    );

    // E1: a fresh run starts badge-free — no fold, no badge.
    harness.sendText('say hi');
    harness.sendEnter();
    await harness.waitForText('hi!', timeout: const Duration(seconds: 30));
    await harness.waitForOutput(
      settleMs: 600,
      timeout: const Duration(seconds: 20),
    );
    expect(
      harness.screenText,
      isNot(contains('[auto-compacted · continuing]')),
      reason: 'a fresh run without folds must never badge',
    );
  });
}

Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_badge_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: yolo
allowedTools: [read]
agent:
  contextWindowCap: 16384
''');
  return tempHome;
}

/// A tiny OpenAI-compatible SSE server scripting the fold scenario:
/// agent turns issue `read` tool calls, the hide-judge gets picks, the
/// checkpoint summarizer gets text, and the post-fold continuation reply
/// streams SLOWLY so the badge-on-screen window is catchable.
final class _FoldingMock {
  HttpServer? _server;
  var agentTurns = 0;

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
      if (request.method != 'POST') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();

      // The hide-judge: picks the oldest pairs (validation drops whatever
      // is protected — a no-op hide is fine for the badge scenario).
      if (body.contains('context-hygiene judge')) {
        await _sse(request, [_textChunk('[2]')]);
        return;
      }
      // The checkpoint/classic summarizer: the summary text.
      if (body.contains('<conversation>')) {
        await _sse(request, [
          _textChunk('checkpoint: the word-count investigation'),
        ]);
        return;
      }
      // Agent turns: two turns of eight parallel reads would be ideal,
      // but one turn carrying all eight reads already overflows the
      // 16384-token window at the second request. First agent turn: the
      // reads; the post-fold continuation (slow, so the badge frame is
      // catchable); anything later: plain quick replies.
      agentTurns++;
      if (agentTurns == 1) {
        await _sse(request, [_readsTurnChunk()]);
        return;
      }
      if (agentTurns == 2) {
        await _sse(request, [
          _textChunk('done: recovered'),
        ], delay: const Duration(milliseconds: 2500));
        return;
      }
      await _sse(request, [_textChunk('hi!')]);
    });
  }

  Map<String, Object> _textChunk(String text) => {
    'id': 'chatcmpl-x',
    'object': 'chat.completion.chunk',
    'choices': [
      {
        'index': 0,
        'delta': {'role': 'assistant', 'content': text},
        'finish_reason': null,
      },
    ],
  };

  /// One assistant turn with eight parallel `read` tool calls.
  Map<String, Object> _readsTurnChunk() => {
    'id': 'chatcmpl-x',
    'object': 'chat.completion.chunk',
    'choices': [
      {
        'index': 0,
        'delta': {
          'role': 'assistant',
          'tool_calls': [
            for (var i = 1; i <= 8; i++)
              {
                'index': i - 1,
                'id': 'call_$i',
                'type': 'function',
                'function': {
                  'name': 'read',
                  'arguments': '{"path": "big$i.txt"}',
                },
              },
          ],
        },
        'finish_reason': null,
      },
    ],
  };

  Future<void> _sse(
    HttpRequest request,
    List<Map<String, Object>> chunks, {
    Duration delay = Duration.zero,
  }) async {
    await Future<void>.delayed(delay);
    final response = request.response;
    response.headers.contentType = ContentType('text', 'event-stream');
    for (final chunk in chunks) {
      response.write('data: ${const JsonEncoder().convert(chunk)}\n\n');
    }
    response.write(
      'data: ${const JsonEncoder().convert({
        'id': 'chatcmpl-x',
        'object': 'chat.completion.chunk',
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
        ],
      })}\n\n',
    );
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
