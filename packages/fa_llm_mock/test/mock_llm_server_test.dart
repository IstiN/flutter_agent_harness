import 'dart:convert';
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

/// One parsed SSE chunk of a `/chat/completions` response.
List<Map<String, dynamic>> _sseChunks(String body) => [
  for (final frame in body.trim().split('\n\n'))
    if (frame.startsWith('data: ') && !frame.contains('[DONE]'))
      jsonDecode(frame.substring('data: '.length)) as Map<String, dynamic>,
];

void main() {
  late MockLlmServer server;
  late HttpClient client;

  setUp(() async {
    server = await MockLlmServer.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  /// POSTs an OpenAI-style chat request with [messages], returns the
  /// (status, raw body).
  Future<(int, String)> postChat(List<Map<String, Object>> messages) async {
    final request = await client.postUrl(
      Uri.parse('${server.baseUrl}/chat/completions'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'model': 'mock-model', 'messages': messages}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body);
  }

  test('enqueued tool call streams a tool_calls delta', () async {
    server.enqueueToolCall('bash', '{"command": "echo hi"}');

    final (status, body) = await postChat([
      {'role': 'user', 'content': 'run something'},
    ]);
    final chunks = _sseChunks(body);

    expect(status, 200);
    final delta = chunks.first['choices'].first['delta'];
    final call = delta['tool_calls'].first;
    expect(call['type'], 'function');
    expect(call['function']['name'], 'bash');
    expect(call['function']['arguments'], '{"command": "echo hi"}');
    expect(chunks.last['choices'].first['finish_reason'], 'tool_calls');
    expect(server.chatCalls, 1);
    expect(server.chatBodies.single, contains('run something'));
  });

  test('enqueued text streams a content delta with finish stop', () async {
    server.enqueueText('all done');

    final (status, body) = await postChat([
      {'role': 'user', 'content': 'hello'},
    ]);
    final chunks = _sseChunks(body);

    expect(status, 200);
    expect(chunks.first['choices'].first['delta']['content'], 'all done');
    expect(chunks.last['choices'].first['finish_reason'], 'stop');
    expect(body, endsWith('data: [DONE]\n\n'));
  });

  test('toolResultEcho quotes the last tool result content', () async {
    server.enqueueToolCall('bash', '{"command": "echo marker"}');
    server.enqueueToolResultEcho();

    // Request 1 consumes the scripted tool call; request 2 gets the echo.
    await postChat([
      {'role': 'user', 'content': 'run'},
      {'role': 'tool', 'content': 'marker-from-tool'},
    ]);
    final (_, body) = await postChat([
      {'role': 'user', 'content': 'run'},
      {'role': 'tool', 'content': 'marker-from-tool'},
    ]);
    final chunks = _sseChunks(body);

    expect(
      chunks.first['choices'].first['delta']['content'],
      'marker-from-tool',
    );
  });

  test('scripted scenario pops its queue on matching user message', () async {
    final scripted = await MockLlmServer.start(
      script: MockLlmScript.parse('''
model: scripted-model
responses:
  - text: fallback answer
scenarios:
  - match: "list the files"
    responses:
      - toolCall:
          name: bash
          arguments: '{"command": "ls"}'
      - toolResultEcho: true
      - text: listed
'''),
    );
    addTearDown(scripted.stop);
    final scriptedClient = HttpClient();
    addTearDown(scriptedClient.close);

    Future<(int, String)> scriptedPost(
      String user, [
      List<Map<String, Object>> extra = const [],
    ]) async {
      final request = await scriptedClient.postUrl(
        Uri.parse('${scripted.baseUrl}/chat/completions'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': 'mock-model',
          'messages': [
            {'role': 'user', 'content': user},
            ...extra,
          ],
        }),
      );
      final response = await request.close();
      return (
        response.statusCode,
        await response.transform(utf8.decoder).join(),
      );
    }

    // The matching scenario plays toolCall → toolResultEcho → text.
    var (status, body) = await scriptedPost('please list the files now');
    expect(status, 200);
    final call = _sseChunks(body).first['choices'].first['delta'];
    expect(call['tool_calls'].first['function']['name'], 'bash');

    // Like the real loop: the follow-up request carries the tool result,
    // which toolResultEcho quotes back.
    (status, body) = await scriptedPost('please list the files now', [
      {'role': 'tool', 'content': 'ls output'},
    ]);
    expect(
      _sseChunks(body).first['choices'].first['delta']['content'],
      'ls output',
    );

    (status, body) = await scriptedPost('please list the files now');
    expect(
      _sseChunks(body).first['choices'].first['delta']['content'],
      'listed',
    );

    // Matched but exhausted → 500, no fallthrough to the fallback.
    (status, body) = await scriptedPost('please list the files now');
    expect(status, 500);
    expect(body, contains('script exhausted'));

    // A non-matching message uses the fallback queue.
    (status, body) = await scriptedPost('something else entirely');
    expect(status, 200);
    expect(
      _sseChunks(body).first['choices'].first['delta']['content'],
      'fallback answer',
    );

    // The scripted model id rides the SSE metadata and /models.
    expect(body, contains('scripted-model'));
    final modelsRequest = await scriptedClient.getUrl(
      Uri.parse('${scripted.baseUrl}/models'),
    );
    final models = await modelsRequest.close();
    expect(
      await models.transform(utf8.decoder).join(),
      contains('scripted-model'),
    );
  });

  test('sticky scenario re-serves its last response past exhaustion', () async {
    // gh-1171: background-noise scenarios (memory auto-tag generation) fire
    // a schedule-dependent number of times; a sticky scenario answers every
    // extra call with its LAST scripted response instead of exhausting into
    // the 500-retry storm.
    final scripted = await MockLlmServer.start(
      script: MockLlmScript.parse('''
responses:
  - text: fallback answer
scenarios:
  - match: "noise"
    sticky: true
    responses:
      - text: noise-one
      - text: noise-last
  - match: "strict"
    responses:
      - text: strict-once
'''),
    );
    addTearDown(scripted.stop);
    final scriptedClient = HttpClient();
    addTearDown(scriptedClient.close);

    Future<String> content(String user) async {
      final request = await scriptedClient.postUrl(
        Uri.parse('${scripted.baseUrl}/chat/completions'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': 'm',
          'messages': [
            {'role': 'user', 'content': user},
          ],
        }),
      );
      final response = await request.close();
      expect(response.statusCode, 200, reason: 'sticky never exhausts');
      final body = await response.transform(utf8.decoder).join();
      return _sseChunks(body).first['choices'].first['delta']['content']
          as String;
    }

    // The queue plays in order, then the LAST response repeats forever.
    expect(await content('some noise'), 'noise-one');
    expect(await content('more noise'), 'noise-last');
    expect(await content('even more noise'), 'noise-last');
    expect(await content('noise again'), 'noise-last');

    // Sticky is per-scenario: the strict scenario plays its queue, then
    // still exhausts with 500 (a real conversation regression must keep
    // failing loudly), and the unmatched traffic still drains the fallback
    // queue — the sticky scenario never leaks into it.
    expect(await content('strict'), 'strict-once');
    final strictRequest = await scriptedClient.postUrl(
      Uri.parse('${scripted.baseUrl}/chat/completions'),
    );
    strictRequest.headers.contentType = ContentType.json;
    strictRequest.write(
      jsonEncode({
        'model': 'm',
        'messages': [
          {'role': 'user', 'content': 'strict'},
        ],
      }),
    );
    final strictResponse = await strictRequest.close();
    expect(strictResponse.statusCode, 500);
    expect(
      await strictResponse.transform(utf8.decoder).join(),
      contains('script exhausted'),
    );

    final fallbackRequest = await scriptedClient.postUrl(
      Uri.parse('${scripted.baseUrl}/chat/completions'),
    );
    fallbackRequest.headers.contentType = ContentType.json;
    fallbackRequest.write(
      jsonEncode({
        'model': 'm',
        'messages': [
          {'role': 'user', 'content': 'unmatched entirely'},
        ],
      }),
    );
    final fallbackResponse = await fallbackRequest.close();
    expect(fallbackResponse.statusCode, 200);
    final fallbackBody = await fallbackResponse.transform(utf8.decoder).join();
    expect(
      _sseChunks(fallbackBody).first['choices'].first['delta']['content'],
      'fallback answer',
    );
  });

  test('sticky scenario with no responses still exhausts', () async {
    final scripted = await MockLlmServer.start(
      script: MockLlmScript.parse('''
scenarios:
  - match: "noise"
    sticky: true
    responses: []
'''),
    );
    addTearDown(scripted.stop);
    final scriptedClient = HttpClient();
    addTearDown(scriptedClient.close);

    final request = await scriptedClient.postUrl(
      Uri.parse('${scripted.baseUrl}/chat/completions'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'model': 'm',
        'messages': [
          {'role': 'user', 'content': 'noise'},
        ],
      }),
    );
    final response = await request.close();
    expect(response.statusCode, 500);
    expect(
      await response.transform(utf8.decoder).join(),
      contains('script exhausted'),
    );
  });

  test('scripted error entry answers the requested status', () async {
    final scripted = await MockLlmServer.start(
      script: MockLlmScript.parse('''
responses:
  - error:
      status: 429
      message: mock rate limit
'''),
    );
    addTearDown(scripted.stop);
    final scriptedClient = HttpClient();
    addTearDown(scriptedClient.close);

    final request = await scriptedClient.postUrl(
      Uri.parse('${scripted.baseUrl}/chat/completions'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'model': 'm',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      }),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    expect(response.statusCode, 429);
    expect(body, contains('mock rate limit'));
  });

  test('exhausted programmatic script answers 500', () async {
    final (status, body) = await postChat([
      {'role': 'user', 'content': 'hello'},
    ]);
    expect(status, 500);
    expect(body, contains('script exhausted after 1 calls'));
  });

  test('unknown paths answer 404', () async {
    final request = await client.getUrl(Uri.parse('${server.baseUrl}/nope'));
    final response = await request.close();
    expect(response.statusCode, 404);
  });

  test(
    'client abort mid-request leaks no unhandled error, queue stays aligned '
    '(issue #1385)',
    () async {
      server.enqueueText('after the abort');
      // A client that dies mid-request the way a SIGKILLed CLI does
      // (steering PTY test phase 2: hardKill races the soft-yield turn's
      // request): headers declare a 64-byte body, 5 bytes arrive, then a
      // clean FIN. TCP orders data before EOF, so the server parser is
      // deterministically mid-body when the socket closes — the exact
      // shape that used to rethrow
      // `HttpException("Connection closed while receiving data",
      // uri: /v1/chat/completions)` out of the handler and into the test
      // zone as an unhandled error (the 2026-10-07 shard reds).
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.add(
        utf8.encode(
          'POST /v1/chat/completions HTTP/1.1\r\n'
          'Host: 127.0.0.1:${server.port}\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 64\r\n'
          '\r\n'
          '{"a":',
        ),
      );
      await socket.flush();
      await socket.close();
      // The abort surfaces asynchronously on the server side — pump the
      // event loop so a leaked (unhandled) error would land inside THIS
      // test: dart test fails the active test on any unhandled zone error,
      // which is precisely the leak this guard pins.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.abortedRequests, 1);
      socket.destroy();
      // The next, well-formed client is served the scripted response — the
      // aborted request consumed nothing from the queue.
      final (status, body) = await postChat([
        {'role': 'user', 'content': 'still here'},
      ]);
      expect(status, 200);
      expect(
        _sseChunks(body).first['choices'].first['delta']['content'],
        'after the abort',
      );
    },
  );

  test(
    'client abort mid-response leaks no unhandled error (issue #1385)',
    () async {
      server.enqueueText('doomed');
      server.enqueueText('next');
      // A full request whose client is gone by the time the response is
      // written — the other hardKill window (kill after dispatch, before
      // the CLI consumed the SSE bytes). An orderly close keeps the request
      // delivery deterministic (FIN never discards receive buffers, so the
      // server always parses the full body and pops the scripted entry)
      // while the response write races a closing socket — which must stay
      // a tolerated abort, never an unhandled zone error. Whether the
      // write itself errors is platform-timing, so only the LEAK and the
      // queue alignment are pinned here.
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.add(
        utf8.encode(
          'POST /v1/chat/completions HTTP/1.1\r\n'
          'Host: 127.0.0.1:${server.port}\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${'{"a":1}'.length}\r\n'
          '\r\n'
          '{"a":1}',
        ),
      );
      await socket.flush();
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.destroy();
      // The full request dispatched, so its scripted response is spent;
      // the next client gets the following scripted entry.
      final (status, body) = await postChat([
        {'role': 'user', 'content': 'still here'},
      ]);
      expect(status, 200);
      expect(
        _sseChunks(body).first['choices'].first['delta']['content'],
        'next',
      );
    },
  );
}
