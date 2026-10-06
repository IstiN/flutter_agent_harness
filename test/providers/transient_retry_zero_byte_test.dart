// Issue #1121 / gh-1308: a zero-byte stall — an endpoint that accepts the
// request and streams NOTHING — survives the run-idle watchdog as a
// machine-cancel replay class. Split out of transient_retry_stream_test.dart
// (the gh-1232 god-file ceiling): the watchdog-replay family is a concern of
// its own and this file owns every watchdog-cancel scenario of the ladder.
//
// The transient ladder's zero-byte replay budget (gh-1308) is exercised on
// the agent level in test/agent/run_idle_watchdog_test.dart and on the
// roles level in test/model_roles/fallback_stream_test.dart.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  late Future<bool> Function(Duration, CancelToken?) savedSleeper;
  late TransientRetryNotice? savedNotice;

  setUp(() {
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    transientRetrySleeper = (delay, token) async => true;
    transientRetryNotice = null;
  });
  tearDown(() {
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
  });

  group('issue #1121 - a zero-byte stall survives the run-idle watchdog', () {
    /// The adapter translation of a watchdog-cancelled token: NOTHING was
    /// pushed (the connect never answered), then the abort event arrives.
    AssistantMessageEventStream zeroByteAbort(CancelTokenSource source) {
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        scheduleMicrotask(
          () => source.cancel(
            RunIdleWatchdogFire('agent run produced no events for 480s'),
          ),
        );
        source.token.onCancel.then((_) {
          stream
            ..push(
              ErrorEvent(
                reason: StopReason.aborted,
                error: testAssistant(
                  stopReason: StopReason.aborted,
                  errorMessage: 'Request was aborted',
                ),
              ),
            )
            ..end();
        });
      });
      return stream;
    }

    test('the bench repro: a watchdog-killed zero-byte request retries and '
        'completes — the run does not die aborted', () async {
      var calls = 0;
      final notices = <String>[];
      transientRetryNotice = (attempt, max, delay, reason) =>
          notices.add('${attempt + 1}/$max in ${delay.inSeconds}s: $reason');
      final source = CancelTokenSource();
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) return zeroByteAbort(source);
        return FakeStreamFunction([
          textTurn('recovered'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
        cancelToken: source.token,
      ).toList();

      expect(calls, 2, reason: 'the zero-byte attempt is replayed');
      // The replay is ANNOUNCED on the [net] surface, and names the
      // machine trigger — "Request was aborted" alone has meant USER
      // intent on that surface (review r1, thread 1).
      expect(notices.single, contains('run-idle watchdog replay'));
      expect(notices.single, contains('Request was aborted'));
      final done = events.whereType<DoneEvent>().single;
      expect(
        done.message.content.whereType<TextContent>().single.text,
        'recovered',
      );
      expect(events.whereType<ErrorEvent>(), isEmpty);
      // The replay re-arms the SAME latch in place — the loop's tool
      // phases and a later user abort observe a live token (issue #1132
      // discipline).
      expect(source.token.isCancelled, isFalse);
    });

    test('a watchdog-killed zero-byte request on EVERY attempt dies loud and '
        'bounded — error budget story, latch re-armed', () async {
      var calls = 0;
      final source = CancelTokenSource();
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return zeroByteAbort(source);
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
        cancelToken: source.token,
      ).toList();

      // gh-1308: the zero-byte budget is 2 consecutive watchdog-killed
      // silent attempts. The ladder never spends its third attempt (and
      // the caller's whole cap with it) replaying into an endpoint that
      // produced nothing across the first two.
      expect(calls, 2, reason: 'the zero-byte replay budget is bounded');
      final terminal = events.whereType<ErrorEvent>().single;
      expect(terminal.reason, StopReason.error);
      expect(terminal.error.errorMessage, contains('after 2 attempt(s)'));
      // The zero-byte classification rides the terminal (NG1): upper
      // layers and post-mortems can tell a provider hang from other
      // failures without opening logs.
      expect(terminal.error.errorMessage, contains(zeroByteStallTag));
      // The per-attempt story names the machine trigger, not just the
      // raw abort (review r1, thread 1).
      expect(
        terminal.error.errorMessage,
        contains(
          'run-idle watchdog replay of zero-byte request: '
          'Request was aborted',
        ),
      );
      // The terminal is classified RETRYABLE/transport so the roles
      // ladder fails over to the next configured model (gh-1308 AC2)
      // instead of standing.
      expect(isTransientNetworkError(terminal.error), isTrue);
      // The latch is re-armed: the run ends as a provider ERROR the
      // roles ladder can act on — never a fake `aborted` (the #1122
      // misclassification in the bench repro).
      expect(source.token.isCancelled, isFalse);
    });

    test('the zero-byte stall terminal is transport-classified for the '
        'roles ladder and a queue timeout death', () {
      final terminal = testAssistant(
        stopReason: StopReason.error,
        errorMessage:
            'Provider zero-byte stall after 2 attempt(s) over 9s — the '
            'endpoint accepted the request but streamed nothing '
            '(zero-byte stall). Check the provider status or try again '
            'later.',
      );
      expect(isTransientNetworkError(terminal), isTrue);
    });

    test('a socket-class failure chain keeps the full 3-attempt budget — '
        'the zero-byte bound governs only watchdog-killed silent attempts',
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
          stream
            ..push(
              ErrorEvent(
                reason: StopReason.error,
                error: testAssistant(
                  stopReason: StopReason.error,
                  errorMessage: 'Connection reset by peer',
                ),
              ),
            )
            ..end();
        });
        return stream;
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
      ).toList();

      expect(calls, 3, reason: 'socket-class replays keep the full budget');
      final terminal = events.whereType<ErrorEvent>().single;
      expect(terminal.error.errorMessage, contains('failed after 3'));
    });

    test('a USER abort before any byte still stands — no replay', () async {
      var calls = 0;
      final source = CancelTokenSource();
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        final stream = AssistantMessageEventStream();
        scheduleMicrotask(() {
          scheduleMicrotask(source.cancel); // bare cancel: user intent
          source.token.onCancel.then((_) {
            stream
              ..push(
                ErrorEvent(
                  reason: StopReason.aborted,
                  error: testAssistant(
                    stopReason: StopReason.aborted,
                    errorMessage: 'Request was aborted',
                  ),
                ),
              )
              ..end();
          });
        });
        return stream;
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
        cancelToken: source.token,
      ).toList();

      expect(calls, 1, reason: 'a user abort is never resumed');
      final terminal = events.whereType<ErrorEvent>().single;
      expect(terminal.reason, StopReason.aborted);
      expect(source.token.isCancelled, isTrue);
    });

    test('a provider-emitted abort with zero bytes and a healthy token '
        'replays (issue #1121 comment E5)', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          final stream = AssistantMessageEventStream();
          scheduleMicrotask(() {
            stream
              ..push(
                ErrorEvent(
                  reason: StopReason.aborted,
                  error: testAssistant(
                    stopReason: StopReason.aborted,
                    errorMessage: 'Request was aborted',
                  ),
                ),
              )
              ..end();
          });
          return stream;
        }
        return FakeStreamFunction([
          textTurn('second try'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
      ).toList();

      expect(calls, 2, reason: 'no one intended this abort — it replays');
      final done = events.whereType<DoneEvent>().single;
      expect(
        done.message.content.whereType<TextContent>().single.text,
        'second try',
      );
    });

    test('a watchdog fire landing INSIDE the retry sleep is absorbed — '
        'the replay proceeds, the latch re-arms', () async {
      var calls = 0;
      final source = CancelTokenSource();
      // Mirror the real sleeper's contract: it races the token, so a
      // watchdog fire landing mid-sleep wins and reports NOT survived.
      transientRetrySleeper = (delay, token) async {
        source.cancel(
          RunIdleWatchdogFire('agent run produced no events for 480s'),
        );
        return false;
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          final stream = AssistantMessageEventStream();
          scheduleMicrotask(() {
            stream
              ..push(
                ErrorEvent(
                  reason: StopReason.error,
                  error: testAssistant(
                    stopReason: StopReason.error,
                    errorMessage: 'SocketException: Connection reset by peer',
                  ),
                ),
              )
              ..end();
          });
          return stream;
        }
        return FakeStreamFunction([
          textTurn('recovered'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
        cancelToken: source.token,
      ).toList();

      // The machine cancel mid-sleep is absorbed — same discipline as the
      // branch above: reset in place, retry on the SAME token.
      expect(calls, 2, reason: 'the machine cancel mid-sleep is absorbed');
      expect(events.whereType<DoneEvent>(), isNotEmpty);
      expect(source.token.isCancelled, isFalse);
    });

    test('the connect watchdog wording enters the ladder (retryable)', () {
      expect(
        isTransientNetworkError(
          testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'TimeoutException: provider stream request to '
                'https://api.example.com/v1/chat/completions timed out: no '
                'response headers within 180s (connect watchdog)',
          ),
        ),
        isTrue,
        reason: 'the #1125 connect ladder exhaustion must flow into this '
            'retry budget, not die as a raw error',
      );
    });
  });
}
}
