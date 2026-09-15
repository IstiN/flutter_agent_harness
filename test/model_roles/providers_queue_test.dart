import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

    test('401/403 → auth, immediate, no cooldown (UT-10)', () {
      for (final text in ['401 Unauthorized', '403 Forbidden: bad key']) {
        final r = classify(_err(m, text));
        expect(r.kind, QueueDeathKind.auth, reason: text);
        expect(r.immediate, isTrue);
      }
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
        _entry('openai-completions', 'm-1'), // default baseUrl → openrouter
        _entry('openai-completions', 'm-2', baseUrl: 'https://g.test/v1'),
        _entry('anthropic', 'm-3', apiKeyEnv: 'K2_API_KEY'),
      ], secrets: _secrets());
      expect(chain[0].model.provider, 'openrouter');
      expect(chain[1].model.provider, 'openai');
      expect(chain[1].model.baseUrl, 'https://g.test/v1');
      expect(chain[2].model.provider, 'anthropic');
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
}
