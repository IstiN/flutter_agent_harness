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
      // Assistant text is a message item whose content admits only
      // output_text parts...
      final assistant = input[1] as Map;
      expect(assistant['role'], 'assistant');
      final content = assistant['content'] as List;
      expect(content, hasLength(1));
      final textBlock = content[0] as Map;
      expect(textBlock['type'], 'output_text');
      expect(textBlock['text'], 'I will use a tool');
      // ...while the tool call rides as a TOP-LEVEL function_call item
      // (issue #705: a function_call content part is a hard 400).
      final toolCall = input[2] as Map;
      expect(toolCall['type'], 'function_call');
      expect(toolCall['call_id'], 'call_42');
      expect(toolCall['name'], 'bash');
      expect(jsonDecode(toolCall['arguments'] as String), {'cmd': 'ls'});
      expect(
        firstResponsesGrammarViolation([
          for (final item in input) item as Map<String, dynamic>,
        ]),
        isNull,
      );
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
      // The tool result message is a top-level function_call_output item;
      // its call (no text on the assistant record) is the function_call
      // item right before it.
      expect((input[1] as Map)['type'], 'function_call');
      final toolResult = input[2] as Map;
      expect(toolResult['type'], 'function_call_output');
      expect(toolResult['call_id'], 'call_42');
      final output = toolResult['output'] as List;
      expect((output[0] as Map)['type'], 'input_text');
      expect((output[0] as Map)['text'], 'file1\nfile2');
    });
  });

  group('provider switch sanitize (#705)', () {
    // A session authored on CodeMie Gemini: thinking blocks, a thought-
    // signed tool call, a screenshot tool result (vision model), and a
    // thinking-only assistant turn. Replayed to the responses API this was
    // a hard 400 on every turn; the converter must re-shape it so the turn
    // completes.
    final visionModel = Model(
      id: 'gpt-5-codex',
      api: 'responses',
      provider: 'chatgpt',
      baseUrl: chatGptCodexBaseUrl,
      input: const ['text', 'image'],
      contextWindow: 128000,
      maxTokens: 16384,
    );

    AssistantMessage geminiAssistant(List<ContentBlock> content) =>
        AssistantMessage(
          content: content,
          api: 'google-generative-ai',
          provider: 'google',
          model: 'gemini-2.5-pro',
          usage: Usage.zero,
          stopReason: StopReason.toolUse,
          timestamp: DateTime.utc(2026),
        );

    Context switchedHistory() => Context(
      messages: [
        UserMessage.text('list the files', timestamp: DateTime.utc(2026)),
        geminiAssistant([
          const ThinkingContent(thinking: 'I should call bash'),
          const TextContent(text: 'Checking.'),
          ToolCall(id: 'call_42', name: 'bash', arguments: {'cmd': 'ls'}),
        ]),
        ToolResultMessage(
          toolCallId: 'call_42',
          toolName: 'bash',
          content: const [
            ImageContent(data: 'aGk=', mimeType: 'image/png'),
          ],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
        geminiAssistant([
          const ThinkingContent(thinking: 'silent reasoning only'),
        ]),
      ],
    );

    test(
      'gemini-authored history switches to responses without a 400 and '
      're-shapes tool calls to top-level items',
      () async {
        Map<String, dynamic>? sentBody;
        final client = http_testing.MockClient.streaming((
          request,
          requestBody,
        ) async {
          sentBody =
              jsonDecode(await requestBody.bytesToString())
                  as Map<String, dynamic>;
          return sseResponse(
            sseChunk({
              'type': 'response.completed',
              'response': {'id': 'r', 'model': 'gpt-5-codex'},
            }),
          );
        });

        final events = await streamChatGptCodex(
          visionModel,
          switchedHistory(),
          credentials: credentials.encode(),
          client: client,
        ).toList();

        // The switch turn completes; no provider 400.
        expect(events.last, isA<DoneEvent>());

        final input = (sentBody!['input'] as List).cast<Map<String, dynamic>>();
        // user → gemini assistant(text+call) → function_call → output.
        expect(input, hasLength(4));
        expect(
          (input[1]['content'] as List).single,
          containsPair('type', 'output_text'),
        );
        final toolCall = input[2];
        expect(toolCall['type'], 'function_call');
        expect(toolCall['call_id'], 'call_42');
        expect(toolCall['name'], 'bash');
        // The thinking block rides no wire slot (dropped, not nested).
        expect(
          input.every(
            (item) =>
                item['type'] != 'message' ||
                (item['content'] as List).every(
                  (part) => (part as Map)['type'] != 'thinking',
                ),
          ),
          isTrue,
        );
        // Thinking-only assistant record: skipped, not an empty message.
        expect(
          input.any((item) => item['role'] == 'assistant' &&
              (item['content'] as List).isEmpty),
          isFalse,
        );
        expect(firstResponsesGrammarViolation(input), isNull);
      },
    );

    test(
      'image-only tool result degrades to the named note and the following '
      'turn also succeeds',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final client = http_testing.MockClient.streaming((
          request,
          requestBody,
        ) async {
          bodies.add(
            jsonDecode(await requestBody.bytesToString())
                as Map<String, dynamic>,
          );
          return sseResponse(
            sseChunk({
              'type': 'response.completed',
              'response': {'id': 'r', 'model': 'gpt-5-codex'},
            }),
          );
        });

        final first = await streamChatGptCodex(
          visionModel,
          switchedHistory(),
          credentials: credentials.encode(),
          client: client,
        ).toList();
        expect(first.last, isA<DoneEvent>());

        final output = (((bodies[0]['input'] as List)[3])
            as Map<String, dynamic>)['output'] as List;
        expect(
          (output.single as Map)['text'],
          responsesOmittedToolResultNote,
        );

        // The FOLLOWING turn (history + the first turn's answer) succeeds
        // too — the degraded record never re-poisons the session.
        final answer = (first.last as DoneEvent).message;
        final secondContext = Context(
          messages: [
            ...switchedHistory().messages,
            answer,
          ],
        );
        final second = await streamChatGptCodex(
          visionModel,
          secondContext,
          credentials: credentials.encode(),
          client: client,
        ).toList();
        expect(second.last, isA<DoneEvent>());
        final secondInput =
            (bodies[1]['input'] as List).cast<Map<String, dynamic>>();
        expect(firstResponsesGrammarViolation(secondInput), isNull);
      },
    );

    test('converter matrix: google/anthropic/completions records convert to '
        'grammar-valid responses items', () {
      // The internal record types are shared, so the matrix pins the source
      // provider identity each record carries plus its provider-specific
      // block shapes.
      final histories = {
        'google-generative-ai': [
          geminiAssistant([
            const ThinkingContent(
              thinking: 'hmm',
              thinkingSignature: 'c2ln',
            ),
            ToolCall(
              id: 'gemini-2.5:fc1',
              name: 'bash',
              arguments: {'cmd': 'ls'},
              thoughtSignature: 'c2ln',
            ),
          ]),
        ],
        'anthropic-messages': [
          AssistantMessage(
            content: const [
              ThinkingContent(
                thinking: 'redacted',
                thinkingSignature: 'enc',
                redacted: true,
              ),
              TextContent(text: 'Running.'),
              ToolCall(id: 'toolu_01ABC', name: 'bash', arguments: {}),
            ],
            api: 'anthropic-messages',
            provider: 'anthropic',
            model: 'claude-sonnet-4',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.utc(2026),
          ),
        ],
        'openai-completions': [
          AssistantMessage(
            content: const [
              TextContent(text: 'Calling bash.'),
              ToolCall(id: 'call_abc123', name: 'bash', arguments: {}),
            ],
            api: 'openai-completions',
            provider: 'openai',
            model: 'gpt-4o',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.utc(2026),
          ),
        ],
      };

      histories.forEach((api, messages) {
        final input = responsesInputItems(messages);
        // Every source shape lands as text-message + top-level
        // function_call; the google record carries no text, so its text
        // message is legitimately absent (thinking rides no wire slot).
        final calls = [
          for (final item in input)
            if (item['type'] == 'function_call') item,
        ];
        expect(calls, hasLength(1), reason: 'history authored by $api');
        final assistantItems = [
          for (final item in input)
            if (item['role'] == 'assistant') item,
        ];
        for (final item in assistantItems) {
          expect(
            [for (final part in item['content'] as List) (part as Map)['type']],
            everyElement('output_text'),
            reason: 'history authored by $api',
          );
        }
        expect(
          firstResponsesGrammarViolation(
            input.cast<Map<String, dynamic>>(),
          ),
          isNull,
          reason: 'history authored by $api must convert to valid responses '
              'items',
        );
      });
    });

    test('a grammar-shaped 400 surfaces the suspect item and a recovery '
        'hint, never a bare loop', () async {
      final client = http_testing.MockClient.streaming(
        (request, requestBody) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'error': {
                  'message':
                      "Invalid value: 'function_call'. Supported values "
                      "are: ['input_text', 'output_text', 'input_image']",
                },
              }),
            ),
          ),
          400,
        ),
      );
      final events = await streamChatGptCodex(
        visionModel,
        switchedHistory(),
        credentials: credentials.encode(),
        client: client,
      ).toList();

      final message = events.whereType<ErrorEvent>().single.error.errorMessage!;
      expect(message, contains("Invalid value: 'function_call'"));
      expect(message, contains('rejected the outbound item/content grammar'));
      expect(message, contains('/compact'));
    });

    test('grammar validator names the poisoned content part', () {
      // The pre-fix payload shape: a function_call nested inside assistant
      // message content.
      final poisoned = [
        {'role': 'user', 'content': const []},
        {
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'x'},
            {
              'type': 'function_call',
              'call_id': 'call_42',
              'name': 'bash',
              'arguments': '{}',
            },
          ],
        },
      ];
      expect(
        firstResponsesGrammarViolation(poisoned),
        contains("'function_call' is not a valid message content part"),
      );
      expect(firstResponsesGrammarViolation(const []), isNull);
    });
  });

  group('sse event coverage', () {
    test(
      'response.incomplete keeps partial text and ends as a terminal error',
      () async {
        final body =
            sseChunk({'type': 'response.output_text.delta', 'delta': 'part'}) +
            sseChunk({
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

        // The partial text stays visible: its block is closed before the
        // terminal error event, never wiped.
        expect(events.whereType<TextEndEvent>().single.content, 'part');
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, contains('max_output_tokens'));
        expect(
          error.error.content.whereType<TextContent>().single.text,
          'part',
        );
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
      'response.failed keeps partial text and ends as a terminal error',
      () async {
        final body =
            sseChunk({
              'type': 'response.output_text.delta',
              'delta': 'so far',
            }) +
            sseChunk({
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

        expect(events.whereType<TextEndEvent>().single.content, 'so far');
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, contains('rate limited'));
        expect(
          error.error.content.whereType<TextContent>().single.text,
          'so far',
        );
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
