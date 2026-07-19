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
}) {
  return AssistantMessage(
    content: text.isEmpty ? const [] : [TextContent(text: text)],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stop,
    errorMessage: error,
    timestamp: DateTime.utc(2026),
  );
}

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

List<AssistantMessageEvent> _rateLimitTurn(
  Model model, {
  Duration? retryAfter,
  String error = '429: rate limit exceeded',
}) {
  final partial = _msg(model);
  return [
    StartEvent(partial: partial),
    ErrorEvent(
      reason: StopReason.error,
      error: _msg(model, stop: StopReason.error, error: error),
      retryAfter: retryAfter,
    ),
  ];
}

/// A scripted stream factory: serves pre-recorded turns per API-key value.
class _Probe {
  final Map<String, List<List<AssistantMessageEvent>>> scriptsByKey;
  final calls = <String>[];

  _Probe(this.scriptsByKey);

  StreamFunction streamForKey(String apiKey) {
    return (model, context, {cancelToken}) {
      calls.add(apiKey);
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

String _signature(AssistantMessageEvent event) => switch (event) {
  StartEvent(:final partial) => 'start:${partial.model}',
  TextStartEvent() => 'textStart',
  TextDeltaEvent(:final delta) => 'delta:$delta',
  DoneEvent(:final message) => 'done:${message.model}',
  ErrorEvent(:final reason, :final error) =>
    'error(${reason.name}):${error.model}:${error.errorMessage}',
  _ => event.runtimeType.toString(),
};

void main() {
  group('FallbackStreamFunction', () {
    late DateTime now;
    late List<Duration> sleeps;
    late List<FallbackNotice> notices;

    setUp(() {
      now = DateTime.utc(2026);
      sleeps = [];
      notices = [];
    });

    ChainEntry entry(
      _Probe probe,
      Model model,
      List<String> keyValues, {
      Duration? keyBackoff,
    }) {
      return ChainEntry(
        model: model,
        keyRing: ApiKeyRing(
          baseName: 'K_${model.provider}_${model.id}',
          credentials: [
            for (var i = 0; i < keyValues.length; i++)
              ApiKeyCredential(
                i == 0 ? 'K_${model.id}' : 'K_${model.id}_${i + 1}',
                keyValues[i],
              ),
          ],
          startIndex: 0,
          now: () => now,
        ),
        streamForKey: probe.streamForKey,
      );
    }

    FallbackStreamFunction wrapper(
      List<ChainEntry> entries, {
      ModelRolesRetryPolicy policy = const ModelRolesRetryPolicy(),
      Future<bool> Function(Duration, CancelToken?)? sleeper,
    }) {
      return FallbackStreamFunction(
        entries: entries,
        policy: policy,
        onNotice: notices.add,
        now: () => now,
        jitterFraction: () => 1.0,
        sleeper:
            sleeper ??
            (delay, token) async {
              sleeps.add(delay);
              now = now.add(delay);
              return true;
            },
      );
    }

    Future<List<String>> run(
      FallbackStreamFunction w, {
      CancelToken? cancelToken,
    }) async {
      final stream = w.call(
        _model('ignored', 'ignored'),
        const Context(messages: []),
        cancelToken: cancelToken,
      );
      return [for (final event in await stream.toList()) _signature(event)];
    }

    test('falls back to the next chain entry on 429, note surfaced', () async {
      final a = _model('openai', 'gpt-a');
      final b = _model('anthropic', 'claude-b');
      final probe = _Probe({
        'v-a': [_rateLimitTurn(a)],
        'v-b': [_okTurn(b, 'hello from b')],
      });
      final w = wrapper(
        [
          entry(probe, a, ['v-a']),
          entry(probe, b, ['v-b']),
        ],
        // No same-entry retries: the run takes over with the next entry
        // right after the first rate-limit failure.
        policy: const ModelRolesRetryPolicy(retriesPerEntry: 0),
      );

      final events = await run(w);

      // Only B's events were forwarded — the rate-limited attempt left no
      // trace (not even its StartEvent).
      expect(events, [
        'start:${b.id}',
        'textStart',
        'delta:hello from b',
        'done:${b.id}',
      ]);
      expect(probe.calls, ['v-a', 'v-b']);
      expect(sleeps, isEmpty); // model switches are delay-0 (omp rule)
      expect(notices, hasLength(1));
      final notice = notices.single;
      expect(notice.kind, FallbackNoticeKind.modelFallback);
      expect(notice.fromModel, 'openai/gpt-a');
      expect(notice.toModel, 'anthropic/claude-b');
      expect(notice.describe(), contains('falling back to anthropic/claude-b'));
      expect(w.activeIndex, 1);
      expect(w.currentModel.id, 'claude-b');
    });

    test(
      'retries the same entry with capped backoff before succeeding',
      () async {
        final a = _model('openai', 'gpt-a');
        final probe = _Probe({
          'v-a': [_rateLimitTurn(a), _okTurn(a, 'second try')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
        ]);

        final events = await run(w);

        expect(events.last, 'done:${a.id}');
        expect(probe.calls, ['v-a', 'v-a']);
        // jitter 1.0 → nominal 500ms first backoff (omp baseDelayMs).
        expect(sleeps, [const Duration(milliseconds: 500)]);
        expect(notices.single.kind, FallbackNoticeKind.retry);
        expect(notices.single.describe(), contains('retrying in 0.5s'));
      },
    );

    test('honors the provider Retry-After hint over local backoff', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [
          _rateLimitTurn(a, retryAfter: const Duration(seconds: 3)),
          _okTurn(a, 'after wait'),
        ],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
      ]);

      await run(w);

      expect(sleeps, [const Duration(seconds: 3)]);
    });

    test(
      'rotates API keys immediately (delay 0) before spending retries',
      () async {
        final a = _model('openai', 'gpt-a');
        final probe = _Probe({
          'v1': [_rateLimitTurn(a)],
          'v2': [_okTurn(a, 'second key works')],
        });
        final w = wrapper([
          entry(probe, a, ['v1', 'v2']),
        ]);

        final events = await run(w);

        expect(events.last, 'done:${a.id}');
        expect(probe.calls, ['v1', 'v2']);
        expect(sleeps, isEmpty);
        expect(notices.single.kind, FallbackNoticeKind.keyRotation);
        expect(notices.single.apiKeyName, 'K_gpt-a_2');
        expect(
          notices.single.describe(),
          contains('rotating API key to K_gpt-a_2'),
        );
      },
    );

    test(
      'never retries after observable output (mid-stream failure stands)',
      () async {
        final a = _model('openai', 'gpt-a');
        final partial = _msg(a);
        final withText = _msg(a, text: 'partial');
        final probe = _Probe({
          'v-a': [
            [
              StartEvent(partial: partial),
              TextStartEvent(contentIndex: 0, partial: partial),
              TextDeltaEvent(
                contentIndex: 0,
                delta: 'partial',
                partial: withText,
              ),
              ErrorEvent(
                reason: StopReason.error,
                error: _msg(
                  a,
                  stop: StopReason.error,
                  error: '429: rate limit exceeded',
                ),
              ),
            ],
            _okTurn(a, 'must not be served'),
          ],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
        ]);

        final events = await run(w);

        expect(probe.calls, ['v-a']); // no second attempt
        expect(events, contains('delta:partial'));
        expect(events.last, startsWith('error(error):${a.id}:429'));
        expect(notices, isEmpty);
      },
    );

    test('context overflow is not retried (compaction owns it)', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [
          _rateLimitTurn(
            a,
            error: 'prompt is too long: 213462 tokens > 200000 maximum',
          ),
        ],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
      ]);

      final events = await run(w);

      expect(probe.calls, ['v-a']);
      expect(events.last, contains('prompt is too long'));
      expect(notices, isEmpty);
    });

    test('non-rate-limit errors are not retried', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [_rateLimitTurn(a, error: '400: invalid request')],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
      ]);

      final events = await run(w);

      expect(probe.calls, ['v-a']);
      expect(events.last, contains('400: invalid request'));
      expect(notices, isEmpty);
    });

    test('aborted streams are forwarded without retry', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [
          [
            ErrorEvent(
              reason: StopReason.aborted,
              error: _msg(
                a,
                stop: StopReason.aborted,
                error: 'Request was aborted',
              ),
            ),
          ],
        ],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
      ]);

      final events = await run(w);

      expect(probe.calls, ['v-a']);
      expect(events.single, 'error(aborted):${a.id}:Request was aborted');
      expect(notices, isEmpty);
    });

    test('exhausted chain forwards the last error', () async {
      final a = _model('openai', 'gpt-a');
      final b = _model('anthropic', 'claude-b');
      final probe = _Probe({
        'v-a': [_rateLimitTurn(a), _rateLimitTurn(a, error: '429: still down')],
        'v-b': [_rateLimitTurn(b), _rateLimitTurn(b, error: '429: b down too')],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
        entry(probe, b, ['v-b']),
      ], policy: const ModelRolesRetryPolicy(retriesPerEntry: 1));

      final events = await run(w);

      expect(probe.calls, ['v-a', 'v-a', 'v-b', 'v-b']);
      expect(events.single, 'error(error):${b.id}:429: b down too');
      expect(notices.map((n) => n.kind), [
        FallbackNoticeKind.retry,
        FallbackNoticeKind.modelFallback,
        FallbackNoticeKind.retry,
      ]);
    });

    test(
      'cooldown skips a failed entry on the next call and reverts later',
      () async {
        final a = _model('openai', 'gpt-a');
        final b = _model('anthropic', 'claude-b');
        final probe = _Probe({
          'v-a': [_rateLimitTurn(a), _okTurn(a, 'a is back')],
          'v-b': [_okTurn(b, 'b takes over'), _okTurn(b, 'b again')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
          entry(probe, b, ['v-b']),
        ], policy: const ModelRolesRetryPolicy(retriesPerEntry: 0));

        await run(w); // A 429s, B takes over; A cools down (keyBackoff 60s)
        expect(w.isInCooldown(0), isTrue);

        final second = await run(w); // starts at B: A is benched
        expect(second, [
          'start:${b.id}',
          'textStart',
          'delta:b again',
          'done:${b.id}',
        ]);

        now = now.add(const Duration(minutes: 2)); // cooldown expires
        final third = await run(w); // reverts to the primary entry
        expect(third.last, 'done:${a.id}');
        expect(w.isInCooldown(0), isFalse);
      },
    );

    test('abort during the backoff sleep ends the call as aborted', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [_rateLimitTurn(a)],
      });
      final source = CancelTokenSource();
      final w = wrapper(
        [
          entry(probe, a, ['v-a']),
        ],
        sleeper: (delay, token) async {
          source.cancel();
          return false; // sleeper contract: false means cancelled
        },
      );

      final events = await run(w, cancelToken: source.token);

      expect(probe.calls, ['v-a']); // no second attempt
      expect(events.single, 'error(aborted):${a.id}:Request was aborted');
    });

    test('an empty Done (no content) is forwarded, not retried', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [
          [
            StartEvent(partial: _msg(a)),
            DoneEvent(reason: StopReason.stop, message: _msg(a)),
          ],
        ],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
      ]);

      final events = await run(w);

      expect(events, ['start:${a.id}', 'done:${a.id}']);
      expect(notices, isEmpty);
    });

    test(
      'waits for a benched sibling key when the whole stack is down',
      () async {
        final a = _model('openai', 'gpt-a');
        final probe = _Probe({
          'v1': [_rateLimitTurn(a)],
          'v2': [_rateLimitTurn(a), _okTurn(a, 'stack recovered')],
        });
        final w = wrapper([
          entry(probe, a, ['v1', 'v2']),
        ]);

        final events = await run(w);

        // k1 429 → rotate k2 → k2 429 → both benched 60s: backoff sleep 500ms,
        // then sibling wait until the earliest key frees (60s + 1s buffer).
        // The retry after the wait keeps round-robin order (k2 was current).
        expect(probe.calls, ['v1', 'v2', 'v2']);
        expect(events.last, 'done:${a.id}');
        expect(sleeps.first, const Duration(milliseconds: 500));
        expect(sleeps.length, 2);
        expect(sleeps[1] > const Duration(seconds: 55), isTrue);
        expect(
          sleeps[1] <= const Duration(seconds: 61),
          isTrue,
          reason: 'sibling wait ends 1s after the earliest bench',
        );
      },
    );

    test(
      'a Retry-After beyond maxWait fails over instead of sleeping',
      () async {
        final a = _model('openai', 'gpt-a');
        final b = _model('anthropic', 'claude-b');
        final probe = _Probe({
          'v-a': [_rateLimitTurn(a, retryAfter: const Duration(minutes: 10))],
          'v-b': [_okTurn(b, 'b instead of waiting')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
          entry(probe, b, ['v-b']),
        ]);

        final events = await run(w);

        expect(sleeps, isEmpty); // 10min > 5min maxWait: no sleep, failover
        expect(events.last, 'done:${b.id}');
        expect(notices.single.kind, FallbackNoticeKind.modelFallback);
      },
    );

    test('single-key exhaustion ends with the all-rate-limited path', () async {
      final a = _model('openai', 'gpt-a');
      final probe = _Probe({
        'v-a': [_rateLimitTurn(a), _rateLimitTurn(a), _rateLimitTurn(a)],
      });
      final w = wrapper([
        entry(probe, a, ['v-a']),
      ]);

      final events = await run(w);

      expect(probe.calls, hasLength(3)); // 1 + retriesPerEntry(2)
      expect(events.single, 'error(error):${a.id}:429: rate limit exceeded');
      expect(notices.map((n) => n.kind), [
        FallbackNoticeKind.retry,
        FallbackNoticeKind.retry,
      ]);
    });
  });

  group('isRateLimitOrQuota', () {
    AssistantMessage errorMessage(String text) => AssistantMessage(
      content: const [],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.error,
      errorMessage: text,
      timestamp: DateTime.utc(2026),
    );

    test('classifies 429, rate-limit, quota, throttling wordings', () {
      for (final text in [
        '429: rate limit exceeded',
        'Rate limit reached for requests',
        'too many requests, slow down',
        'insufficient_quota: You exceeded your current quota',
        'Resource has been exhausted (e.g. check quota)',
        'usage limit reached for this hour',
        'Throttling error: Too many tokens, please wait',
        '429 Too Many Requests',
      ]) {
        expect(isRateLimitOrQuota(errorMessage(text)), isTrue, reason: text);
      }
    });

    test('rejects overflow, non-errors, and unrelated failures', () {
      expect(
        isRateLimitOrQuota(errorMessage('prompt is too long: 5 > 3 maximum')),
        isFalse,
      );
      expect(isRateLimitOrQuota(errorMessage('400: invalid request')), isFalse);
      expect(isRateLimitOrQuota(errorMessage('502 bad gateway')), isFalse);
      final ok = AssistantMessage(
        content: const [],
        api: 'a',
        provider: 'p',
        model: 'm',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      expect(isRateLimitOrQuota(ok), isFalse);
    });

    test('a Retry-After hint alone does not classify', () {
      expect(
        isRateLimitOrQuota(
          errorMessage('500: internal error'),
          retryAfter: const Duration(seconds: 5),
        ),
        isFalse,
      );
    });
  });
}
