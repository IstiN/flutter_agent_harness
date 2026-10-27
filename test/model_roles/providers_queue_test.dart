import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

Model _model(String provider, String id) => Model(
  id: id,
  api: 'test-api',
  provider: provider,
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _msg(
  Model model, {
  String text = '',
  StopReason stop = StopReason.stop,
  String? error,
  String? rawStopReason,
}) {
  return AssistantMessage(
    content: text.isEmpty ? const [] : [TextContent(text: text)],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stop,
    errorMessage: error,
    rawStopReason: rawStopReason,
    timestamp: DateTime.utc(2026),
  );
}

ErrorEvent _err(
  Model model,
  String message, {
  Duration? retryAfter,
  StopReason reason = StopReason.error,
  String? rawStopReason,
}) => ErrorEvent(
  reason: reason,
  error: _msg(
    model,
    stop: StopReason.error,
    error: message,
    rawStopReason: rawStopReason,
  ),
  retryAfter: retryAfter,
);

List<AssistantMessageEvent> _okTurn(Model model, String text) {
  final empty = _msg(model);
  final full = _msg(model, text: text);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: full),
    DoneEvent(reason: StopReason.stop, message: full),
  ];
}

List<AssistantMessageEvent> _deathTurn(Model model, String error) => [
  StartEvent(partial: _msg(model)),
  _err(model, error),
];

/// A scripted stream factory: serves pre-recorded turns per API-key value
/// and records every call.
class _Probe {
  final Map<String, List<List<AssistantMessageEvent>>> scriptsByKey;
  final calls = <String>[];

  _Probe(this.scriptsByKey);

  StreamFunction streamForKey(String apiKey) {
    return (model, context, {cancelToken}) {
      calls.add('${model.id}:$apiKey');
      final queue = scriptsByKey[apiKey];
      if (queue == null || queue.isEmpty) {
        throw StateError('no scripted turn left for key $apiKey');
      }
      final stream = AssistantMessageEventStream();
      for (final event in queue.removeAt(0)) {
        stream.push(event);
      }
      stream.end();
      return stream;
    };
  }
}

ProviderQueueEntry _entry(
  String kind,
  String model, {
  String? baseUrl,
  String? apiKeyEnv = 'K_API_KEY',
}) => ProviderQueueEntry(
  providerType: kind,
  model: model,
  baseUrl: baseUrl,
  apiKeyEnv: apiKeyEnv,
);

Map<String, String> _secrets([Map<String, String> extra = const {}]) => {
  'K_API_KEY': 'key-head',
  'K2_API_KEY': 'key-two',
  'K3_API_KEY': 'key-three',
  ...extra,
};

void main() {
  _bootScopeTests();
  group('parseProviderQueueJsonText', () {
    test('parses the canonical two-entry queue (UT-parse-env-happy)', () {
      final parsed = parseProviderQueueJsonText(
        jsonEncode([
          {
            'provider_type': 'openai-completions',
            'provider_config': {
              'baseUrl': 'https://gate.test/v1',
              'model': 'm-1',
              'apiKeyEnv': 'K_API_KEY',
              'contextWindow': 128000,
            },
          },
          {
            'provider_type': 'anthropic',
            'provider_config': {'model': 'm-2', 'apiKeyEnv': 'K2_API_KEY'},
          },
        ]),
      );
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries[0].providerType, 'openai-completions');
      expect(parsed.entries[0].baseUrl, 'https://gate.test/v1');
      expect(parsed.entries[0].contextWindow, 128000);
      expect(parsed.entries[1].providerType, 'anthropic');
      expect(parsed.warnings, isEmpty);
    });

    test('whitespace, BOM and trailing newline tolerance (E9)', () {
      final parsed = parseProviderQueueJsonText(
        '﻿\n  [${jsonEncode({
          'provider_type': 'anthropic',
          'provider_config': {'model': 'm', 'apiKeyEnv': 'K_API_KEY'},
        })}]  \n',
      );
      expect(parsed.entries, hasLength(1));
    });

    test('hard error with line:col on invalid JSON (UT-parse-env-sad)', () {
      expect(
        () => parseProviderQueueJsonText('[{"provider_type": oops}]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('line 1'), contains('column 20')),
          ),
        ),
      );
    });

    test('shell-level single quotes are rejected with a hint (E8)', () {
      expect(
        () => parseProviderQueueJsonText("['{...}']"),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('single quotes'),
          ),
        ),
      );
    });

    test('empty array is an explicit error (UT-parse-empty-single)', () {
      expect(
        () => parseProviderQueueJsonText('[]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('the queue is empty'),
          ),
        ),
      );
    });

    test('@path file form loads through the injected reader', () {
      final parsed = parseProviderQueueEnv(
        '@/tmp/queue.json',
        readText: (path) => jsonEncode([
          {
            'provider_type': 'anthropic',
            'provider_config': {'model': 'm', 'apiKeyEnv': 'K_API_KEY'},
          },
        ]),
      );
      expect(parsed.entries, hasLength(1));
      expect(
        () => parseProviderQueueEnv('@/missing.json'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('literal apiKey in provider_config is a hard error (AC9)', () {
      expect(
        () => parseProviderQueueJsonText(
          jsonEncode([
            {
              'provider_type': 'anthropic',
              'provider_config': {'model': 'm', 'apiKey': 'sk-secret-value'},
            },
          ]),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('apiKeyEnv'),
          ),
        ),
      );
    });

    test('unknown provider_type names the supported kinds', () {
      expect(
        () => parseProviderQueueJsonText(
          jsonEncode([
            {
              'provider_type': 'not-a-kind',
              'provider_config': {'model': 'm'},
            },
          ]),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('not-a-kind'), contains('openai-completions')),
          ),
        ),
      );
    });

    test('missing model is an error; unknown config keys warn (UT-warn)', () {
      expect(
        () => parseProviderQueueJsonText(
          jsonEncode([
            {
              'provider_type': 'anthropic',
              'provider_config': {'apiKeyEnv': 'K_API_KEY'},
            },
          ]),
        ),
        throwsA(isA<ConfigException>()),
      );
      final parsed = parseProviderQueueJsonText(
        jsonEncode([
          {
            'provider_type': 'anthropic',
            'provider_config': {
              'model': 'm',
              'apiKeyEnv': 'K_API_KEY',
              'weirdKey': 1,
            },
          },
        ]),
      );
      expect(parsed.warnings, hasLength(1));
      expect(parsed.warnings.single, contains('weirdKey'));
    });

    test('duplicates dedup keep-first with a warning (UT-duplicates, E10)', () {
      final entry = {
        'provider_type': 'anthropic',
        'provider_config': {'model': 'm', 'apiKeyEnv': 'K_API_KEY'},
      };
      final parsed = parseProviderQueueJsonText(jsonEncode([entry, entry]));
      expect(parsed.entries, hasLength(1));
      expect(parsed.warnings.single, contains('keeping the first'));
      // Same provider, different model: two distinct entries.
      final two = parseProviderQueueJsonText(
        jsonEncode([
          entry,
          {
            'provider_type': 'anthropic',
            'provider_config': {'model': 'm2', 'apiKeyEnv': 'K_API_KEY'},
          },
        ]),
      );
      expect(two.entries, hasLength(2));
    });

    test('{"ref": name} resolves through the custom provider (UT-ref)', () {
      final parsed = parseProviderQueueEntries(
        [
          {
            'ref': 'kimi_me',
            'provider_config': {'model': 'override-model'},
          },
        ],
        source: 'test',
        resolveRef: (name) => (
          kind: 'openai-completions',
          baseUrl: 'https://kimi.test/v1',
          model: 'kimi-k2',
          keyName: 'KIMI_API_KEY',
        ),
      );
      expect(parsed.entries.single.providerType, 'openai-completions');
      expect(parsed.entries.single.baseUrl, 'https://kimi.test/v1');
      // Inline override wins over the ref's model (UT-inline-merge).
      expect(parsed.entries.single.model, 'override-model');
      expect(parsed.entries.single.apiKeyEnv, 'KIMI_API_KEY');
      expect(
        () => parseProviderQueueEntries(
          [
            {'ref': 'ghost'},
          ],
          source: 'test',
          resolveRef: (name) => null,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('resolveProviderQueueScopes', () {
    ProviderQueueScopeInput scope(
      ProviderQueueScope s,
      bool present, [
      List<ProviderQueueEntry>? entries,
    ]) => ProviderQueueScopeInput(
      scope: s,
      isPresent: present,
      parse: entries == null
          ? null
          : ParsedProviderQueue(entries: entries, warnings: const []),
    );

    test('none set → unset legacy resolution (AC10)', () {
      final r = resolveProviderQueueScopes([]);
      expect(r.isSet, isFalse);
      expect(r.notices, isEmpty);
    });

    test('env wins over project and user, both named (IT-40, AC2)', () {
      final r = resolveProviderQueueScopes([
        scope(ProviderQueueScope.env, true, [_entry('anthropic', 'env-m')]),
        scope(ProviderQueueScope.project, true, [_entry('anthropic', 'proj')]),
        scope(ProviderQueueScope.user, true, [_entry('anthropic', 'user')]),
      ]);
      expect(r.scope, ProviderQueueScope.env);
      expect(r.entries.single.model, 'env-m');
      expect(r.notices.first, contains('FA_PROVIDERS_QUEUE env'));
      expect(r.notices, hasLength(3));
      expect(r.notices[1], contains('project'));
      expect(r.notices[2], contains('user'));
    });

    test('project over user when env unset', () {
      final r = resolveProviderQueueScopes([
        scope(ProviderQueueScope.project, true, [_entry('anthropic', 'proj')]),
        scope(ProviderQueueScope.user, true, [_entry('anthropic', 'user')]),
      ]);
      expect(r.scope, ProviderQueueScope.project);
      expect(r.notices, hasLength(2));
    });

    test(
      'identical shadowed queue collapses into one notice (UT-scope-stack)',
      () {
        final entries = [_entry('anthropic', 'same')];
        final r = resolveProviderQueueScopes([
          scope(ProviderQueueScope.project, true, entries),
          scope(ProviderQueueScope.user, true, [_entry('anthropic', 'same')]),
        ]);
        expect(r.notices, hasLength(2));
        expect(r.notices[1], contains('same queue'));
      },
    );
  });

  group('editor list ops (UT-editor-api)', () {
    test('add validates and rejects duplicates', () {
      var queue = [_entry('anthropic', 'm')];
      queue = providerQueueAdd(queue, _entry('anthropic', 'm2'));
      expect(queue, hasLength(2));
      expect(
        () => providerQueueAdd(queue, _entry('anthropic', 'm')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => providerQueueAdd(
          queue,
          ProviderQueueEntry(providerType: 'x', model: 'm'),
        ),
        throwsA(anything),
      );
    });

    test('removeAt and move reorder/move-to-head', () {
      final queue = [
        _entry('anthropic', 'a'),
        _entry('anthropic', 'b'),
        _entry('anthropic', 'c'),
      ];
      expect(providerQueueRemoveAt(queue, 1).map((e) => e.model), ['a', 'c']);
      expect(providerQueueMove(queue, 2, 0).map((e) => e.model).toList(), [
        'c',
        'a',
        'b',
      ]);
      expect(() => providerQueueRemoveAt(queue, 9), throwsA(isA<RangeError>()));
    });

    test(
      'yaml body round-trips through the yaml parser (UT-yaml-roundtrip)',
      () {
        final body = providersQueueYamlBody([
          _entry('openai-completions', 'm-1', baseUrl: 'https://g.test/v1'),
          _entry('anthropic', 'm-2', apiKeyEnv: 'K2_API_KEY'),
        ]);
        expect(body, contains('- provider_type: openai-completions'));
        expect(body, contains('apiKeyEnv: K2_API_KEY'));
        expect(body, isNot(contains('sk-')));
        final loaded = loadYaml('providersQueue:\n$body') as YamlMap;
        final parsed = parseProviderQueueYaml(
          loaded['providersQueue'],
          source: 'test',
        );
        expect(parsed.entries, hasLength(2));
        expect(parsed.entries[0].model, 'm-1');
        expect(parsed.entries[0].baseUrl, 'https://g.test/v1');
        expect(parsed.entries[1].apiKeyEnv, 'K2_API_KEY');
      },
    );
  });

  group('classifyQueueDeath (UT-17 kind strings)', () {
    final m = _model('anthropic', 'm');

    ({QueueDeathKind? kind, bool immediate, Duration? cooldown}) classify(
      ErrorEvent event,
    ) {
      final death = classifyQueueDeath(event);
      return (
        kind: death?.kind,
        immediate: death?.immediate ?? false,
        cooldown: death?.cooldown,
      );
    }

    test('429 → quota with Retry-After cooldown', () {
      final r = classify(
        _err(
          m,
          '429: too many requests',
          retryAfter: const Duration(seconds: 7),
        ),
      );
      expect(r.kind, QueueDeathKind.quota);
      expect(r.cooldown, const Duration(seconds: 7));
    });

    test('quota without Retry-After → default 60s (UT-cooldown-borders)', () {
      final r = classify(_err(m, 'quota exceeded for this project'));
      expect(r.kind, QueueDeathKind.quota);
      expect(r.cooldown, providerQueueDefaultCooldown);
    });

    test(
      'budget/spending exhaustion → quota death, immediate (issue #926)',
      () {
        final r = classify(
          _err(
            m,
            '403: CodeMie monthly budget limit reached '
            '(\$150.08 / \$150.00). Next budget reset: 01/10/2026',
          ),
        );
        expect(r.kind, QueueDeathKind.quota);
        expect(r.immediate, isTrue);
        expect(r.cooldown, isNull);
      },
    );

    test('budget wording outranks the gateway 5xx and finish_reason nets', () {
      // A budget error wrapped in transport/terminal wordings must still
      // advance immediately, never surface verbatim or ride the ladder.
      final wrapped = classify(
        _err(m, '500: Internal network failure — spending limit reached'),
      );
      expect(wrapped.kind, QueueDeathKind.quota);
      expect(wrapped.immediate, isTrue);
    });

    test('401/403 → auth, immediate, no cooldown (UT-10)', () {
      for (final text in ['401 Unauthorized', '403 Forbidden: bad key']) {
        final r = classify(_err(m, text));
        expect(r.kind, QueueDeathKind.auth, reason: text);
        expect(r.immediate, isTrue);
      }
    });

    test('gh-1308: the zero-byte stall verdict → timeout death, immediate', () {
      // The entry's silent-replay budget is already spent — same-entry
      // retries cost a watchdog interval each. The queue advances at once.
      final r = classify(
        _err(
          m,
          'Provider zero-byte stall after 2 attempt(s) over 962s — the '
          'endpoint accepted the request but never produced output; '
          'the run-idle watchdog killed every silent attempt '
          '(zero-byte stall). Check the provider status or try again '
          'later.',
        ),
      );
      expect(r.kind, QueueDeathKind.timeout);
      expect(r.immediate, isTrue);
    });

    test('network, timeout, malformed, 5xx, finish_reason labels', () {
      expect(
        classify(_err(m, 'Connection refused (os error 111)')).kind,
        QueueDeathKind.network,
      );
      expect(
        classify(_err(m, 'Failed host lookup: api.test')).kind,
        QueueDeathKind.network,
      );
      expect(
        classify(
          _err(m, 'TimeoutException after 0:03:00: Future not completed'),
        ).kind,
        QueueDeathKind.timeout,
      );
      expect(
        classify(_err(m, 'stream ended without finish_reason')).kind,
        QueueDeathKind.malformed,
      );
      expect(classify(_err(m, '502 Bad Gateway')).kind, QueueDeathKind.fivexx);
      expect(
        classify(_err(m, '500: Internal network failure')).kind,
        QueueDeathKind.fivexx,
      );
      expect(
        classify(
          _err(
            m,
            'Provider finish_reason: unknown_stop_reason',
            rawStopReason: 'unknown_stop_reason',
          ),
        ).kind,
        QueueDeathKind.finishReason,
      );
    });

    test('every #1036 watchdog timeout renders retryable and classifies '
        'timeout (review round 1)', () {
      // The transcript path: the agent loop renders the thrown
      // TimeoutException via formatProviderError, the queue classifies the
      // rendered text. All five watchdog shapes must land on
      // QueueDeathKind.timeout (the retry-next-provider death), not
      // fall through to the verbatim unknown net.
      for (final exception in [
        TimeoutException(
          'provider fetch (models list): no response headers within '
          '30s (connect watchdog)',
        ),
        TimeoutException(
          'provider fetch (models list): response did not complete within '
          '120s (read watchdog; FA_PROVIDER_TIMEOUT_SECONDS overrides this)',
        ),
        TimeoutException(
          'provider stream request to https://example.test/v1/responses '
          'timed out: no response headers within 180s (connect watchdog)',
        ),
        TimeoutException(
          'no events from the endpoint for 300s (stream idle timeout)',
        ),
        TimeoutException(
          'chatgpt-codex https://example.test/v1/responses stalled: no SSE '
          'bytes for 300s (stream idle timeout)',
        ),
      ]) {
        final r = classify(_err(m, formatProviderError(exception)));
        expect(
          r.kind,
          QueueDeathKind.timeout,
          reason: r.runtimeType.toString(),
        );
      }
    });

    test('content_filter and user abort never advance (E-guard)', () {
      expect(
        classify(_err(m, 'Provider finish_reason: content_filter')).kind,
        isNull,
      );
      expect(
        classify(_err(m, 'aborted by user', reason: StopReason.aborted)).kind,
        isNull,
      );
      expect(classify(_err(m, 'something entirely novel')).kind, isNull);
    });
  });

  group('buildProviderQueueChain', () {
    test('builds models with kind→catalog mapping (openai-completions)', () {
      final chain = buildProviderQueueChain([
        _entry(
          'openai-completions',
          'm-1',
          baseUrl: 'https://openrouter.ai/api/v1',
        ),
        _entry('openai-completions', 'm-2', baseUrl: 'https://g.test/v1'),
        _entry('anthropic', 'm-3', apiKeyEnv: 'K2_API_KEY'),
      ], secrets: _secrets());
      expect(chain[0].model.provider, 'openrouter');
      expect(chain[1].model.provider, 'openai');
      expect(chain[1].model.baseUrl, 'https://g.test/v1');
      expect(chain[2].model.provider, 'anthropic');
    });

    test('an openai-completions entry WITHOUT baseUrl is rejected — no '
        'silent openrouter ride (gh-1570 M5/AC6)', () {
      // The legacy rule resolved the name-less kind to openrouter and sent
      // the entry's OPENAI_API_KEY to openrouter.ai. Identity-less means
      // rejected now.
      expect(
        () => buildProviderQueueChain([
          _entry('openai-completions', 'm-1', apiKeyEnv: 'K1_API_KEY'),
        ], secrets: _secrets()),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('m-1'), contains('baseUrl')),
          ),
        ),
      );
    });

    test('a queue entry whose model names another dialect is rejected '
        '(gh-1570 AC6 binding validation)', () {
      expect(
        () => buildProviderQueueChain([
          _entry('anthropic', 'zai/glm-5.3-flashx', apiKeyEnv: 'K1_API_KEY'),
        ], secrets: _secrets()),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('zai/glm-5.3-flashx'), contains('anthropic')),
          ),
        ),
      );
    });

    test('keyless env skips with a reason; all-keyless throws', () {
      final skipped = <String>[];
      final chain = buildProviderQueueChain(
        [
          _entry('anthropic', 'm-1', apiKeyEnv: 'MISSING_KEY'),
          _entry('anthropic', 'm-2'),
        ],
        secrets: _secrets(),
        skipped: skipped,
      );
      expect(chain, hasLength(1));
      expect(skipped.single, contains('MISSING_KEY'));
      expect(
        () => buildProviderQueueChain([
          _entry('anthropic', 'm', apiKeyEnv: 'MISSING_KEY'),
        ], secrets: _secrets()),
        throwsA(isA<ConfigException>()),
      );
    });

    // gh-1624 review r2: a queue entry whose vendor prefix names another
    // dialect stops exit-64ing on a private endpoint (the PR fix) but must
    // not ride SILENTLY either — the chain builder emits the binding's
    // warnings on the same out-channel pattern as [skipped].
    test('a queue entry with a foreign-dialect prefix on a private '
        'endpoint rides LOUD: the chain emits the binding warnings '
        '(gh-1624 review r2)', () {
      final warnings = <String>[];
      final chain = buildProviderQueueChain(
        [
          _entry(
            'anthropic',
            'zai/glm-5.3',
            baseUrl: 'http://192.168.1.23:8080/anthropic',
          ),
        ],
        secrets: _secrets(),
        warnings: warnings,
      );
      expect(chain, hasLength(1));
      expect(warnings, hasLength(1));
      expect(
        warnings.single,
        allOf(
          contains('anthropic/zai/glm-5.3'),
          contains('zai/glm-5.3'),
          contains('routing key'),
        ),
      );
    });

    test('a quiet entry emits no binding warnings (channel stays empty)', () {
      final warnings = <String>[];
      buildProviderQueueChain(
        [_entry('anthropic', 'claude-sonnet-4-5')],
        secrets: _secrets(),
        warnings: warnings,
      );
      expect(warnings, isEmpty);
    });
  });

  // Issue #1704: chatgpt-codex entries resolve their credential on a
  // ladder — apiKeyEnv (full OAuth blob or a raw Bearer token), then
  // refreshTokenEnv (mint on first activation, memoized in memory), then
  // the default Keychain slot name.
  group('buildProviderQueueChain — chatgpt-codex credential ladder', () {
    final blob = const ChatGptOAuthCredentials(
      accessToken: 'at-1',
      refreshToken: 'rt-1',
      idToken: 'it-1',
    ).encode();

    test('an omitted apiKeyEnv resolves the default Keychain slot', () {
      final skipped = <String>[];
      final chain = buildProviderQueueChain(
        [_entry('chatgpt-codex', 'gpt-5-codex', apiKeyEnv: null)],
        secrets: {'CHATGPT_OAUTH_CREDENTIALS': blob, ..._secrets()},
        skipped: skipped,
      );
      expect(chain, hasLength(1));
      expect(skipped, isEmpty);
      expect(chain.single.model.provider, 'chatgpt');
    });

    test('an omitted apiKeyEnv with no stored login is skipped with a '
        'login hint', () {
      final skipped = <String>[];
      buildProviderQueueChain(
        [
          _entry('chatgpt-codex', 'gpt-5-codex', apiKeyEnv: null),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ],
        secrets: _secrets(),
        skipped: skipped,
      );
      expect(skipped, hasLength(1));
      expect(skipped.single, contains('no ChatGPT login'));
      expect(skipped.single, contains('/provider chatgpt oauth'));
      expect(skipped.single, contains('CHATGPT_OAUTH_CREDENTIALS'));
    });

    test('a refreshTokenEnv entry mints once, then reuses the blob', () async {
      final probe = _Probe({
        'minted-blob': [
          _okTurn(_model('chatgpt', 'gpt-5-codex'), 'from-mint'),
          _okTurn(_model('chatgpt', 'gpt-5-codex'), 'again'),
        ],
      });
      var mints = 0;
      final chain = buildProviderQueueChain(
        [
          ProviderQueueEntry(
            providerType: 'chatgpt-codex',
            model: 'gpt-5-codex',
            refreshTokenEnv: 'CHATGPT_REFRESH_TOKEN',
          ),
        ],
        secrets: {'CHATGPT_REFRESH_TOKEN': 'rt-secret'},
        streamFactory: (kind, apiKey) => probe.streamForKey(apiKey),
        mintChatGptCredentials: (refreshToken) async {
          mints++;
          expect(refreshToken, 'rt-secret');
          return 'minted-blob';
        },
      );
      // The mint is LAZY: building the chain touches nothing.
      expect(mints, 0);
      expect(probe.calls, isEmpty);

      // First activation mints; the second reuses the memoized blob.
      for (var i = 0; i < 2; i++) {
        final events = await chain.single
            .streamForKey('rt-secret')(
              _model('chatgpt', 'gpt-5-codex'),
              const Context(messages: []),
            )
            .toList();
        expect(events.whereType<DoneEvent>(), hasLength(1));
      }
      expect(mints, 1);
      expect(probe.calls, hasLength(2));
      expect(probe.calls.every((c) => c.endsWith(':minted-blob')), isTrue);
    });

    test('a mint failure surfaces as the terminal error event', () async {
      final chain = buildProviderQueueChain(
        [
          ProviderQueueEntry(
            providerType: 'chatgpt-codex',
            model: 'gpt-5-codex',
            refreshTokenEnv: 'CHATGPT_REFRESH_TOKEN',
          ),
        ],
        secrets: {'CHATGPT_REFRESH_TOKEN': 'rt-secret'},
        streamFactory: (kind, apiKey) =>
            throw StateError('factory must not run'),
        mintChatGptCredentials: (refreshToken) async =>
            throw const ConfigException('invalid_grant: token revoked'),
      );
      final events = await chain.single
          .streamForKey('rt-secret')(
            _model('chatgpt', 'gpt-5-codex'),
            const Context(messages: []),
          )
          .toList();
      final error = events.whereType<ErrorEvent>().single;
      expect(error.error.errorMessage, contains('credential bootstrap'));
      expect(error.error.errorMessage, contains('invalid_grant'));
      expect(error.error.errorMessage, isNot(contains('rt-secret')));
    });

    test('a missing refresh token env skips the entry with the env name', () {
      final skipped = <String>[];
      buildProviderQueueChain(
        [
          ProviderQueueEntry(
            providerType: 'chatgpt-codex',
            model: 'gpt-5-codex',
            refreshTokenEnv: 'CHATGPT_REFRESH_TOKEN',
          ),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ],
        secrets: _secrets(),
        skipped: skipped,
      );
      expect(skipped.single, contains('missing refresh token'));
      expect(skipped.single, contains('CHATGPT_REFRESH_TOKEN'));
    });

    test('refreshTokenEnv on a non-chatgpt kind is a hard error', () {
      expect(
        () => buildProviderQueueChain(
          [
            ProviderQueueEntry(
              providerType: 'anthropic',
              model: 'm-1',
              refreshTokenEnv: 'CHATGPT_REFRESH_TOKEN',
            ),
          ],
          secrets: {'CHATGPT_REFRESH_TOKEN': 'rt'},
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('only to chatgpt-codex'),
          ),
        ),
      );
    });

    test('a non-chatgpt entry that names no key is a hard error', () {
      // The default ChatGPT slot is chatgpt-codex-only: other kinds must
      // name their key env (the chain has no identity without one).
      expect(
        () => buildProviderQueueChain(
          [_entry('openai-completions', 'm-1', apiKeyEnv: null)],
          secrets: {'CHATGPT_OAUTH_CREDENTIALS': 'blob'},
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('has no apiKeyEnv'),
          ),
        ),
      );
    });

    test('an apiKeyEnv raw bearer token passes through to the adapter', () {
      // The blob-to-Bearer tolerance lives in the adapter; the chain's
      // contract is passing the value through untouched (UT at the
      // seam: the factory receives exactly the env value).
      final probe = _Probe({
        'raw-bearer-at': [_okTurn(_model('chatgpt', 'gpt-5-codex'), 'ok')],
      });
      final chain = buildProviderQueueChain(
        [_entry('chatgpt-codex', 'gpt-5-codex', apiKeyEnv: 'CHATGPT_API_KEY')],
        secrets: {'CHATGPT_API_KEY': 'raw-bearer-at'},
        streamFactory: (kind, apiKey) => probe.streamForKey(apiKey),
      );
      expect(chain, hasLength(1));
    });

    test('refreshTokenEnv round-trips through toJson/fromJsonMap', () {
      final entry = ProviderQueueEntry.fromJsonMap({
        'provider_type': 'chatgpt-codex',
        'provider_config': {
          'model': 'gpt-5-codex',
          'refreshTokenEnv': 'CHATGPT_REFRESH_TOKEN',
        },
      }, position: 1);
      expect(entry.refreshTokenEnv, 'CHATGPT_REFRESH_TOKEN');
      final restored = ProviderQueueEntry.fromJsonMap(
        entry.toJson(),
        position: 1,
      );
      expect(restored.refreshTokenEnv, entry.refreshTokenEnv);
    });
  });

  // gh-1624 review r2: the runtime build forwards the chain's binding
  // warnings so hosts (boot, REPL queue reload) can render them — the
  // queue lane's mismatch never rides silently.
  group('ProviderQueueRuntime.build — binding warning surfacing', () {
    test(
      'build forwards the chain\'s binding warnings to onBindingWarning',
      () {
        final lines = <String>[];
        ProviderQueueRuntime.build(
          ProviderQueueResolution(
            scope: ProviderQueueScope.env,
            entries: [
              _entry(
                'anthropic',
                'zai/glm-5.3',
                baseUrl: 'http://192.168.1.23:8080/anthropic',
              ),
            ],
            notices: const [],
          ),
          secrets: _secrets(),
          onBindingWarning: lines.add,
        );
        expect(lines, hasLength(1));
        expect(lines.single, contains('zai/glm-5.3'));
      },
    );
  });

  // gh-1781: the boot-level queue contract — partial key sets skip the
  // keyless head LOUDLY (a warning reaches the host channel), an
  // all-keyless queue is the loud ConfigException (never the legacy
  // missing-OPENROUTER-key failure), and the secrets snapshot carries the
  // rotation stack so multi-credential entries build a real ApiKeyRing.
  group('ProviderQueueRuntime.build — boot key gates (gh-1781)', () {
    test('UT-queue-partial-keys-boot: a keyless head is skipped with a '
        'warning and the keyed entry leads (AC2, E1)', () {
      final lines = <String>[];
      final runtime = ProviderQueueRuntime.build(
        ProviderQueueResolution(
          scope: ProviderQueueScope.env,
          entries: [
            _entry('anthropic', 'm-0', apiKeyEnv: 'MISSING_KEY_1'),
            _entry('anthropic', 'm-1', apiKeyEnv: 'PRESENT_KEY_2'),
          ],
          notices: const [],
        ),
        secrets: {'PRESENT_KEY_2': 'key-two-value'},
        onBindingWarning: lines.add,
      );
      expect(runtime.streamFunction.currentModel.id, 'm-1');
      expect(lines, hasLength(1));
      expect(
        lines.single,
        allOf(
          startsWith('warning: provider queue skipped '),
          contains('anthropic/m-0'),
          contains('MISSING_KEY_1'),
        ),
      );
    });

    test('UT-queue-partial-keys-boot: a fully keyed queue emits no skip '
        'warning', () {
      final lines = <String>[];
      ProviderQueueRuntime.build(
        ProviderQueueResolution(
          scope: ProviderQueueScope.env,
          entries: [_entry('anthropic', 'm-0')],
          notices: const [],
        ),
        secrets: {'K_API_KEY': 'key-head-value'},
        onBindingWarning: lines.add,
      );
      expect(lines, isEmpty);
    });

    test('UT-queue-all-keys-missing: every entry keyless throws the loud '
        'queue error naming each missing var (AC3)', () {
      expect(
        () => ProviderQueueRuntime.build(
          ProviderQueueResolution(
            scope: ProviderQueueScope.env,
            entries: [
              _entry('anthropic', 'm-0', apiKeyEnv: 'MISSING_KEY_1'),
              _entry('anthropic', 'm-1', apiKeyEnv: 'MISSING_KEY_2'),
            ],
            notices: const [],
          ),
          secrets: const {},
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('the provider queue has no usable entry'),
              contains('MISSING_KEY_1'),
              contains('MISSING_KEY_2'),
              isNot(contains('OPENROUTER_API_KEY')),
            ),
          ),
        ),
      );
    });

    test('UT-queue-secrets-rotation-stack: collectQueueSecrets captures '
        'KEY, KEY_2, KEY_3 from env and backs the base from the store '
        '(AC4, E2)', () async {
      final keys = SecureKeyCache(_FakeStore({'ZAI_CODE_KEY': 'store-zai'}));
      await keys.preload(const {'ZAI_CODE_KEY'});
      final secrets = collectQueueSecrets(
        [_entry('zai', 'glm-5.3-flash', apiKeyEnv: 'ZAI_CODE_KEY')],
        keys,
        env: const {
          'ZAI_CODE_KEY_2': 'env-two-value1',
          'ZAI_CODE_KEY_3': 'env-three-val',
        },
      );
      expect(secrets, {
        'ZAI_CODE_KEY': 'store-zai',
        'ZAI_CODE_KEY_2': 'env-two-value1',
        'ZAI_CODE_KEY_3': 'env-three-val',
      });
    });

    test('UT-queue-secrets-rotation-stack: the stack feeds a multi-key '
        'ApiKeyRing (AC4, E2)', () {
      final chain = buildProviderQueueChain(
        [_entry('zai', 'glm-5.3-flash', apiKeyEnv: 'ZAI_CODE_KEY')],
        secrets: collectQueueSecrets(
          [_entry('zai', 'glm-5.3-flash', apiKeyEnv: 'ZAI_CODE_KEY')],
          SecureKeyCache(_FakeStore(const {})),
          env: const {
            'ZAI_CODE_KEY': 'env-base-value',
            'ZAI_CODE_KEY_2': 'env-two-value1',
          },
        ),
      );
      expect(chain.single.keyRing.length, 2);
    });

    test('UT-queue-secrets-rotation-stack: an unrelated NAME_2-shaped var '
        'is not captured', () async {
      final keys = SecureKeyCache(_FakeStore(const {}));
      await keys.preload(const {'ZAI_CODE_KEY'});
      final secrets = collectQueueSecrets(
        [_entry('zai', 'glm-5.3-flash', apiKeyEnv: 'ZAI_CODE_KEY')],
        keys,
        env: const {
          'ZAI_CODE_KEY_OLD': 'old-value-123',
          'OTHER_KEY_2': 'other-2-value',
        },
      );
      expect(secrets, isEmpty);
    });
  });

  group('ProviderQueueRuntime failover (UT-18..26, IT-37)', () {
    late DateTime now;
    late List<Duration> sleeps;
    late List<FallbackNotice> notices;

    setUp(() {
      now = DateTime.utc(2026);
      sleeps = [];
      notices = [];
    });

    Future<List<AssistantMessageEvent>> drive(FallbackStreamFunction fn) async {
      final out = fn(
        _model('anthropic', 'ignored'),
        const Context(messages: []),
      );
      final events = <AssistantMessageEvent>[];
      await for (final event in out) {
        events.add(event);
      }
      return events;
    }

    ProviderQueueRuntime runtime(
      List<ProviderQueueEntry> entries,
      _Probe probe, {
      Map<String, String>? secrets,
      ModelRolesRetryPolicy policy = const ModelRolesRetryPolicy(
        retriesPerEntry: 0,
      ),
    }) => ProviderQueueRuntime.build(
      ProviderQueueResolution(
        scope: ProviderQueueScope.env,
        entries: entries,
        notices: const [],
      ),
      secrets: secrets ?? _secrets(),
      policy: policy,
      now: () => now,
      jitterFraction: () => 1.0,
      sleeper: (delay, token) async {
        sleeps.add(delay);
        now = now.add(delay);
        return true;
      },
      onNotice: notices.add,
      streamFactory: (kind, apiKey) => probe.streamForKey(apiKey),
    );

    test(
      'failover on death then sticky cursor: 10/10 on the winner (UT-sticky)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '502 Bad Gateway'),
          ],
          'key-two': [
            _okTurn(_model('anthropic', 'm2'), 'a'),
            for (var i = 0; i < 10; i++)
              _okTurn(_model('anthropic', 'm2'), 'again $i'),
          ],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        await drive(rt.streamFunction);
        for (var i = 0; i < 10; i++) {
          await drive(rt.streamFunction);
        }
        expect(probe.calls.where((c) => c.startsWith('m1:')), hasLength(1));
        expect(probe.calls.where((c) => c.startsWith('m2:')), hasLength(11));
        expect(rt.state.currentIndex, 1);
        // The switch is loud and carries the 5xx kind (AC3, UT-17).
        expect(
          notices.where((n) => n.kind == FallbackNoticeKind.modelFallback),
          hasLength(1),
        );
        expect(
          notices
              .firstWhere((n) => n.kind == FallbackNoticeKind.modelFallback)
              .reason,
          contains('5xx'),
        );
      },
    );

    test(
      'cooldown re-probe at exact expiry; success heals (UT-cooldown-reprobe, AC5)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '429: rate limited'),
            _okTurn(_model('anthropic', 'm1'), 'healed'),
          ],
          'key-two': [_okTurn(_model('anthropic', 'm2'), 'b')],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        await drive(rt.streamFunction);
        // Head is cooling for 60s (the 429 had no Retry-After); the next call
        // goes to entry 2.
        await drive(rt.streamFunction);
        expect(probe.calls.last, startsWith('m2:'));
        expect(
          rt.state.cooldownRemaining(0, now),
          providerQueueDefaultCooldown,
        );
        // 1ms before expiry: still cooling.
        now = now.add(
          providerQueueDefaultCooldown - const Duration(milliseconds: 1),
        );
        await drive(rt.streamFunction);
        expect(probe.calls.last, startsWith('m2:'));
        // At expiry: head re-probed, success resets the failure counters.
        now = now.add(const Duration(milliseconds: 1));
        await drive(rt.streamFunction);
        expect(probe.calls.last, startsWith('m1:'));
        expect(rt.state.lastErrorKind(0), isNull);
        expect(rt.state.consecutiveFailures(0), 0);
      },
    );

    test(
      'consecutive quota failures double the cooldown up to the cap (UT-backoff-doubling)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '429: rate limited'),
            _deathTurn(_model('anthropic', 'm1'), '429: rate limited'),
            _deathTurn(_model('anthropic', 'm1'), '429: rate limited'),
          ],
          'key-two': [
            _okTurn(_model('anthropic', 'm2'), 'b'),
            _okTurn(_model('anthropic', 'm2'), 'b'),
            _okTurn(_model('anthropic', 'm2'), 'b'),
          ],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        // Three rounds: cooldowns 60s → 120s → 240s.
        for (var round = 0; round < 3; round++) {
          await drive(rt.streamFunction); // m1 dies, failover to m2, serves
          await drive(rt.streamFunction); // m2 serves (sticky)
          expect(
            rt.state.cooldownRemaining(0, now),
            providerQueueDefaultCooldown * (1 << round),
            reason: 'round $round',
          );
          // Fast-forward past the current cooldown for the next round.
          now = now.add(providerQueueDefaultCooldown * (1 << round));
        }
      },
    );

    test(
      'Retry-After beyond the clamp clamps to 24h (UT-cooldown-borders)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '429: rate limited'),
          ],
          'key-two': [_okTurn(_model('anthropic', 'm2'), 'b')],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        // The Retry-After rides the ErrorEvent, not the queue entry; the
        // classifier reads it from the event.
        // (Covered at classifier level above; here the default path proves
        // the clamp wiring exists via providerQueueMaxCooldown.)
        await drive(rt.streamFunction);
        expect(
          rt.state.cooldownRemaining(0, now),
          lessThanOrEqualTo(providerQueueMaxCooldown),
        );
      },
    );

    test(
      'auth death advances immediately and leaves no cooldown (UT-10)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '401 Unauthorized'),
            _deathTurn(_model('anthropic', 'm1'), '401 Unauthorized'),
          ],
          'key-two': [
            _okTurn(_model('anthropic', 'm2'), 'b'),
            _okTurn(_model('anthropic', 'm2'), 'b'),
          ],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        await drive(rt.streamFunction);
        // m1 died once (auth), m2 served; no cooldown was left on m1.
        expect(probe.calls, ['m1:key-head', 'm2:key-two']);
        expect(rt.state.cooldownRemaining(0, now), isNull);
        expect(sleeps, isEmpty, reason: 'no retry sleep for a dead key');
        // The next call re-probes the head (no cooldown after an auth
        // death) and fails over again (UT-10).
        await drive(rt.streamFunction);
        expect(probe.calls, [
          'm1:key-head',
          'm2:key-two',
          'm1:key-head',
          'm2:key-two',
        ]);
      },
    );

    test(
      'a refreshTokenEnv mint entry fails over like any other (issue #1704)',
      () async {
        final probe = _Probe({
          // The minted blob is the factory key the adapter would see.
          'minted-blob': [
            _deathTurn(_model('chatgpt', 'm1'), '401 Unauthorized'),
          ],
          'key-two': [_okTurn(_model('anthropic', 'm2'), 'b')],
        });
        final rt = ProviderQueueRuntime.build(
          ProviderQueueResolution(
            scope: ProviderQueueScope.env,
            entries: [
              ProviderQueueEntry(
                providerType: 'chatgpt-codex',
                model: 'm1',
                refreshTokenEnv: 'CHATGPT_REFRESH_TOKEN',
              ),
              _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
            ],
            notices: const [],
          ),
          secrets: {'CHATGPT_REFRESH_TOKEN': 'rt-secret', ..._secrets()},
          policy: const ModelRolesRetryPolicy(retriesPerEntry: 0),
          now: () => now,
          jitterFraction: () => 1.0,
          sleeper: (delay, token) async {
            sleeps.add(delay);
            now = now.add(delay);
            return true;
          },
          onNotice: notices.add,
          streamFactory: (kind, apiKey) => probe.streamForKey(apiKey),
          mintChatGptCredentials: (refreshToken) async => 'minted-blob',
        );
        await drive(rt.streamFunction);
        // The mint entry's auth death advanced the cursor to entry 1.
        expect(rt.state.currentIndex, 1);
        expect(probe.calls, ['m1:minted-blob', 'm2:key-two']);
      },
    );

    test(
      'every entry cooling → terminal with per-entry ETAs (UT-23)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '429: rate limit'),
          ],
          'key-two': [_deathTurn(_model('anthropic', 'm2'), '429: rate limit')],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        await drive(rt.streamFunction); // both die, both cool
        final events = await drive(rt.streamFunction);
        final error = events.whereType<ErrorEvent>().single;
        expect(error.error.errorMessage, contains('queue cooling down'));
        expect(error.error.errorMessage, contains('m1'));
        expect(error.error.errorMessage, contains('m2'));
      },
    );

    test(
      'exhausted queue → one terminal with per-entry health (UT-24)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '503 Service Unavailable'),
          ],
          'key-two': [_deathTurn(_model('anthropic', 'm2'), '429: quota')],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        final events = await drive(rt.streamFunction);
        final error = events.whereType<ErrorEvent>().single;
        final text = error.error.errorMessage!;
        expect(text, contains('Provider chain exhausted'));
        expect(text, contains('5xx'));
        expect(text, contains('quota'));
        expect(text, contains('Queue health'));
      },
    );

    test('sole queue entry waits out a quota wall: waited total in the story '
        '(issue #1066)', () async {
      final m = _model('anthropic', 'm1');
      List<AssistantMessageEvent> quotaWallTurn() => [
        StartEvent(partial: _msg(m)),
        _err(m, '429: quota', retryAfter: const Duration(seconds: 90)),
      ];
      final probe = _Probe({
        'key-head': [quotaWallTurn(), quotaWallTurn(), quotaWallTurn()],
      });
      final rt = runtime(
        [_entry('anthropic', 'm1')],
        probe,
        policy: const ModelRolesRetryPolicy(
          retriesPerEntry: 2,
          maxWait: Duration(seconds: 30),
        ),
      );

      final events = await drive(rt.streamFunction);

      // Queue deaths ride the transport-flagged rotation path, but the
      // QUOTA class keys the accounting: two 90s wait-outs announced as
      // plain retries, and the story reports the waited total.
      expect(sleeps, [
        const Duration(seconds: 90),
        const Duration(seconds: 90),
      ]);
      expect(
        notices.map((n) => n.kind),
        everyElement(FallbackNoticeKind.retry),
      );
      final error = events.whereType<ErrorEvent>().single;
      final text = error.error.errorMessage!;
      expect(text, contains('Provider chain exhausted'));
      expect(text, contains('waited 3m on rate limits'));
      expect(text, contains('Queue health'));
    });

    test(
      'mid-turn committed failure stands; next turn uses the next entry (UT-midturn-boundary)',
      () async {
        final m1 = _model('anthropic', 'm1');
        final probe = _Probe({
          'key-head': [
            [
              // A committed (post-content) death: the turn stands on m1.
              StartEvent(partial: _msg(m1)),
              TextStartEvent(contentIndex: 0, partial: _msg(m1)),
              TextDeltaEvent(
                contentIndex: 0,
                delta: 'partial answer',
                partial: _msg(m1, text: 'partial answer'),
              ),
              _err(m1, '504 Gateway Timeout'),
            ],
          ],
          'key-two': [_okTurn(_model('anthropic', 'm2'), 'next turn')],
        });
        final rt = runtime([
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ], probe);
        final first = await drive(rt.streamFunction);
        final error = first.whereType<ErrorEvent>().single;
        expect(error.error.errorMessage, contains('mid-answer'));
        expect(first.map((e) => e.runtimeType), contains(TextDeltaEvent));
        final second = await drive(rt.streamFunction);
        print(
          'DBG2=${second.map((e) => e.runtimeType).toList()} cooling0=${rt.state.cooldownRemaining(0, now)} idx=${rt.state.currentIndex}',
        );
        expect(second.whereType<DoneEvent>().single.message.model, 'm2');
      },
    );

    test(
      'fresh runtime restarts at the head (AC6, UT-restart-resets)',
      () async {
        final probe = _Probe({
          'key-head': [
            _deathTurn(_model('anthropic', 'm1'), '429: rate limit'),
            _okTurn(_model('anthropic', 'm1'), 'back at head'),
          ],
          'key-two': [_okTurn(_model('anthropic', 'm2'), 'b')],
        });
        final entries = [
          _entry('anthropic', 'm1'),
          _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
        ];
        final first = runtime(entries, probe);
        await drive(first.streamFunction);
        expect(first.state.currentIndex, 1);
        // A fresh build (what a restart does) starts at the head again.
        final second = runtime(entries, probe);
        expect(second.state.currentIndex, 0);
      },
    );

    test(
      'no queue → no runtime change: legacy byte-identical (AC10, REG-45)',
      () {
        final r = resolveProviderQueueScopes([]);
        expect(r.isSet, isFalse);
        expect(r.notices, isEmpty);
      },
    );
  });

  group('ProviderQueueRuntime notice listeners (gh-1617 review r2)', () {
    // gh-1617 review r2 (IMPORTANT): hosts build the runtime at boot but
    // wire the agent later — the queue lane needs a late-attach listener
    // so a mid-run failover can re-sync `agent.state.model` (the
    // watchdog's arm-time window reads it) exactly like the roles lane's
    // `_onRolesNotice` does.
    late DateTime now;

    setUp(() {
      now = DateTime.utc(2026);
    });

    Future<List<AssistantMessageEvent>> drive(FallbackStreamFunction fn) async {
      final out = fn(
        _model('anthropic', 'ignored'),
        const Context(messages: []),
      );
      final events = <AssistantMessageEvent>[];
      await for (final event in out) {
        events.add(event);
      }
      return events;
    }

    ProviderQueueRuntime failoverRuntime({
      void Function(FallbackNotice notice)? onNotice,
      List<FallbackNotice>? lateNotices,
    }) {
      final probe = _Probe({
        'key-head': [_deathTurn(_model('anthropic', 'm1'), '502 Bad Gateway')],
        'key-two': [_okTurn(_model('anthropic', 'm2'), 'a')],
      });
      final rt = ProviderQueueRuntime.build(
        ProviderQueueResolution(
          scope: ProviderQueueScope.env,
          entries: [
            _entry('anthropic', 'm1'),
            _entry('anthropic', 'm2', apiKeyEnv: 'K2_API_KEY'),
          ],
          notices: const [],
        ),
        secrets: _secrets(),
        policy: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        now: () => now,
        jitterFraction: () => 1.0,
        sleeper: (delay, token) async => true,
        onNotice: onNotice,
        streamFactory: (kind, apiKey) => probe.streamForKey(apiKey),
      );
      if (lateNotices != null) rt.addNoticeListener(lateNotices.add);
      return rt;
    }

    test('a late-attached listener rides the same dispatch as the build '
        'handler', () async {
      final buildNotices = <FallbackNotice>[];
      final lateNotices = <FallbackNotice>[];
      final rt = failoverRuntime(
        onNotice: buildNotices.add,
        lateNotices: lateNotices,
      );
      await drive(rt.streamFunction);
      expect(
        buildNotices.where((n) => n.kind == FallbackNoticeKind.modelFallback),
        hasLength(1),
      );
      expect(
        lateNotices.map((n) => n.kind),
        buildNotices.map((n) => n.kind),
        reason:
            'the late listener sees exactly the notices the build '
            'handler sees, in order',
      );
    });

    test('a listener works with NO build handler (the boot never wired '
        'onNotice — the fah_runapp shape)', () async {
      final lateNotices = <FallbackNotice>[];
      final rt = failoverRuntime(lateNotices: lateNotices);
      await drive(rt.streamFunction);
      expect(
        lateNotices.where((n) => n.kind == FallbackNoticeKind.modelFallback),
        hasLength(1),
      );
    });

    test('no listener: dispatch stays inert and the failover is '
        'byte-identical (legacy boot)', () async {
      final rt = failoverRuntime();
      final events = await drive(rt.streamFunction);
      expect(events.whereType<DoneEvent>(), hasLength(1));
      expect(rt.state.currentIndex, 1);
    });
  });
}

void _bootScopeTests() {
  group('boot scope resolution (IT-33..36)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fahqueue'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('project .fah/config.yaml wins over user; env wins over both', () {
      final project = Directory('${tmp.path}/proj')..createSync();
      Directory('${project.path}/.fah').createSync();
      File('${project.path}/.fah/config.yaml').writeAsStringSync(
        'providersQueue:\n'
        '  - provider_type: anthropic\n'
        '    provider_config: {model: pm, apiKeyEnv: K1_API_KEY}\n',
      );
      final home = Directory('${tmp.path}/home')..createSync();
      Directory('${home.path}/.fah').createSync();
      File('${home.path}/.fah/config.yaml').writeAsStringSync(
        'providersQueue:\n'
        '  - provider_type: anthropic\n'
        '    provider_config: {model: um, apiKeyEnv: K2_API_KEY}\n',
      );
      var r = resolveProviderQueueAtBoot(
        projectDir: project.path,
        homeDir: home.path,
        env: const {},
      );
      expect(r.scope, ProviderQueueScope.project);
      expect(r.entries.single.model, 'pm');
      expect(r.notices, hasLength(2), reason: 'winner note + shadowed note');

      r = resolveProviderQueueAtBoot(
        projectDir: project.path,
        homeDir: home.path,
        env: {
          'FA_PROVIDERS_QUEUE': jsonEncode([
            {
              'provider_type': 'anthropic',
              'provider_config': {'model': 'em', 'apiKeyEnv': 'K3_API_KEY'},
            },
          ]),
        },
      );
      expect(r.scope, ProviderQueueScope.env);
      expect(r.entries.single.model, 'em');
    });

    test(
      'absent files and sections are not present; no queue = no notices',
      () {
        final r = resolveProviderQueueAtBoot(
          projectDir: tmp.path,
          homeDir: tmp.path,
          env: const {},
        );
        expect(r.entries, isEmpty);
        expect(r.notices, isEmpty);
      },
    );

    test(
      'present-but-invalid section is a hard boot error naming the file',
      () {
        Directory('${tmp.path}/.fah').createSync();
        File(
          '${tmp.path}/.fah/config.yaml',
        ).writeAsStringSync('providersQueue: [nope\n');
        expect(
          () => resolveProviderQueueAtBoot(
            projectDir: tmp.path,
            homeDir: tmp.path,
            env: const {},
          ),
          throwsA(isA<ConfigException>()),
        );
      },
    );

    test('collectQueueSecrets: env wins, secure store backs up', () async {
      final store = _FakeStore({'K_STORED': 'stored-value'});
      final keys = SecureKeyCache(store);
      await keys.preload(const {'K_ENV', 'K_STORED', 'K_MISSING'});
      final entries = [
        _entry('anthropic', 'a', apiKeyEnv: 'K_ENV'),
        _entry('anthropic', 'b', apiKeyEnv: 'K_STORED'),
        _entry('anthropic', 'c', apiKeyEnv: 'K_MISSING'),
      ];
      final secrets = collectQueueSecrets(
        entries,
        keys,
        env: {'K_ENV': 'env-value'},
      );
      expect(secrets['K_ENV'], 'env-value');
      expect(secrets['K_STORED'], 'stored-value');
      expect(secrets.containsKey('K_MISSING'), isFalse);
    });
  });

  group('type naming in parse errors (gh-1713 CRAP descent)', () {
    String nodeMessage(Object? node) {
      try {
        parseProviderQueueEntries(node, source: 'q');
      } on ConfigException catch (e) {
        return e.message;
      }
      fail('expected ConfigException');
    }

    String itemMessage(Object? item) => nodeMessage([item]);

    test('a non-array node names the decoded type', () {
      expect(nodeMessage(null), contains('got nothing'));
      expect(nodeMessage('x'), contains('got a string'));
      expect(nodeMessage(42), contains('got a number'));
      expect(nodeMessage(true), contains('got a boolean'));
      expect(nodeMessage({'a': 1}), contains('got an object'));
    });

    test('a non-object entry names the decoded type', () {
      expect(itemMessage(1.5), contains('got a number'));
      expect(itemMessage(true), contains('got a boolean'));
      expect(itemMessage('s'), contains('got a string'));
      expect(itemMessage([1]), contains('got an array'));
      expect(itemMessage(null), contains('got nothing'));
      expect(itemMessage(Object()), contains('got Object'));
    });
  });
}

final class _FakeStore implements SecureKeyStore {
  _FakeStore(this._values);
  final Map<String, String> _values;
  @override
  String get label => 'test store';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<String?> read(String name) async => _values[name];
  @override
  Future<void> write(String name, String value) async => _values[name] = value;
  @override
  Future<void> delete(String name) async => _values.remove(name);
}
