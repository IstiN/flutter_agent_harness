@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #355 — the Shift+Enter HID gate must never cost the REPL its
/// interactivity: with the SSH session env injected, the first Enter still
/// submits against a mock provider and Ctrl+C still quits the process
/// bounded; the FA_TUI_SHIFT_HID=0 kill switch keeps the submit path
/// intact without SSH env. Drives the REAL binary over a PTY (see
/// pty_harness.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  late _EchoMock mock;
  late Directory tempHome;

  setUp(() async {
    mock = _EchoMock();
    await mock.start();
    tempHome = _tempHomeForMock(mock.port);
  });

  tearDown(() async {
    await mock.close();
    tempHome.deleteSync(recursive: true);
  });

  Future<FaCliHarness> spawnFa(Map<String, String> extraEnv) {
    return FaCliHarness.spawn(extraEnv: {'HOME': tempHome.path, ...extraEnv});
  }

  test('SSH session env: the first Enter submits and Ctrl+C quits', () async {
    final fa = await spawnFa({
      'SSH_CONNECTION': '10.0.0.1 52222 10.0.0.2 22',
      'SSH_TTY': '/dev/ttys004',
    });
    try {
      await fa.waitForBoot();
      fa.sendText('gate-echo-marker');
      fa.sendEnter();
      await fa.waitForText(
        'gate-echo-marker-reply',
        timeout: const Duration(seconds: 30),
      );
      fa.sendCtrlC();
      final code = await fa.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => -1,
      );
      expect(code, anyOf(0, 130), reason: 'Ctrl+C must quit the REPL');
    } finally {
      await fa.close();
    }
  });

  test(
    'FA_TUI_SHIFT_HID=0 without SSH env: submit path stays intact',
    () async {
      final fa = await spawnFa({'FA_TUI_SHIFT_HID': '0'});
      try {
        await fa.waitForBoot();
        fa.sendText('kill-switch-marker');
        fa.sendEnter();
        await fa.waitForText(
          'kill-switch-marker-reply',
          timeout: const Duration(seconds: 30),
        );
      } finally {
        await fa.close();
      }
    },
  );
}

/// Creates a temp HOME pointing at the local mock with yolo approval.
Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_ssh_gate_');
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

/// A tiny OpenAI-compatible SSE server answering every chat request with
/// the last user message echoed back with a `-reply` suffix — the reply
/// text proves the submit traveled composer → provider → output.
final class _EchoMock {
  HttpServer? _server;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      // The boot-time model-cache refresh must not hit the chat path.
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
      final messages =
          (jsonDecode(body) as Map<String, dynamic>)['messages']
              as List<dynamic>;
      final lastUser =
          messages.lastWhere(
                (message) =>
                    (message as Map<String, dynamic>)['role'] == 'user',
                orElse: () => <String, dynamic>{'content': 'boot'},
              )
              as Map<String, dynamic>;
      final content = lastUser['content'];
      final text = content is String
          ? content
          : (content as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .where((block) => block['type'] == 'text')
                .map((block) => block['text'] as String)
                .join(' ');
      final chunk = jsonEncode({
        'id': 'chatcmpl-1',
        'object': 'chat.completion.chunk',
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': '$text-reply'},
            'finish_reason': null,
          },
        ],
      });
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.add(utf8.encode('data: $chunk\n\n'));
      request.response.add(utf8.encode('data: [DONE]\n\n'));
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
