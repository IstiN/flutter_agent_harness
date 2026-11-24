// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — `CompactionCachePolicy.sessionAffine` (AC10, UT-14) and the
/// request-shape plumbing of the merged hand-over call (AC3, REG-06/07):
/// NULL fallthrough resolves the session's own routing values, the
/// resolver yields only to an EXPLICIT override, `affine`/`isolated` stay
/// byte-identical, and the catalog threads `tool_choice` / `maxTokens` /
/// `prefixLength` / the pinned Copilot initiator into the adapter payloads.

library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

final _model = Model(
  id: 'gpt-4o',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  contextWindow: 128000,
  maxTokens: 16384,
);

Context _context() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

AssistantMessageEventStream _okStream() {
  final message = AssistantMessage(
    content: [TextContent(text: 'ok')],
    api: 'openai-completions',
    provider: 'openai',
    model: 'gpt-4o',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: message));
  stream.push(DoneEvent(reason: StopReason.stop, message: message));
  stream.end();
  return stream;
}

String _sse(List<Map<String, dynamic>> chunks) => [
  for (final chunk in chunks) 'data: ${jsonEncode(chunk)}\n\n',
  'data: [DONE]\n\n',
].join();

http.Client _openAiSse(List<String> bodies) =>
    http_testing.MockClient.streaming((request, requestBody) async {
      bodies.add(await requestBody.bytesToString());
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            _sse([
              {
                'id': '1',
                'object': 'chat.completion.chunk',
                'model': 'gpt-4o',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': 'ok'},
                    'finish_reason': null,
                  },
                ],
              },
              {
                'id': '1',
                'object': 'chat.completion.chunk',
                'model': 'gpt-4o',
                'choices': [
                  {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
                ],
              },
            ]),
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

/// An Anthropic SSE capture client: records the request body (the
/// adapter's own serialization — the breakpoint positions are read off
/// it) and the `x-initiator` header.
http.Client _anthropicCapture(List<String> bodies, List<String> headers) {
  return http_testing.MockClient.streaming((request, requestBody) async {
    bodies.add(await requestBody.bytesToString());
    headers.add(request.headers['x-initiator'] ?? '');
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          [
            'event: message_start',
            'data: {"type":"message_start","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}',
            'event: content_block_start',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'event: content_block_delta',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
            'event: content_block_stop',
            'data: {"type":"content_block_stop","index":0}',
            'event: message_delta',
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}',
            'event: message_stop',
            'data: {"type":"message_stop"}',
            '',
          ].join('\n\n'),
        ),
      ),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

void main() {
  group('UT-14 sessionAffine routing record', () {
    test('every field is null — the fallthrough, never a literal', () {
      final policy = CompactionCachePolicy.sessionAffine();
      for (final klass in CompactionCallClass.values) {
        final routing = policy.routingFor(klass);
        expect(routing.sessionId, isNull);
        expect(routing.cacheRetention, isNull);
      }
    });

    test(
      'runWith installs the all-null record; it is not an explicit override',
      () async {
        final policy = CompactionCachePolicy.sessionAffine();
        late ({String? sessionId, String? cacheRetention})? seen;
        late bool explicit;
        await policy.runWith(() async {
          seen = StreamCacheRouting.current;
          explicit = StreamCacheRouting.hasExplicitRouting;
        }, CompactionCallClass.digest);
        expect(seen, (sessionId: null, cacheRetention: null));
        expect(explicit, isFalse);
        expect(StreamCacheRouting.current, isNull);
      },
    );

    test(
      'REG-06: affine and isolated are byte-identical to before (explicit overrides)',
      () async {
        final affine = CompactionCachePolicy.affine(sessionId: 'run-1');
        final seen = <({String? sessionId, String? cacheRetention})>[];
        affine.runWith(
          () => seen.add(StreamCacheRouting.current!),
          CompactionCallClass.digest,
        );
        affine.runWith(
          () => seen.add(StreamCacheRouting.current!),
          CompactionCallClass.judge,
        );
        expect(seen, [
          (sessionId: 'run-1', cacheRetention: 'short'),
          (sessionId: 'run-1', cacheRetention: 'short'),
        ]);
        expect(
          StreamCacheRouting.hasExplicitRouting,
          isFalse,
          reason: 'outside the zone there is no override',
        );
        affine.runWith(
          () => expect(StreamCacheRouting.hasExplicitRouting, isTrue),
          CompactionCallClass.digest,
        );
        final isolated = CompactionCachePolicy.isolated();
        isolated.runWith(
          () => seen.add(StreamCacheRouting.current!),
          CompactionCallClass.digest,
        );
        expect(seen.last.cacheRetention, 'none');
        expect(seen.last.sessionId, isNotEmpty);
      },
    );

    test(
      'UT-14: the call shape rides the zone — toolChoice/maxTokens/prefixLength/copilotInitiator',
      () async {
        StreamCallShape? seen;
        await StreamCacheRouting.runWith(
          () async => seen = StreamCacheRouting.callShape,
          sessionId: null,
          cacheRetention: null,
          shape: const StreamCallShape(
            toolChoice: 'none',
            maxTokens: 8192,
            prefixLength: 12,
            copilotInitiator: 'agent',
          ),
        );
        expect(seen?.toolChoice, 'none');
        expect(seen?.maxTokens, 8192);
        expect(seen?.prefixLength, 12);
        expect(seen?.copilotInitiator, 'agent');
        expect(StreamCacheRouting.callShape, isNull);
        // An ordinary runWith installs no shape.
        StreamCacheRouting.runWith(
          () => expect(StreamCacheRouting.callShape, isNull),
          sessionId: 'x',
        );
      },
    );
  });

  group('E11/E14 — the resolver keeps its binding under sessionAffine', () {
    test(
      'the hand-over call rides the resolver-bound session id of the main request',
      () async {
        final sink = <({String? sessionId, String? cacheRetention})?>[];
        final resolver = ModelRolesResolver(
          config: ModelRolesConfig(
            roles: const {
              'default': [ModelRef(provider: 'openai', modelId: 'gpt-4o')],
            },
          ),
          secrets: const {'OPENAI_API_KEY': 'k'},
          streamFactory: (kind, apiKey) => (model, context, {cancelToken}) {
            sink.add(StreamCacheRouting.current);
            return _okStream();
          },
        );
        resolver.sessionId = () => 'sess-9';
        final resolved = resolver.resolveRole('default')!;
        await resolved.stream(resolved.model, _context()).toList();
        await CompactionCachePolicy.sessionAffine().runWith(
          () => resolved.stream(resolved.model, _context()).toList(),
          CompactionCallClass.digest,
        );
        // Main request: the resolver binds sess-9. Hand-over: the SAME
        // binding — the all-null override is no opinion.
        expect(sink, [
          (sessionId: 'sess-9', cacheRetention: null),
          (sessionId: 'sess-9', cacheRetention: null),
        ]);
      },
    );
  });

  group('REG-06/07 — the catalog threads the shape into adapter payloads', () {
    test(
      'OpenAI-compat: tool_choice none + max_tokens on the hand-over, absent on main',
      () async {
        final bodies = <String>[];
        final stream = providerStreamFunction(
          'openai-completions',
          'k',
          httpClient: _openAiSse(bodies),
        );
        await stream(_model, _context()).toList();
        await CompactionCachePolicy.sessionAffine().runWith(
          () => stream(_model, _context()).toList(),
          CompactionCallClass.digest,
          shape: const StreamCallShape(toolChoice: 'none', maxTokens: 8192),
        );
        final main = jsonDecode(bodies[0]) as Map<String, dynamic>;
        final handOver = jsonDecode(bodies[1]) as Map<String, dynamic>;
        expect(main.containsKey('tool_choice'), isFalse);
        expect(handOver['tool_choice'], 'none');
        expect(
          handOver["max_tokens"] ?? handOver["max_completion_tokens"],
          8192,
        );
        // Same key, same bucket: the prefix (system + messages) is identical.
        expect(handOver['messages'], main['messages']);
        expect(handOver['model'], main['model']);
      },
    );

    test(
      'E24: Anthropic puts the history breakpoint on S0-last (4 total) and none when S0 ends assistant',
      () async {
        final bodies = <String>[];
        final headers = <String>[];
        final stream = providerStreamFunction(
          'anthropic',
          'k',
          httpClient: _anthropicCapture(bodies, headers),
        );
        final claude = Model(
          id: 'claude-sonnet-4-5',
          api: 'anthropic-messages',
          provider: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          contextWindow: 200000,
          maxTokens: 8192,
        );
        Context request(int prefix) => Context(
          systemPrompt: 'sys',
          messages: [
            UserMessage.text('a', timestamp: DateTime.utc(2026)),
            UserMessage.text('b', timestamp: DateTime.utc(2026)),
            UserMessage.text('instruction', timestamp: DateTime.utc(2026)),
          ].take(prefix + 1).toList(),
        );
        await CompactionCachePolicy.sessionAffine().runWith(
          () => stream(claude, request(2)).toList(),
          CompactionCallClass.digest,
          shape: const StreamCallShape(toolChoice: 'none', prefixLength: 2),
        );
        final payload = jsonDecode(bodies.single) as Map<String, dynamic>;
        final messages = (payload['messages'] as List)
            .cast<Map<String, dynamic>>();
        int breakpoints(Map<String, dynamic> message) {
          final content = message["content"];
          if (content is! List) return 0;
          return content
              .whereType<Map>()
              .where((block) => block.containsKey("cache_control"))
              .length;
        }

        // system + tools(none) + history (S0-last = message 1) + instruction.
        expect(
          breakpoints(messages[1]),
          1,
          reason: 'history breakpoint on S0-last',
        );
        expect(breakpoints(messages[2]), 1, reason: 'instruction breakpoint');
        expect(
          ((payload['system'] as List).single as Map).containsKey(
            'cache_control',
          ),
          isTrue,
        );
        expect(payload['tool_choice'], {'type': 'none'});

        // Negative: S0 ending with an assistant message gets NO history
        // breakpoint (Anthropic only breaks on user messages).
        bodies.clear();
        await CompactionCachePolicy.sessionAffine().runWith(
          () => stream(
            claude,
            Context(
              messages: [
                UserMessage.text('q', timestamp: DateTime.utc(2026)),
                AssistantMessage(
                  content: [TextContent(text: 'a')],
                  api: 'anthropic-messages',
                  provider: 'anthropic',
                  model: 'claude-sonnet-4-5',
                  usage: Usage.zero,
                  stopReason: StopReason.stop,
                  timestamp: DateTime.utc(2026),
                ),
                UserMessage.text('instruction', timestamp: DateTime.utc(2026)),
              ],
            ),
          ).toList(),
          CompactionCallClass.digest,
          shape: const StreamCallShape(prefixLength: 2),
        );
        final negative = jsonDecode(bodies.single) as Map<String, dynamic>;
        final negativeMessages = (negative['messages'] as List)
            .cast<Map<String, dynamic>>();
        expect(breakpoints(negativeMessages[0]), 0);
        expect(breakpoints(negativeMessages[1]), 0);
        expect(
          breakpoints(negativeMessages[2]),
          1,
          reason: 'only the instruction',
        );
      },
    );
  });
}
