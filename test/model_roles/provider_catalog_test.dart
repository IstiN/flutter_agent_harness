// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

final _utc = DateTime.utc(2026);

/// Regression pin for the Phase 1 un-hide: the ChatGPT Codex provider must
/// stay visible across the pickers, settings screens, and `enabledProviders`
/// consumers. A refactor that drops the default `visible: true` fails here
/// instead of surfacing as a "the picker is missing chatgpt" mystery.
///
/// The ceiling groups pin issue #273's per-family output caps: the catalog
/// specs' blanket `maxTokens: 16384` clamps modern Claude models, so
/// resolution is config override > Claude ceiling table > provider default.
/// Issue #302 scopes the table to its Anthropic-API family — a claude id
/// over any other dialect keeps the provider default.

/// The table step for an id on the table's own family (the only family
/// [resolveModelMaxOutputTokens] consults it for).
int? anthropicCeiling(String id) =>
    resolveModelMaxOutputTokens(id, api: anthropicMessagesApi);

void main() {
  test('chatgpt spec is visible after Phase 1 un-hide', () {
    expect(providerCatalog['chatgpt']!.visible, isTrue);
    expect(enabledProviders().any((s) => s.name == 'chatgpt'), isTrue);
  });

  group('resolveModelMaxOutputTokens (UT-ceilings, AC2)', () {
    test('exact catalogued versions pin their documented cap', () {
      expect(anthropicCeiling('claude-opus-4-5'), 64000);
      expect(anthropicCeiling('claude-sonnet-4-6'), 128000);
      expect(anthropicCeiling('claude-haiku-4-5'), 64000);
      expect(anthropicCeiling('claude-sonnet-3-5'), 8192);
      // Version read from before the family token.
      expect(anthropicCeiling('claude-3-opus'), 4096);
    });

    test('uncatalogued versions fall to the nearest-lower minor', () {
      // 4.9 is past 4.8 — rides the largest catalogued ≤ it.
      expect(anthropicCeiling('claude-opus-4-9'), 128000);
      // 4.7 misses; sonnet falls back to 4.6's cap.
      expect(anthropicCeiling('claude-sonnet-4-7'), 128000);
      // Nothing catalogued at or below 2.9.
      expect(anthropicCeiling('claude-opus-2-9'), 128000);
    });

    test('unknown Claude model takes the conservative fallback', () {
      expect(anthropicCeiling('claude-lambda-9'), 128000);
    });

    test('non-Claude ids miss the table (null = provider default)', () {
      expect(anthropicCeiling('gpt-4o'), isNull);
      expect(anthropicCeiling('glm-5.3-flash'), isNull);
      expect(anthropicCeiling('kimi-k2'), isNull);
    });

    test('claude ids outside the anthropic family miss the table (#302)', () {
      expect(
        resolveModelMaxOutputTokens(
          'claude-opus-4-5',
          api: 'openai-completions',
        ),
        isNull,
      );
      expect(
        resolveModelMaxOutputTokens(
          'claude-sonnet-4-6',
          api: 'google-generative-ai',
        ),
        isNull,
      );
    });

    test('id shapes: dates, dots, scopes, underscores, pre-family', () {
      expect(anthropicCeiling('claude-opus-4-5-20251101'), 64000);
      expect(anthropicCeiling('claude-opus-4.5'), 64000);
      expect(anthropicCeiling('anthropic/claude-opus-4.5'), 64000);
      // Date suffix must not parse as the version; 3.5 read pre-family.
      expect(anthropicCeiling('claude-3-5-sonnet-20241022'), 8192);
      expect(anthropicCeiling('claude-sonnet-4-5'), 64000);
      expect(anthropicCeiling('claude_opus_4_5'), 64000);
    });
  });

  group('catalog/cli builders thread the ceiling table', () {
    test('buildCatalogModel: table beats provider default', () {
      expect(
        buildCatalogModel('anthropic', 'claude-opus-4-5').maxTokens,
        64000,
      );
    });

    test('buildCatalogModel: non-Claude id keeps the provider default', () {
      expect(buildCatalogModel('openai', 'gpt-4o').maxTokens, 16384);
    });

    test('buildCatalogModel: explicit override beats the table', () {
      expect(
        buildCatalogModel(
          'anthropic',
          'claude-opus-4-5',
          maxTokens: 1000,
        ).maxTokens,
        1000,
      );
    });

    test('buildCliDefaultModel resolves through the table', () {
      expect(
        buildCliDefaultModel('anthropic', modelId: 'claude-opus-4-5').maxTokens,
        64000,
      );
    });

    test('buildCatalogModel: claude id off the table family keeps the '
        'provider default (#302)', () {
      expect(
        buildCatalogModel('openrouter', 'anthropic/claude-opus-4.5').maxTokens,
        16384,
      );
    });

    test('buildCliDefaultModel: claude id off the table family keeps the '
        'provider default (#302)', () {
      expect(
        buildCliDefaultModel(
          'openai-completions',
          modelId: 'anthropic/claude-opus-4-5',
        ).maxTokens,
        16384,
      );
    });
  });

  group('explicit input modalities (issue #638 AC1)', () {
    test('buildCatalogModel: explicit input overrides the catalog spec', () {
      // zai's catalog spec is text-only; a preconfig declaring
      // input: ["text","image"] must win.
      expect(buildCatalogModel('zai', 'glm-5.3-flash').input, ['text']);
      expect(
        buildCatalogModel(
          'zai',
          'glm-5.3-flash',
          input: const ['text', 'image'],
        ).input,
        ['text', 'image'],
      );
    });

    test('buildCliDefaultModel threads the explicit input override', () {
      expect(
        buildCliDefaultModel(
          'zai',
          modelId: 'glm-5.3-flash',
          input: const ['text', 'image'],
        ).input,
        ['text', 'image'],
      );
      // Absent override keeps the catalog spec (today's behavior).
      expect(buildCliDefaultModel('zai', modelId: 'glm-5.3-flash').input, [
        'text',
      ]);
    });

    test('buildCliDefaultModel threads the preconfig thinkingLevel '
        '(issue #734 rework: the no-roles boot path)', () {
      // The FA_PROVIDER_* level must reach the fallback/default model when
      // no roles chain pins it — the boot notice names the level, so the
      // booted model has to carry it.
      expect(
        buildCliDefaultModel(
          'anthropic',
          modelId: 'claude-opus-4-5',
          thinkingLevel: 'max',
        ).thinkingLevel,
        // Verbatim pass-through: the rung fold happens at the config parse
        // boundary (FA_PROVIDER_CONFIG / ModelRef.fromYaml both normalize
        // xhigh/max → high before a Model is ever built).
        'max',
      );
      // Absent level stays null (byte-identical legacy boot).
      expect(
        buildCliDefaultModel(
          'anthropic',
          modelId: 'claude-opus-4-5',
        ).thinkingLevel,
        isNull,
      );
    });

    test('buildCliDefaultModel threads the preconfig contextWindow/'
        'maxTokens (gh-1471 D4: the FA_PROVIDER_CONFIG declaration)', () {
      // The bench kimi mapping pins 200000/16384 — the declaration wins
      // over every resolver layer below it (spec, ceiling table).
      final declared = buildCliDefaultModel(
        'kimi',
        modelId: 'k3-256k',
        contextWindow: 200000,
        maxTokens: 16384,
      );
      expect(declared.contextWindow, 200000);
      expect(declared.maxTokens, 16384);
      // Absent declarations keep the catalog spec (the kimi spec already
      // carries 200000/16384 — a zai boot is byte-identical either way).
      final inherited = buildCliDefaultModel('kimi', modelId: 'k3-256k');
      expect(inherited.contextWindow, 200000);
      expect(inherited.maxTokens, 16384);
    });
  });

  group('providerStreamFunction cache routing (issue #1992 CRAP tier)', () {
    // Minimal openai-completions SSE: one content delta, then stop.
    const sse =
        'data: {"id":"c1","choices":[{"delta":{"content":"ack"}}]}\n\n'
        'data: {"id":"c1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n';

    const model = Model(
      id: 'gpt-test',
      api: 'openai-completions',
      provider: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      contextWindow: 100000,
      maxTokens: 4096,
    );

    /// Drives the factory's StreamFunction against a body-capturing mock
    /// and returns the decoded chat-completions request body. [routing]
    /// wraps the call in a [StreamCacheRouting] override zone (the
    /// compaction-bypass path); without it the factory defaults apply.
    Future<Map<String, dynamic>> requestBody({
      String? Function()? sessionId,
      ({String? sessionId, String? cacheRetention})? routing,
    }) async {
      final captured = <String>[];
      final client = http_testing.MockClient.streaming((request, body) async {
        captured.add(utf8.decode(await body.toBytes()));
        return http.StreamedResponse(
          Stream.value(utf8.encode(sse)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final streamFunction = providerStreamFunction(
        'openai-completions',
        'key',
        sessionId: sessionId,
        httpClient: client,
      );
      AssistantMessageEventStream invoke() => streamFunction(
        model,
        Context(messages: [UserMessage.text('hi', timestamp: _utc)]),
      );
      final events =
          await (routing == null
                  ? invoke()
                  : StreamCacheRouting.runWith(
                      invoke,
                      sessionId: routing.sessionId,
                      cacheRetention: routing.cacheRetention,
                    ))
              .toList();
      expect(
        events.whereType<ErrorEvent>(),
        isEmpty,
        reason: 'the scripted stream must complete cleanly',
      );
      expect(captured, hasLength(1));
      return jsonDecode(captured.single) as Map<String, dynamic>;
    }

    test('an unknown kind is rejected at the factory', () {
      expect(
        () => providerStreamFunction('bogus', 'key'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('the factory sessionId rides the wire as prompt_cache_key', () async {
      final body = await requestBody(sessionId: () => 'sess-factory');
      expect(body['prompt_cache_key'], 'sess-factory');
    });

    test('an active StreamCacheRouting override wins per call', () async {
      final body = await requestBody(
        sessionId: () => 'sess-factory',
        routing: (sessionId: 'sess-route', cacheRetention: 'long'),
      );
      expect(body['prompt_cache_key'], 'sess-route');
      expect(body['prompt_cache_retention'], '24h');
    });
  });
}
