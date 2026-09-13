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
  String? raw,
}) {
  return AssistantMessage(
    content: text.isEmpty ? const [] : [TextContent(text: text)],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stop,
    errorMessage: error,
    rawStopReason: raw,
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
      double jitter = 1.0,
    }) {
      return FallbackStreamFunction(
        entries: entries,
        policy: policy,
        onNotice: notices.add,
        now: () => now,
        jitterFraction: () => jitter,
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
        expect(
          events.last,
          startsWith('error(error):${a.id}:Provider failed mid-answer'),
        );
        expect(
          events.last,
          contains('Provider error: 429: rate limit exceeded'),
        );
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
      expect(
        events.single,
        startsWith('error(error):${b.id}:Provider chain exhausted'),
      );
      expect(events.single, contains('2 of 2 chain model(s) failed'));
      expect(events.single, contains('anthropic/claude-b: 429: b down too'));
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
      expect(
        events.single,
        startsWith('error(error):${a.id}:Provider chain exhausted'),
      );
      expect(events.single, contains('1 of 1 chain model(s) failed'));
      expect(events.single, contains('after 3 attempt(s)'));
      expect(events.single, contains('openai/gpt-a: 429: rate limit exceeded'));
      expect(notices.map((n) => n.kind), [
        FallbackNoticeKind.retry,
        FallbackNoticeKind.retry,
      ]);
    });

    group('transport errors', () {
      List<AssistantMessageEvent> transportTurn(
        Model model, {
        String error =
            'ClientException: Connection closed while receiving data',
      }) {
        final partial = _msg(model);
        return [
          StartEvent(partial: partial),
          ErrorEvent(
            reason: StopReason.error,
            error: _msg(model, stop: StopReason.error, error: error),
          ),
        ];
      }

      test('retries the same entry on a dropped connection', () async {
        final a = _model('openai', 'gpt-a');
        final probe = _Probe({
          'v-a': [transportTurn(a), _okTurn(a, 'second try')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
        ]);

        final events = await run(w);

        // The failed pre-content attempt left no trace; the retry streamed.
        expect(events, [
          'start:${a.id}',
          'textStart',
          'delta:second try',
          'done:${a.id}',
        ]);
        expect(probe.calls, ['v-a', 'v-a']);
        expect(sleeps, [const Duration(milliseconds: 500)]);
        expect(notices.single.kind, FallbackNoticeKind.transportRetry);
        expect(
          notices.single.describe(),
          contains('connection lost on openai/gpt-a'),
        );
      });

      test('never rotates API keys for a transport failure', () async {
        final a = _model('openai', 'gpt-a');
        final probe = _Probe({
          'v-a': [transportTurn(a), _okTurn(a, 'recovered')],
          'v-a-2': [_okTurn(a, 'wrong key')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a', 'v-a-2']),
        ]);

        await run(w);

        // Same credential retried: the sibling key is never touched.
        expect(probe.calls, ['v-a', 'v-a']);
        expect(
          notices.map((n) => n.kind),
          everyElement(FallbackNoticeKind.transportRetry),
        );
      });

      test('fails over to the next entry when retries are spent', () async {
        final a = _model('openai', 'gpt-a');
        final b = _model('anthropic', 'claude-b');
        final probe = _Probe({
          'v-a': [transportTurn(a)],
          'v-b': [_okTurn(b, 'hello from b')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
          entry(probe, b, ['v-b']),
        ], policy: const ModelRolesRetryPolicy(retriesPerEntry: 0));

        final events = await run(w);

        expect(events.last, 'done:${b.id}');
        expect(probe.calls, ['v-a', 'v-b']);
        expect(notices.single.kind, FallbackNoticeKind.modelFallback);
      });

      test(
        'forwards the last transport error when the chain exhausts',
        () async {
          final a = _model('openai', 'gpt-a');
          final probe = _Probe({
            'v-a': [
              transportTurn(a),
              transportTurn(a, error: 'SocketException: Connection refused'),
              transportTurn(a, error: 'Failed host lookup: api.example.test'),
            ],
          });
          final w = wrapper([
            entry(probe, a, ['v-a']),
          ]);

          final events = await run(w);

          expect(probe.calls, hasLength(3)); // 1 + retriesPerEntry(2)
          expect(
            events.single,
            startsWith('error(error):${a.id}:Provider chain exhausted'),
          );
        },
      );

      test(
        'a mid-stream transport drop is forwarded, never replayed',
        () async {
          final a = _model('openai', 'gpt-a');
          final partial = _msg(a);
          final probe = _Probe({
            'v-a': [
              [
                StartEvent(partial: partial),
                TextStartEvent(contentIndex: 0, partial: partial),
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'half',
                  partial: _msg(a, text: 'half'),
                ),
                ErrorEvent(
                  reason: StopReason.error,
                  error: _msg(
                    a,
                    stop: StopReason.error,
                    error: 'Connection closed while receiving data',
                  ),
                ),
              ],
              _okTurn(a, 'must not be used'),
            ],
          });
          final w = wrapper([
            entry(probe, a, ['v-a']),
          ]);

          final events = await run(w);

          // Observable output already left: the failure stands (the CLI
          // appends deltas — a silent replay would duplicate the transcript).
          expect(events, [
            'start:${a.id}',
            'textStart',
            'delta:half',
            'error(error):${a.id}:Provider failed mid-answer: the stream '
                'died after output was already delivered (not retried — a '
                'replay would duplicate the transcript). Provider error: '
                'Connection closed while receiving data',
          ]);
          expect(probe.calls, ['v-a']);
          expect(notices, isEmpty);
        },
      );
    });
    group('issue #290 — verbatim 500 coverage + exhaustion story', () {
      List<AssistantMessageEvent> gateway500Turn(
        Model model, {
        String error =
            '500: Internal network failure, error id: '
            '20260913154946260720382f38417e, please try again later.',
      }) {
        final partial = _msg(model);
        return [
          StartEvent(partial: partial),
          ErrorEvent(
            reason: StopReason.error,
            error: _msg(model, stop: StopReason.error, error: error),
          ),
        ];
      }

      test(
        'verbatim gateway 500 is retried in place (main-loop stream, AC1)',
        () async {
          final a = _model('kimi', 'kimi-k2');
          final probe = _Probe({
            'v-a': [gateway500Turn(a), _okTurn(a, 'recovered')],
          });
          final w = wrapper([
            entry(probe, a, ['v-a']),
          ]);

          final events = await run(w);

          expect(events, [
            'start:${a.id}',
            'textStart',
            'delta:recovered',
            'done:${a.id}',
          ]);
          expect(probe.calls, ['v-a', 'v-a']);
          expect(sleeps, [const Duration(milliseconds: 500)]);
          expect(notices.single.kind, FallbackNoticeKind.transportRetry);
        },
      );

      test(
        'exhausted chain tells the retry story, not a raw dump (AC2/E1)',
        () async {
          final a = _model('kimi', 'kimi-k2');
          final b = _model('openai', 'gpt-b');
          const incident =
              '500: Internal network failure, error id: X, please try again later.';
          final probe = _Probe({
            'v-a': [
              gateway500Turn(a, error: incident),
              gateway500Turn(a, error: incident),
            ],
            'v-b': [
              gateway500Turn(b, error: incident),
              gateway500Turn(b, error: incident),
            ],
          });
          final w = wrapper(
            [
              entry(probe, a, ['v-a']),
              entry(probe, b, ['v-b']),
            ],
            policy: const ModelRolesRetryPolicy(
              retriesPerEntry: 1,
              baseDelay: Duration(milliseconds: 10),
            ),
          );

          final events = await run(w);

          final terminal = events.single;
          expect(
            terminal,
            startsWith('error(error):${b.id}:Provider chain exhausted'),
          );
          // E1: the story says the WHOLE chain failed (an outage), never
          // "key rotated, try again".
          expect(terminal, contains('2 of 2 chain model(s) failed'));
          expect(terminal, contains('after 4 attempt(s)'));
          expect(terminal, contains('over <1s'));
          expect(
            terminal,
            contains('kimi/kimi-k2: 500: Internal network failure'),
          );
          expect(
            terminal,
            contains('openai/gpt-b: 500: Internal network failure'),
          );
          expect(terminal, contains('not a key problem'));
        },
      );

      test('cooldown-wall exhaustion (no attempts this call) still tells a '
          'story', () async {
        final a = _model('kimi', 'kimi-k2');
        final b = _model('openai', 'gpt-b');
        const backoff = Duration(minutes: 10);
        final probe = _Probe({
          'v-a': [_rateLimitTurn(a, retryAfter: backoff)],
          'v-a2': [_rateLimitTurn(a, retryAfter: backoff)],
          'v-b': [_rateLimitTurn(b, retryAfter: backoff)],
          'v-b2': [_rateLimitTurn(b, retryAfter: backoff)],
        });
        final w = wrapper([
          entry(probe, a, ['v-a', 'v-a2']),
          entry(probe, b, ['v-b', 'v-b2']),
        ], policy: const ModelRolesRetryPolicy(retriesPerEntry: 1));

        // Call 1 benches every key (10m retryAfter) and cools both
        // entries down; call 2 starts with the whole chain benched.
        await run(w);
        final events = await run(w);

        expect(events.single, startsWith('error(error):${a.id}:Provider'));
        expect(
          events.single,
          contains('every chain model is rate limited and cooling down'),
        );
        expect(
          events.single,
          contains('retried automatically once its cooldown lapses'),
        );
      });

      test(
        'post-commit gateway 500 stands as a mid-answer error (AC4)',
        () async {
          final a = _model('kimi', 'kimi-k2');
          final partial = _msg(a);
          const incident =
              '500: Internal network failure, error id: X, please try again later.';
          final probe = _Probe({
            'v-a': [
              [
                StartEvent(partial: partial),
                TextStartEvent(contentIndex: 0, partial: partial),
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'half',
                  partial: _msg(a, text: 'half'),
                ),
                ErrorEvent(
                  reason: StopReason.error,
                  error: _msg(a, stop: StopReason.error, error: incident),
                ),
              ],
              _okTurn(a, 'must not be used'),
            ],
          });
          final w = wrapper([
            entry(probe, a, ['v-a']),
          ]);

          final events = await run(w);

          expect(events, [
            'start:${a.id}',
            'textStart',
            'delta:half',
            'error(error):${a.id}:Provider failed mid-answer: the stream died '
                'after output was already delivered (not retried — a replay '
                'would duplicate the transcript). Provider error: $incident',
          ]);
          expect(probe.calls, [
            'v-a',
          ], reason: 'no retry after observable output');
        },
      );

      test(
        'transport backoff follows the retry: knobs, jitter pins (AC5/E3)',
        () async {
          final a = _model('openai', 'gpt-a');
          final probe = _Probe({
            'v-a': [
              gateway500Turn(a),
              gateway500Turn(a),
              gateway500Turn(a),
              _okTurn(a, 'fourth try'),
            ],
          });
          final w = wrapper(
            [
              entry(probe, a, ['v-a']),
            ],
            policy: const ModelRolesRetryPolicy(
              retriesPerEntry: 3,
              baseDelay: Duration(milliseconds: 100),
              maxBackoff: Duration(milliseconds: 250),
            ),
          );

          final events = await run(w);

          expect(events.last, 'done:${a.id}');
          // Knob-driven ladder: 100→200→capped at maxBackoff 250.
          expect(sleeps, [
            const Duration(milliseconds: 100),
            const Duration(milliseconds: 200),
            const Duration(milliseconds: 250),
          ]);

          // E3: jitter (fraction 0.5 → ×0.875) de-phases retries — no herd.
          final probe2 = _Probe({
            'v-a': [gateway500Turn(a), _okTurn(a, 'second try')],
          });
          final w2 = wrapper(
            [
              entry(probe2, a, ['v-a']),
            ],
            policy: const ModelRolesRetryPolicy(
              baseDelay: Duration(milliseconds: 100),
            ),
            jitter: 0.5,
          );

          final events2 = await run(w2);

          expect(events2.last, 'done:${a.id}');
          expect(sleeps.last, const Duration(milliseconds: 88));
        },
      );
    });

    group('finish_reason classification (issue #312)', () {
      List<AssistantMessageEvent> finishTurn(
        Model model, {
        required String raw,
      }) {
        final partial = _msg(model);
        return [
          StartEvent(partial: partial),
          ErrorEvent(
            reason: StopReason.error,
            error: _msg(
              model,
              stop: StopReason.error,
              error: 'Provider finish_reason: $raw',
              raw: raw,
            ),
          ),
        ];
      }

      test(
        'an unknown vendor finish_reason retries the entry in place',
        () async {
          final a = _model('openai', 'gpt-a');
          final probe = _Probe({
            'v-a': [
              finishTurn(a, raw: 'unexpected_state'),
              _okTurn(a, 'second try'),
            ],
          });
          final w = wrapper([
            entry(probe, a, ['v-a']),
          ]);

          final events = await run(w);

          expect(events, [
            'start:${a.id}',
            'textStart',
            'delta:second try',
            'done:${a.id}',
          ]);
          expect(probe.calls, ['v-a', 'v-a']);
          expect(notices.single.kind, FallbackNoticeKind.transportRetry);
        },
      );

      test('a TERMINAL finish_reason is forwarded without any retry', () async {
        final a = _model('openai', 'gpt-a');
        final probe = _Probe({
          'v-a': [finishTurn(a, raw: 'content_filter')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
        ]);

        final events = await run(w);

        expect(probe.calls, ['v-a'], reason: 'retrying a filter is unsafe');
        expect(events, [
          'start:${a.id}',
          'error(error):${a.id}:Provider finish_reason: content_filter',
        ]);
        expect(notices, isEmpty);
      });

      test('a provider failing every call fails over to the next entry '
          '(E2)', () async {
        final a = _model('openai', 'gpt-a');
        final b = _model('anthropic', 'claude-b');
        final probe = _Probe({
          'v-a': [finishTurn(a, raw: 'unexpected_state')],
          'v-b': [_okTurn(b, 'hello from b')],
        });
        final w = wrapper([
          entry(probe, a, ['v-a']),
          entry(probe, b, ['v-b']),
        ], policy: const ModelRolesRetryPolicy(retriesPerEntry: 0));

        final events = await run(w);

        expect(events.last, 'done:${b.id}');
        expect(probe.calls, ['v-a', 'v-b']);
        expect(notices.single.kind, FallbackNoticeKind.modelFallback);
      });
    });
  });

  group('isTransientTransportError', () {
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

    test('classifies dropped connections, DNS, TLS, and 5xx gateways', () {
      for (final text in [
        'ClientException: Connection closed while receiving data',
        'Connection reset by peer',
        'SocketException: Connection refused',
        'Connection aborted',
        'Connection terminated during handshake',
        'Connection timed out',
        'Failed host lookup: api.openai.com',
        'Network is unreachable',
        'No route to host',
        'Broken pipe',
        '502 Bad Gateway',
        '503 Service Unavailable',
        '504 Gateway Timeout',
        '500: Internal network failure, error id: 2026090604313429886c81faba4889, please try again later.',
        '500: internal server error',
        'TimeoutException after 0:03:00.000000: Future not completed',
        'Request timed out',
      ]) {
        expect(
          isTransientTransportError(errorMessage(text)),
          isTrue,
          reason: text,
        );
      }
    });

    test('rejects rate limits, overflow, non-errors, and clean failures', () {
      for (final text in [
        '429: rate limit exceeded',
        'insufficient_quota: You exceeded your current quota',
        'prompt is too long: 5 > 3 maximum',
        '400: invalid request',
        '400: bad request',
      ]) {
        expect(
          isTransientTransportError(errorMessage(text)),
          isFalse,
          reason: text,
        );
      }
      final ok = AssistantMessage(
        content: const [],
        api: 'a',
        provider: 'p',
        model: 'm',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      expect(isTransientTransportError(ok), isFalse);
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
