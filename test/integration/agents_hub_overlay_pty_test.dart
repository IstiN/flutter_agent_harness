@TestOn('vm')
@Tags(['integration', 'pty'])
@Timeout(Duration(minutes: 5))
library;

// Issue #382 AC4, end to end over a real PTY: with the hub armed once and
// then closed, a chat-idle agent spawns a background child via the task
// tool — the child's spawn/settle events must not push the overlay open.
// A manual `/agents` afterwards still opens the tree with the child in it.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'child spawn/settle events never force the closed hub open; '
    '/agents live-refreshes afterwards (issue #382)',
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final mock = _TaskSpawnMock();
      await mock.start();
      addTearDown(mock.close);
      final tempHome = Directory.systemTemp.createTempSync('fa_hub_guard_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:${mock.port}/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
      addTearDown(() => tempHome.deleteSync(recursive: true));

      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(harness.close);
      // Generous: a loaded box (sibling test loops) can take minutes to
      // jit the entrypoint; the 90s default misreads that as a dead boot.
      await harness.waitForBoot(timeout: const Duration(seconds: 300));

      // Open the hub once (arms the event subscription), then close it.
      await harness.runSlashCommand('/agents');
      await harness.waitForText('agents hub');
      harness.sendEscape();
      await harness.waitForOutput(settleMs: 300);
      final closedMark = harness.rawOutput.length;

      // Chat idle → the scripted turn spawns one child via the task tool.
      // The child runs its own model turn and settles: spawn + settle
      // events fire while the overlay is closed.
      harness.sendText('Spawn a scout.');
      harness.sendEnter();
      await harness.waitForText(
        'scout-settled',
        // Generous like the boot wait above: the settle chain (child
        // spawn, its own model turn, the parent re-wake run) first-touches
        // large JIT units, and a loaded nightly box (sibling test loops,
        // 2-core runners) can stretch it past a tighter default.
        timeout: const Duration(seconds: 300),
      );

      // Zero overlay pushes since the close: no hub frame, even though
      // child events landed throughout the run.
      expect(
        harness.rawOutput.substring(closedMark),
        isNot(contains('agents hub')),
        reason: 'child events must not force the closed hub open',
      );

      // The user opens the hub: bare /agents still opens (AC5) and the
      // tree carries the spawned child — the live feature still works.
      await harness.runSlashCommand('/agents');
      await harness.waitForText('agents hub');
      expect(harness.screenText, contains('scout'));

      harness.sendCtrlC();
      await harness.waitForOutput(settleMs: 300);
    },
  );
}

/// A tiny OpenAI-compatible SSE mock: request 1 (the main agent) answers
/// with a scripted `task` tool call, request 2 (the child's own turn) with
/// plain text, and request 3+ (the main agent's post-tool turn) with the
/// settle text the test waits for.
final class _TaskSpawnMock {
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
      final n = bodies.length - 1;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final chunks = switch (n) {
        0 => _taskCallChunks(),
        1 => _textChunks(),
        _ => _settleChunks(),
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

  static List<String> _taskCallChunks() => [
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
                'function': {'name': 'task', 'arguments': ''},
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
                      '{"context": "pty guard test", "tasks": [{"name": '
                      '"scout", "agent": "explore", "task": "look around"}]}',
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

  static List<String> _settleChunks() => [
    jsonEncode({
      'id': 'chatcmpl-3',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'scout-settled'},
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
