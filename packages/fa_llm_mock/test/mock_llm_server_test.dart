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
}
