// gh-1602: the provider ladder's rate-limit class — a pre-commit 429 is
// retried with capped exponential backoff (honoring `Retry-After`,
// bounded by the session deadline's wrap-up margin) instead of failing
// the run. Run 7 of the harbor bench lost 5 of 30 trials to single
// transient quota blips because nothing above the provider ladder owned
// the 429 in a single-provider setup.
//
// Companion to gh1602_rate_limit_repro_test.dart (the pre-fix RED proof
// with the public pre-fix API only); this file exercises the fix's
// policy surface: classifier, budget, backoff, deadline bound, terminal
// evidence, and the classes that must stay fatal.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

AssistantMessageEventStream failWith(String text, {Duration? retryAfter}) {
  final stream = AssistantMessageEventStream();
  scheduleMicrotask(() {
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        retryAfter: retryAfter,
        error: AssistantMessage(
          content: const [],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.error,
          errorMessage: text,
          timestamp: DateTime.utc(2026),
        ),
      ),
    );
    stream.end();
  });
  return stream;
}

void main() {
  late Future<bool> Function(Duration, CancelToken?) savedSleeper;
  late TransientRetryNotice? savedNotice;
  late double Function() savedJitter;
  late Duration? Function()? savedDeadlineLeft;
  late Duration savedMargin;

  setUp(() {
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    savedJitter = transientRetryJitter;
    savedDeadlineLeft = transientRetryDeadlineLeft;
    savedMargin = transientRetryWrapUpMargin;
    transientRetrySleeper = (delay, token) async => true;
    transientRetryNotice = null;
    transientRetryJitter = () => 0;
    transientRetryDeadlineLeft = null;
    transientRetryWrapUpMargin = const Duration(seconds: 120);
  });
  tearDown(() {
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
    transientRetryJitter = savedJitter;
    transientRetryDeadlineLeft = savedDeadlineLeft;
    transientRetryWrapUpMargin = savedMargin;
  });

  group('rate-limit classifier', () {
    AssistantMessage errorMsg(String text) => AssistantMessage(
      content: const [],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.error,
      errorMessage: text,
      timestamp: DateTime.utc(2026),
    );

    test('matches the run-7 429 wording and its siblings', () {
      expect(
        isRateLimitError(errorMsg('429: Rate limit reached. Try again later.')),
        isTrue,
      );
      expect(isRateLimitError(errorMsg('429 too many requests')), isTrue);
      expect(
        isRateLimitError(errorMsg('Provider is throttling requests')),
        isTrue,
      );
    });

    test(
      'budget/spending exhaustion is terminal, never a retry (issue #926)',
      () {
        // `insufficient_quota` matches the rate-limit wording set but the
        // budget net must win — retrying a dead budget only burns requests.
        expect(
          isRateLimitError(
            errorMsg(
              'Error: 429 insufficient_quota: you have run out of quota',
            ),
          ),
          isFalse,
        );
        expect(
          isBudgetExhaustion(errorMsg('Error: 429 insufficient_quota')),
          isTrue,
        );
      },
    );

    test('non-error messages never classify', () {
      expect(
        isRateLimitError(
          AssistantMessage(
            content: const [],
            api: 'test-api',
            provider: 'p',
            model: 'm',
            usage: Usage.zero,
            stopReason: StopReason.stop,
            errorMessage: '429 rate limit',
            timestamp: DateTime.utc(2026),
          ),
        ),
        isFalse,
      );
    });
  });

  group('rateLimitBackoffFor', () {
    test(
      'exponential from the 2s floor, capped at 60s, jitter upward only',
      () {
        expect(rateLimitBackoffFor(1, 0.0).inMilliseconds, 2000);
        expect(rateLimitBackoffFor(2, 0.0).inMilliseconds, 4000);
        expect(rateLimitBackoffFor(3, 0.0).inMilliseconds, 8000);
        // Way past the cap: clamped at the cap.
        expect(
          rateLimitBackoffFor(12, 0.0).inMilliseconds,
          rateLimitBackoffCap.inMilliseconds,
        );
        // Full jitter adds up to 25%, never undercuts the base.
        expect(
          rateLimitBackoffFor(1, 1.0).inMilliseconds,
          greaterThanOrEqualTo(rateLimitBackoffBase.inMilliseconds),
        );
        expect(rateLimitBackoffFor(1, 1.0).inMilliseconds, 2500);
      },
    );
  });

  group('the ladder rate-limit policy', () {
    test('429 then 200: retried, the call completes', () async {
      var calls = 0;
      final waits = <Duration>[];
      transientRetrySleeper = (delay, token) async {
        waits.add(delay);
        return true;
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return failWith(
            '429: Rate limit reached. Try again later.',
            retryAfter: const Duration(seconds: 30),
          );
        }
        return FakeStreamFunction([
          textTurn('recovered'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 2);
      expect(message.stopReason, StopReason.stop);
      expect(message.content.whereType<TextContent>().single.text, 'recovered');
      // Retry-After is honored verbatim up to the rateLimitBackoffCap —
      // the backoff formula never overrides the provider's explicit
      // instruction inside the cap (AC2).
      expect(waits, [const Duration(seconds: 30)]);
    });

    test('a Retry-After larger than the 60s cap waits the cap — verbatim '
        'only up to rateLimitBackoffCap', () async {
      var calls = 0;
      final waits = <Duration>[];
      transientRetrySleeper = (delay, token) async {
        waits.add(delay);
        return true;
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return failWith(
            '429: Rate limit reached. Try again later.',
            retryAfter: const Duration(seconds: 90),
          );
        }
        return FakeStreamFunction([
          textTurn('recovered'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      // No unbounded sleeps: a 90s hint waits the 60s cap — the ladder's
      // whole budget stays inside a bench trial's wrap-up margin.
      expect(calls, 2);
      expect(message.stopReason, StopReason.stop);
      expect(waits, [rateLimitBackoffCap]);
    });

    test('no Retry-After: capped exponential backoff 2s, 4s, 8s', () async {
      var calls = 0;
      final waits = <Duration>[];
      transientRetrySleeper = (delay, token) async {
        waits.add(delay);
        return true;
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls <= 3) {
          return failWith('429: Rate limit reached. Try again later.');
        }
        return FakeStreamFunction([
          textTurn('ok'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 4);
      expect(message.stopReason, StopReason.stop);
      expect(waits, const [
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
    });

    test('persistent 429: the budget exhausts into a rate-limit-shaped '
        'terminal the roles layer still classifies', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return failWith('429: Rate limit reached. Try again later.');
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      // 1 initial attempt + maxRateLimitRetries replays, then the
      // terminal — the budget is its own, not the transport ladder's 3
      // total attempts.
      expect(calls, 1 + maxRateLimitRetries);
      expect(message.stopReason, StopReason.error);
      final text = message.errorMessage ?? '';
      // The terminal keeps the raw 429 evidence: when a roles chain IS
      // configured above, `isRateLimitOrQuota` must still match so key
      // rotation / failover keep working (the gh-1602 boundary note).
      expect(text, contains('429: Rate limit reached'));
      expect(isRateLimitOrQuota(message), isTrue);
    });

    test(
      'the deadline bound: no retry past the wrap-up margin (AC2)',
      () async {
        var calls = 0;
        transientRetryDeadlineLeft = () => const Duration(seconds: 90);
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          return failWith('429: Rate limit reached. Try again later.');
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        // 90s left − 120s wrap-up margin ≤ 0: the margin is reserved, the
        // ladder must not even start retrying.
        expect(calls, 1);
        expect(message.stopReason, StopReason.error);
        expect(message.errorMessage, contains('rate limit'));
        expect(message.errorMessage, contains('deadline'));
        // The terminal keeps the raw evidence for the classifiers above.
        expect(message.errorMessage, contains('429: Rate limit reached'));
      },
    );

    test(
      'the deadline bound: a retry that fits the allowance still runs',
      () async {
        var calls = 0;
        final waits = <Duration>[];
        transientRetrySleeper = (delay, token) async {
          waits.add(delay);
          return true;
        };
        transientRetryDeadlineLeft = () => const Duration(seconds: 200);
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls == 1) {
            return failWith(
              '429: Rate limit reached. Try again later.',
              retryAfter: const Duration(seconds: 60),
            );
          }
          return FakeStreamFunction([
            textTurn('recovered'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        // 200s − 120s margin = 80s allowance; the 60s Retry-After fits.
        expect(calls, 2);
        expect(message.stopReason, StopReason.stop);
        expect(waits, [const Duration(seconds: 60)]);
      },
    );

    test(
      'a Retry-After larger than the allowance stops the ladder (AC2)',
      () async {
        var calls = 0;
        final waits = <Duration>[];
        transientRetrySleeper = (delay, token) async {
          waits.add(delay);
          return true;
        };
        transientRetryDeadlineLeft = () => const Duration(seconds: 150);
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          return failWith(
            '429: Rate limit reached. Try again later.',
            retryAfter: const Duration(seconds: 90),
          );
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        // 150s − 120s = 30s allowance; sleeping 90s would cross the
        // wrap-up margin — the ladder stops instead of a doomed wait.
        expect(calls, 1);
        expect(waits, isEmpty);
        expect(message.stopReason, StopReason.error);
        expect(message.errorMessage, contains('deadline'));
      },
    );

    test(
      'no deadline armed: the attempt budget governs, no clock bound',
      () async {
        var calls = 0;
        transientRetryDeadlineLeft = null;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls <= 2) {
            return failWith('429: Rate limit reached. Try again later.');
          }
          return FakeStreamFunction([
            textTurn('recovered'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(calls, 3);
        expect(message.stopReason, StopReason.stop);
      },
    );

    test(
      'auth failure stays fatal — no rate-limit retry (AC: 401 fatal)',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          return failWith('401 unauthorized: invalid API key');
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(calls, 1);
        expect(message.stopReason, StopReason.error);
        expect(message.errorMessage, '401 unauthorized: invalid API key');
      },
    );

    test(
      'insufficient_quota stays terminal — never a backoff loop (#926)',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          return failWith(
            'Error: 429 insufficient_quota: you have run out of quota',
          );
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(calls, 1);
        expect(message.stopReason, StopReason.error);
        expect(message.errorMessage, contains('insufficient_quota'));
      },
    );

    test(
      'a mid-answer 429 still stands — no replay over streamed deltas',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          final stream = AssistantMessageEventStream();
          scheduleMicrotask(() {
            final empty = testAssistant();
            final part = testAssistant(
              content: [const TextContent(text: 'partial answer')],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(TextStartEvent(contentIndex: 0, partial: empty))
              ..push(
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'partial answer',
                  partial: part,
                ),
              )
              ..push(
                TextEndEvent(
                  contentIndex: 0,
                  content: 'partial answer',
                  partial: part,
                ),
              )
              ..push(
                ErrorEvent(
                  reason: StopReason.error,
                  error: testAssistant(
                    content: [const TextContent(text: 'partial answer')],
                    stopReason: StopReason.error,
                    errorMessage: '429: Rate limit reached. Try again later.',
                  ),
                ),
              )
              ..end();
          });
          return stream;
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        // A replay would duplicate the transcript — the #290 stand-rule
        // owns post-commit failures, rate limits included (gh-1602 keeps
        // it: only PRE-commit 429s are replayed; the error passes through
        // verbatim like every other non-retryable mid-answer class).
        expect(calls, 1);
        expect(message.stopReason, StopReason.error);
        expect(
          message.errorMessage,
          '429: Rate limit reached. Try again later.',
        );
      },
    );

    test('the notice speaks the FAILED attempt (1/4, 2/4, 3/4) — never the '
        'upcoming one, the face renders attempt + 1', () async {
      var calls = 0;
      final attempts = <int>[];
      final maxes = <int>[];
      transientRetryNotice = (attempt, maxAttempts, delay, reason) {
        attempts.add(attempt);
        maxes.add(maxAttempts);
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls <= 3) {
          return failWith('429: Rate limit reached. Try again later.');
        }
        return FakeStreamFunction([
          textTurn('ok'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      // The TransientRetryNotice contract: attempt = the 1-based attempt
      // that just failed; the faces render attempt + 1 (the retry about
      // to run) — the transport convention. Passing the UPCOMING number
      // double-increments the display ("attempt 3/4" on the first retry,
      // "attempt 5/4" on the third — beyond the declared budget) and
      // contradicts the 429_retry record.
      expect(message.stopReason, StopReason.stop);
      expect(attempts, [1, 2, 3]);
      expect(maxes, List.filled(3, 1 + maxRateLimitRetries));
    });

    test('mixed chain: rate-limit retries do not erode the transport '
        'budget — the classes do not eat each other\'s budget', () async {
      var calls = 0;
      var rateLimitFailures = 0;
      var transportFailures = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        final n = ++calls;
        if (n.isEven) {
          transportFailures++;
          return failWith('SocketException: Connection reset by peer');
        }
        rateLimitFailures++;
        return failWith('429: Rate limit reached. Try again later.');
      }, maxAttempts: 3);

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      // maxAttempts=3 transport + maxRateLimitRetries=3 rate-limit: the
      // alternating chain 429 → drop → 429 → drop → 429 → drop must give
      // the transport class its FULL 3 attempts — the shared attempt log
      // may not exhaust it after 2 (the exhaustion terminal lands on the
      // 6th call, the 3rd transport failure).
      expect(calls, maxRateLimitRetries + 3);
      expect(rateLimitFailures, maxRateLimitRetries);
      expect(transportFailures, 3);
      expect(message.stopReason, StopReason.error);
      expect(message.errorMessage, contains('Provider call failed after 6'));
    });

    test('the notice reason carries the UNTRUNCATED provider line — the '
        'face classifies the full text, truncation is display-only', () async {
      var calls = 0;
      final reasons = <String>[];
      transientRetryNotice = (attempt, maxAttempts, delay, reason) {
        reasons.add(reason);
      };
      // The rate-limit wording sits past the 120-char display cap (a
      // structured JSON-ish error render does this).
      final longLine =
          '${'structured error payload detail; ' * 10}'
          '429 rate limit exceeded, back off and retry';
      expect(longLine.length, greaterThan(120));
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return failWith(longLine);
        }
        return FakeStreamFunction([
          textTurn('ok'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      // The ladder retried under the rate-limit policy — the notice's
      // reason must let the CLI face see the SAME class, so the
      // `[net] rate limited` line and the 429_retry record are emitted.
      expect(message.stopReason, StopReason.stop);
      expect(reasons, hasLength(1));
      expect(reasons.single, longLine);
      expect(matchesRateLimitWording(reasons.single), isTrue);
    });

    test('a user cancel landing inside the backoff announces NOTHING — no '
        'retry follows, so no `[net] rate limited` face for it', () async {
      var calls = 0;
      final notices = <String>[];
      transientRetryNotice = (attempt, maxAttempts, delay, reason) {
        notices.add('$reason in ${delay.inSeconds}s');
      };
      final source = CancelTokenSource();
      transientRetrySleeper = (delay, token) async {
        source.cancel();
        return false;
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return failWith('429: Rate limit reached. Try again later.');
        }
        return FakeStreamFunction([
          textTurn('ok'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
        cancelToken: source.token,
      ).toList();

      // The cancel ends the ladder and the aborted terminal stands — a
      // cancelled backoff wait must never print a rate-limit retry face
      // (or append a 429_retry record): no retry follows it, and a
      // `delay_ms: 0` row would count an absorption that never happened
      // in bench post-mortems.
      expect(calls, 1);
      expect(notices, isEmpty);
      final aborts = events
          .whereType<ErrorEvent>()
          .where((event) => event.reason == StopReason.aborted)
          .toList();
      expect(aborts, hasLength(1));
    });
  });
}
