import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

final chatGptModel = Model(
  id: 'gpt-5-codex',
  api: 'responses',
  provider: 'chatgpt',
  baseUrl: chatGptCodexBaseUrl,
  input: const ['text'],
  contextWindow: 128000,
  maxTokens: 16384,
);

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

const credentials = ChatGptOAuthCredentials(
  accessToken: 'at-1',
  refreshToken: 'rt-1',
  idToken: 'it-1',
  accountId: 'acc-1',
);

String sseChunk(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

http.Client sseClient(String body) => http_testing.MockClient.streaming(
  (request, requestBody) async => http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    200,
    headers: {'content-type': 'text/event-stream'},
  ),
);

/// A 200 SSE response wrapping [body].
http.StreamedResponse sseResponse(String body) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  200,
  headers: {'content-type': 'text/event-stream'},
);

/// Mock streaming client popping one queued response per request and
/// recording each request's headers into [sentHeaders].
http.Client queueClient(
  List<Map<String, String>> sentHeaders,
  List<http.StreamedResponse> responses,
) => http_testing.MockClient.streaming((request, requestBody) async {
  sentHeaders.add(Map.of(request.headers));
  return responses.removeAt(0);
});

void main() {
  group('streamChatGptCodex', () {
    test('streams text deltas, usage and a done event', () async {
      final body =
          sseChunk({
            'type': 'response.created',
            'response': {'id': 'resp_1', 'model': 'gpt-5-codex'},
          }) +
          sseChunk({'type': 'response.output_text.delta', 'delta': 'Hel'}) +
          sseChunk({'type': 'response.output_text.delta', 'delta': 'lo'}) +
          sseChunk({'type': 'response.output_text.done'}) +
          sseChunk({
            'type': 'response.completed',
            'response': {
              'id': 'resp_1',
              'model': 'gpt-5-codex',
              'usage': {
                'input_tokens': 10,
                'output_tokens': 2,
                'total_tokens': 12,
              },
            },
          });

      final stream = streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: sseClient(body),
      );
      final events = await stream.toList();

      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas, hasLength(2));
      expect(deltas[0].delta, 'Hel');
      expect(deltas[1].delta, 'lo');
      expect(events.whereType<TextEndEvent>().single.content, 'Hello');

      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.stop);
      expect(done.message.responseId, 'resp_1');
      expect(done.message.usage.input, 10);
      expect(done.message.usage.output, 2);
    });

    test('streams tool calls and ends with toolUse', () async {
      final body =
          sseChunk({
            'type': 'response.function_call_arguments.delta',
            'call_id': 'call_1',
            'name': 'bash',
            'delta': '{"cmd',
          }) +
          sseChunk({
            'type': 'response.function_call_arguments.delta',
            'call_id': 'call_1',
            'name': 'bash',
            'delta': '":"ls"}',
          }) +
          sseChunk({'type': 'response.function_call_arguments.done'});

      final stream = streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: sseClient(body),
      );
      final events = await stream.toList();

      expect(events.whereType<ToolCallStartEvent>(), hasLength(1));
      expect(events.whereType<ToolCallDeltaEvent>(), hasLength(2));
      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.toolUse);
      final toolCall = done.message.content.whereType<ToolCall>().single;
      expect(toolCall.name, 'bash');
      expect(toolCall.arguments, {'cmd': 'ls'});
    });

    test('sends Codex transport headers and store:false body', () async {
      Map<String, dynamic>? sentBody;
      Map<String, String>? sentHeaders;
      final client = http_testing.MockClient.streaming((
        request,
        requestBody,
      ) async {
        sentBody =
            jsonDecode(await requestBody.bytesToString())
                as Map<String, dynamic>;
        sentHeaders = Map.of(request.headers);
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              sseChunk({
                'type': 'response.completed',
                'response': {'id': 'r', 'model': 'gpt-5-codex'},
              }),
            ),
          ),
          200,
        );
      });

      final stream = streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: client,
      );
      await stream.toList();

      expect(sentBody!['store'], isFalse);
      expect(sentBody!['stream'], isTrue);
      expect(sentBody!['model'], 'gpt-5-codex');
      expect(sentHeaders!['authorization'], 'Bearer at-1');
      expect(sentHeaders!['ChatGPT-Account-ID'], 'acc-1');
      expect(sentHeaders!['accept'], 'text/event-stream');
      expect(sentHeaders!['session-id'], isNotEmpty);
      expect(sentHeaders!['thread-id'], isNotEmpty);
      expect(sentHeaders!['x-client-request-id'], sentHeaders!['thread-id']);
      expect(sentHeaders!['originator'], 'codex_cli_rs');
    });

    test('a 401 refreshes, persists and retries with the new token', () async {
      var requests = 0;
      final sessionIds = <String?>[];
      String? retriedAuthorization;
      final client = http_testing.MockClient.streaming((
        request,
        requestBody,
      ) async {
        requests++;
        if (request.url.host == 'auth.openai.com') {
          // The refresh call.
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'access_token': 'at-2',
                  'refresh_token': 'rt-2',
                  'id_token': 'it-2',
                }),
              ),
            ),
            200,
          );
        }
        sessionIds.add(request.headers['session-id']);
        if (requests == 1) {
          return http.StreamedResponse(Stream.value(utf8.encode('')), 401);
        }
        retriedAuthorization = request.headers['authorization'];
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              sseChunk({
                    'type': 'response.output_text.delta',
                    'delta': 'recovered',
                  }) +
                  sseChunk({'type': 'response.output_text.done'}),
            ),
          ),
          200,
        );
      });

      String? persisted;
      final stream = streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        onCredentialsRefreshed: (encoded) => persisted = encoded,
        client: client,
      );
      final events = await stream.toList();

      expect(retriedAuthorization, 'Bearer at-2');
      expect(persisted, isNotNull);
      final saved = ChatGptOAuthCredentials.decode(persisted!);
      expect(saved.accessToken, 'at-2');
      expect(saved.refreshToken, 'rt-2');
      // The account id survives the refresh (the new id_token is a stub, so
      // the previous one is kept).
      expect(saved.accountId, 'acc-1');
      expect(events.whereType<TextEndEvent>().single.content, 'recovered');
      // Session/thread ids stay stable across the retry.
      expect(sessionIds, hasLength(2));
      expect(sessionIds[0], isNotEmpty);
      expect(sessionIds[1], sessionIds[0]);
    });

    test('replays learned Cloudflare cookies on a challenge retry', () async {
      final sentHeaders = <Map<String, String>>[];
      final client = queueClient(sentHeaders, [
        http.StreamedResponse(
          Stream.value(utf8.encode('<html>Just a moment...</html>')),
          403,
          headers: {
            'content-type': 'text/html',
            'cf-mitigated': 'challenge',
            'set-cookie': '__cf_bm=x; Path=/; Secure',
          },
        ),
        sseResponse(
          sseChunk({'type': 'response.output_text.delta', 'delta': 'ok'}) +
              sseChunk({'type': 'response.output_text.done'}),
        ),
      ]);

      final events = await streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: client,
      ).toList();

      expect(sentHeaders, hasLength(2));
      expect(sentHeaders[0]['cookie'], isNull);
      expect(sentHeaders[1]['cookie'], '__cf_bm=x');
      expect(events.whereType<TextEndEvent>().single.content, 'ok');
      expect(events.last, isA<DoneEvent>());
    });

    test(
      'a challenge replay cannot clear fails with Cloudflare guidance',
      () async {
        final sentHeaders = <Map<String, String>>[];
        http.StreamedResponse challenge() => http.StreamedResponse(
          Stream.value(utf8.encode('<html>Just a moment...</html>')),
          403,
          headers: {
            'content-type': 'text/html',
            'set-cookie': '__cf_bm=x; Path=/; Secure',
          },
        );
        final client = queueClient(sentHeaders, [challenge(), challenge()]);

        final events = await streamChatGptCodex(
          chatGptModel,
          simpleContext(),
          credentials: credentials.encode(),
          client: client,
        ).toList();

        // One cookie replay, then a hard failure — no third attempt.
        expect(sentHeaders, hasLength(2));
        final error = events.whereType<ErrorEvent>().single;
        expect(error.error.errorMessage, contains('Cloudflare'));
        expect(
          error.error.errorMessage,
          contains('fa /provider chatgpt oauth'),
        );
      },
    );

    test('refreshes proactively when the access token is expired', () async {
      final urls = <Uri>[];
      String? responsesAuthorization;
      final client = http_testing.MockClient.streaming((
        request,
        requestBody,
      ) async {
        urls.add(request.url);
        if (request.url.host == 'auth.openai.com') {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'access_token': 'at-2',
                  'refresh_token': 'rt-2',
                  'id_token': 'it-2',
                }),
              ),
            ),
            200,
          );
        }
        responsesAuthorization = request.headers['authorization'];
        return sseResponse(
          sseChunk({
            'type': 'response.completed',
            'response': {'id': 'r', 'model': 'gpt-5-codex'},
          }),
        );
      });

      final expired = ChatGptOAuthCredentials(
        accessToken: 'at-1',
        refreshToken: 'rt-1',
        idToken: 'it-1',
        accountId: 'acc-1',
        expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );
      String? persisted;
      final events = await streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: expired.encode(),
        onCredentialsRefreshed: (encoded) => persisted = encoded,
        client: client,
      ).toList();

      expect(urls.first.host, 'auth.openai.com');
      expect(responsesAuthorization, 'Bearer at-2');
      expect(ChatGptOAuthCredentials.decode(persisted!).accessToken, 'at-2');
      expect(events.last, isA<DoneEvent>());
    });
  });

  group('request body construction', () {
    test('serializes assistant messages with text and tool calls', () async {
      Map<String, dynamic>? sentBody;
      final client = http_testing.MockClient.streaming((
        request,
        requestBody,
      ) async {
        sentBody =
            jsonDecode(await requestBody.bytesToString())
                as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              sseChunk({
                'type': 'response.completed',
                'response': {'id': 'r', 'model': 'gpt-5-codex'},
              }),
            ),
          ),
          200,
        );
      });

      final ctx = Context(
        messages: [
          UserMessage.text('hello', timestamp: DateTime.utc(2026)),
          AssistantMessage(
            content: [
              TextContent(text: 'I will use a tool'),
              ToolCall(id: 'call_42', name: 'bash', arguments: {'cmd': 'ls'}),
            ],
            api: 'responses',
            provider: 'chatgpt',
            model: 'gpt-5-codex',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.utc(2026),
          ),
        ],
      );

      final stream = streamChatGptCodex(
        chatGptModel,
        ctx,
        credentials: credentials.encode(),
        client: client,
      );
      await stream.toList();

      final input = sentBody!['input'] as List;
      // User message.
      expect((input[0] as Map)['role'], 'user');
      // Assistant message.
      final assistant = input[1] as Map;
      expect(assistant['role'], 'assistant');
      final content = assistant['content'] as List;
      final textBlock = content[0] as Map;
      expect(textBlock['type'], 'output_text');
      expect(textBlock['text'], 'I will use a tool');
      final toolBlock = content[1] as Map;
      expect(toolBlock['type'], 'function_call');
      expect(toolBlock['call_id'], 'call_42');
      expect(toolBlock['name'], 'bash');
      expect(jsonDecode(toolBlock['arguments'] as String), {'cmd': 'ls'});
    });

    test('serializes tool result messages as function_call_output', () async {
      Map<String, dynamic>? sentBody;
      final client = http_testing.MockClient.streaming((
        request,
        requestBody,
      ) async {
        sentBody =
            jsonDecode(await requestBody.bytesToString())
                as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              sseChunk({
                'type': 'response.completed',
                'response': {'id': 'r', 'model': 'gpt-5-codex'},
              }),
            ),
          ),
          200,
        );
      });

      final ctx = Context(
        messages: [
          UserMessage.text('hello', timestamp: DateTime.utc(2026)),
          AssistantMessage(
            content: [
              ToolCall(id: 'call_42', name: 'bash', arguments: {'cmd': 'ls'}),
            ],
            api: 'responses',
            provider: 'chatgpt',
            model: 'gpt-5-codex',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.utc(2026),
          ),
          ToolResultMessage(
            toolCallId: 'call_42',
            toolName: 'bash',
            content: [const TextContent(text: 'file1\nfile2')],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
        ],
      );

      final stream = streamChatGptCodex(
        chatGptModel,
        ctx,
        credentials: credentials.encode(),
        client: client,
      );
      await stream.toList();

      final input = sentBody!['input'] as List;
      // The tool result message is a top-level function_call_output item.
      final toolResult = input[2] as Map;
      expect(toolResult['type'], 'function_call_output');
      expect(toolResult['call_id'], 'call_42');
      final output = toolResult['output'] as List;
      expect((output[0] as Map)['type'], 'input_text');
      expect((output[0] as Map)['text'], 'file1\nfile2');
    });
  });

  group('sse event coverage', () {
    test(
      'response.incomplete is a terminal error carrying the reason',
      () async {
        final body = sseChunk({
          'type': 'response.incomplete',
          'response': {
            'incomplete_details': {'reason': 'max_output_tokens'},
          },
        });
        final events = await streamChatGptCodex(
          chatGptModel,
          simpleContext(),
          credentials: credentials.encode(),
          client: sseClient(body),
        ).toList();

        final error = events.whereType<ErrorEvent>().single;
        expect(error.error.errorMessage, contains('max_output_tokens'));
        expect(events.whereType<DoneEvent>(), isEmpty);
      },
    );

    test('output_item.added pre-binds the tool call block', () async {
      final body =
          sseChunk({
            'type': 'response.output_item.added',
            'item': {
              'type': 'function_call',
              'call_id': 'call_9',
              'name': 'bash',
            },
          }) +
          // Argument deltas without call_id still bind to the block.
          sseChunk({
            'type': 'response.function_call_arguments.delta',
            'delta': '{"cmd":"ls"}',
          }) +
          sseChunk({
            'type': 'response.output_item.done',
            'item': {'type': 'function_call'},
          });
      final events = await streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: sseClient(body),
      ).toList();

      final start = events.whereType<ToolCallStartEvent>().single;
      expect(
        events.indexOf(start),
        lessThan(events.indexOf(events.whereType<ToolCallDeltaEvent>().first)),
      );
      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.id, 'call_9');
      expect(end.toolCall.name, 'bash');
      expect(end.toolCall.arguments, {'cmd': 'ls'});
      expect((events.last as DoneEvent).reason, StopReason.toolUse);
    });

    test('reasoning deltas stream as a thinking block', () async {
      final body =
          sseChunk({
            'type': 'response.reasoning_summary_text.delta',
            'delta': 'think',
          }) +
          sseChunk({'type': 'response.reasoning_text.delta', 'delta': 'ing'}) +
          sseChunk({'type': 'response.reasoning_summary_text.done'}) +
          sseChunk({'type': 'response.reasoning_summary_part.added'}) +
          sseChunk({'type': 'response.output_text.delta', 'delta': 'answer'}) +
          sseChunk({'type': 'response.output_text.done'}) +
          sseChunk({
            'type': 'response.completed',
            'response': {'id': 'r', 'model': 'gpt-5-codex'},
          });
      final events = await streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: sseClient(body),
      ).toList();

      expect(events.whereType<ThinkingStartEvent>(), hasLength(1));
      expect(
        events.whereType<ThinkingDeltaEvent>().map((e) => e.delta).join(),
        'thinking',
      );
      expect(events.whereType<ThinkingEndEvent>().single.content, 'thinking');
      final done = events.last as DoneEvent;
      expect(
        done.message.content.whereType<ThinkingContent>().single.thinking,
        'thinking',
      );
      expect(
        done.message.content.whereType<TextContent>().single.text,
        'answer',
      );
    });
  });

  group('error handling', () {
    test(
      'response.failed pushes an ErrorEvent with the error message',
      () async {
        final body = sseChunk({
          'type': 'response.failed',
          'response': {
            'error': {'message': 'rate limited'},
          },
        });
        final stream = streamChatGptCodex(
          chatGptModel,
          simpleContext(),
          credentials: credentials.encode(),
          client: sseClient(body),
        );
        final events = await stream.toList();
        final error = events.whereType<ErrorEvent>().single;
        expect(error.error.errorMessage, contains('rate limited'));
      },
    );

    test('response.failed with no error message uses default', () async {
      final body = sseChunk({'type': 'response.failed', 'response': {}});
      final stream = streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: sseClient(body),
      );
      final events = await stream.toList();
      final error = events.whereType<ErrorEvent>().single;
      expect(error.error.errorMessage, contains('ChatGPT response failed'));
    });
    test('a 429 error message includes the Codex reset time', () async {
      final client = http_testing.MockClient.streaming(
        (request, requestBody) async => http.StreamedResponse(
          Stream.value(utf8.encode('slow down')),
          429,
          headers: {
            'content-type': 'text/plain',
            'x-codex-primary-used-percent': '100',
            'x-codex-primary-reset-at': '2000000000',
          },
        ),
      );
      final events = await streamChatGptCodex(
        chatGptModel,
        simpleContext(),
        credentials: credentials.encode(),
        client: client,
      ).toList();

      final message = events.whereType<ErrorEvent>().single.error.errorMessage!;
      expect(message, contains('429'));
      expect(message, contains('rate limited; resets at'));
      expect(
        message,
        contains(
          DateTime.fromMillisecondsSinceEpoch(
            2000000000 * 1000,
            isUtc: true,
          ).toIso8601String(),
        ),
      );
    });
  });
}
