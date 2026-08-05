import 'dart:convert';
import 'dart:io';

import 'package:fa_llm/src/openai_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('sends correct OpenAI chat completions payload', () async {
    late Map<String, dynamic> capturedBody;
    final client = MockClient((request) async {
      expect(
        request.headers[HttpHeaders.authorizationHeader],
        'Bearer test-key',
      );
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'Hello'},
            },
          ],
        }),
        200,
      );
    });

    final provider = OpenAiProvider(
      apiKey: 'test-key',
      defaultModel: 'gpt-4',
      temperature: 0.5,
      maxTokens: 1024,
      client: client,
    );

    final response = await provider.chat('Say hi');
    expect(response, 'Hello');
    expect(capturedBody['model'], 'gpt-4');
    expect(capturedBody['temperature'], 0.5);
    expect(capturedBody['max_completion_tokens'], 1024);
    expect(capturedBody['messages'], [
      {'role': 'user', 'content': 'Say hi'},
    ]);
  });

  test('omits temperature when negative', () async {
    late Map<String, dynamic> capturedBody;
    final client = MockClient((request) async {
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': ''},
            },
          ],
        }),
        200,
      );
    });

    final provider = OpenAiProvider(
      apiKey: 'test-key',
      defaultModel: 'gpt-4',
      client: client,
    );
    await provider.chat('x');
    expect(capturedBody.containsKey('temperature'), isFalse);
  });
}
