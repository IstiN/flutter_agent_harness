import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

/// The transient-network retry wrapper: a Wi-Fi switch kills the stream
/// with "Connection reset by peer" — the call sleeps 5s and replays.
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

  group('isTransientNetworkError', () {
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

    test('matches the socket-level wordings', () {
      expect(
        isTransientNetworkError(
          errorMsg('SocketException: Connection reset by peer'),
        ),
        isTrue,
      );
      expect(isTransientNetworkError(errorMsg('Connection refused')), isTrue);
      expect(
        isTransientNetworkError(errorMsg('Network is unreachable')),
        isTrue,
      );
      expect(isTransientNetworkError(errorMsg('Connection timed out')), isTrue);
      expect(isTransientNetworkError(errorMsg('Broken pipe')), isTrue);
    });

    test('rejects non-transient failures', () {
      expect(isTransientNetworkError(errorMsg('401 unauthorized')), isFalse);
      expect(isTransientNetworkError(errorMsg('429 rate limit')), isFalse);
      expect(
        isTransientNetworkError(errorMsg('context length exceeded')),
        isFalse,
      );
      // A bad certificate never heals in 5 seconds.
      expect(
        isTransientNetworkError(
          errorMsg('HandshakeException: certificate verify failed'),
        ),
        isFalse,
      );
      // The idle watchdog's wording is not a socket error.
      expect(
        isTransientNetworkError(
          errorMsg(
            'no events from the endpoint for 300s (stream idle timeout)',
          ),
        ),
        isFalse,
      );
    });

    test('a cut stream (no finish_reason) is transport (issue #312)', () {
      expect(
        isTransientNetworkError(
          errorMsg(
            'stream ended without finish_reason — the reply may be truncated',
          ),
        ),
        isTrue,
      );
    });
  });

  group('transientRetryStreamFunction', () {
    AssistantMessageEventStream failWith(String text) {
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        stream.push(
          ErrorEvent(
            reason: StopReason.error,
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

    /// A stream-terminal finish_reason failure (issue #312): the message
    /// carries the raw reason verbatim; the wire `rawStopReason` rides for
    /// the structured classification.
    AssistantMessageEventStream failFinish(String raw) {
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        stream.push(
          ErrorEvent(
            reason: StopReason.error,
            error: AssistantMessage(
              content: const [],
              api: 'test-api',
              provider: 'test-provider',
              model: 'test-model',
              usage: Usage.zero,
              stopReason: StopReason.error,
              rawStopReason: raw,
              errorMessage: 'Provider finish_reason: $raw',
              timestamp: DateTime.utc(2026),
            ),
          ),
        );
        stream.end();
      });
      return stream;
    }

    test('a reset-then-recover call retries and succeeds', () async {
      var calls = 0;
      final notices = <String>[];
      transientRetryNotice = (attempt, max, delay, reason) {
        notices.add('${attempt + 1}/$max in ${delay.inSeconds}s: $reason');
      };
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls < 3) {
          return failWith(
            'SocketException: Connection reset by peer, errno = 54',
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

      expect(calls, 3, reason: 'two transient failures, then the recover');
      expect(message.stopReason, StopReason.stop);
      expect(message.content.whereType<TextContent>().single.text, 'recovered');
      expect(notices, hasLength(2));
      expect(notices.first, contains('2/3 in 5s'));
      expect(notices.first, contains('Connection reset by peer'));
    });

    test('a non-transient error is forwarded without any retry', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return failWith('401 unauthorized');
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 1);
      expect(message.stopReason, StopReason.error);
      expect(message.errorMessage, '401 unauthorized');
    });

    test('an exhausted budget forwards the last failure', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return failWith('Connection reset by peer');
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 3, reason: 'the full budget burned');
      expect(message.stopReason, StopReason.error);
      expect(
        message.errorMessage,
        startsWith('Provider call failed after 3 attempt(s)'),
      );
      expect(message.errorMessage, contains('Connection reset by peer'));
    });

    test('a failure AFTER content is never replayed (observable-output '
        'guard)', () async {
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
              TextDeltaEvent(
                delta: 'partial',
                contentIndex: 0,
                partial: AssistantMessage(
                  content: const [TextContent(text: 'partial')],
                  api: 'test-api',
                  provider: 'test-provider',
                  model: 'test-model',
                  usage: Usage.zero,
                  stopReason: StopReason.stop,
                  timestamp: DateTime.utc(2026),
                ),
              ),
            )
            ..push(
              ErrorEvent(
                reason: StopReason.error,
                error: AssistantMessage(
                  content: const [],
                  api: 'test-api',
                  provider: 'test-provider',
                  model: 'test-model',
                  usage: Usage.zero,
                  stopReason: StopReason.error,
                  errorMessage: 'Connection reset by peer',
                  timestamp: DateTime.utc(2026),
                ),
              ),
            );
          stream.end();
        });
        return stream;
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
      ).toList();

      expect(calls, 1, reason: 'partial content committed the attempt');
      expect(events.whereType<TextDeltaEvent>(), hasLength(1));
      expect(events.whereType<ErrorEvent>(), hasLength(1));
    });

    test(
      'a cancel during the retry sleep aborts instead of replaying',
      () async {
        var calls = 0;
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
          return failWith('Connection reset by peer');
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
          cancelToken: source.token,
        ).result;

        expect(calls, 1, reason: 'the sleep was cancelled — no second call');
        expect(message.stopReason, StopReason.aborted);
        expect(message.errorMessage, contains('Connection reset by peer'));
      },
    );

    test('providerStreamFunction wraps every kind with the retry', () async {
      // The chokepoint contract: a transient failure on the FIRST call
      // replays — proven here through the factory itself (google kind with
      // a mock client that 500s once would need HTTP plumbing; the wrapper
      // composition is asserted structurally instead).
      final stream = providerStreamFunction('google', 'test-key');
      var calls = 0;
      final probe = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return failWith('Connection reset by peer');
      });
      await probe(testModel, const Context(messages: [])).result;
      expect(calls, 3);
      expect(stream, isNotNull);
    });

    test('a vendor finish_reason classified transient replays '
        '(issue #312)', () async {
      // Kimi k3 gateway: `unexpected_state` is its word for an internal
      // transient failure — the turn must replay, not die.
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) return failFinish('unexpected_state');
        return FakeStreamFunction([
          textTurn('recovered'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 2, reason: 'unexpected_state is transient — replayed');
      expect(message.stopReason, StopReason.stop);
      expect(message.content.whereType<TextContent>().single.text, 'recovered');
    });

    test('a TERMINAL finish_reason never replays (safety)', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return failFinish('content_filter');
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 1, reason: 'retrying a filter is a safety bug');
      expect(message.stopReason, StopReason.error);
      expect(message.errorMessage, 'Provider finish_reason: content_filter');
    });

    test('an UNKNOWN vendor finish_reason defaults transient', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        if (calls == 1) return failFinish('upstream_restarted');
        return FakeStreamFunction([
          textTurn('recovered'),
        ]).call(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(
        testModel,
        const Context(messages: []),
      ).result;

      expect(calls, 2, reason: 'unknown words degrade to retry, not death');
      expect(message.stopReason, StopReason.stop);
    });

    test('a classified failure AFTER content stands (no replay)', () async {
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
              TextDeltaEvent(
                delta: 'partial',
                contentIndex: 0,
                partial: AssistantMessage(
                  content: const [TextContent(text: 'partial')],
                  api: 'test-api',
                  provider: 'test-provider',
                  model: 'test-model',
                  usage: Usage.zero,
                  stopReason: StopReason.stop,
                  timestamp: DateTime.utc(2026),
                ),
              ),
            )
            ..push(
              ErrorEvent(
                reason: StopReason.error,
                error: AssistantMessage(
                  content: const [],
                  api: 'test-api',
                  provider: 'test-provider',
                  model: 'test-model',
                  usage: Usage.zero,
                  stopReason: StopReason.error,
                  rawStopReason: 'unexpected_state',
                  errorMessage: 'Provider finish_reason: unexpected_state',
                  timestamp: DateTime.utc(2026),
                ),
              ),
            );
          stream.end();
        });
        return stream;
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
      ).toList();

      expect(
        calls,
        1,
        reason:
            'the classification never bypasses the observable-output '
            'guard',
      );
      expect(events.whereType<TextDeltaEvent>(), hasLength(1));
      expect(events.whereType<ErrorEvent>(), hasLength(1));
    });
  });
  group('issue #290 — gateway 5xx coverage (the retry-free hole)', () {
    const incidentError =
        '500: Internal network failure, error id: '
        '20260913154946260720382f38417e, please try again later.';
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

    AssistantMessageEventStream failWith(String text) {
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        stream.push(
          ErrorEvent(reason: StopReason.error, error: errorMsg(text)),
        );
        stream.end();
      });
      return stream;
    }

    test('classifies the verbatim incident 500 and the 5xx family', () {
      expect(
        isTransientNetworkError(errorMsg(incidentError)),
        isTrue,
        reason: 'the incident wording must ride the wrapper',
      );
      expect(isTransientNetworkError(errorMsg('502: Bad Gateway')), isTrue);
      expect(
        isTransientNetworkError(errorMsg('503 Service Unavailable')),
        isTrue,
      );
      expect(
        isTransientNetworkError(errorMsg('504: Gateway time-out')),
        isTrue,
      );
      expect(
        isTransientNetworkError(errorMsg('500: internal server error')),
        isTrue,
      );
    });

    test(
      'still rejects rate limits, overflow, auth, watchdog wording (AC6)',
      () {
        expect(
          isTransientNetworkError(
            errorMsg('429: rate limit exceeded, please try again later'),
          ),
          isFalse,
          reason: '429 owns its rotation policy — never in-place retried here',
        );
        expect(
          isTransientNetworkError(
            errorMsg('Resource has been exhausted (quota)'),
          ),
          isFalse,
        );
        expect(
          isTransientNetworkError(errorMsg('context length exceeded')),
          isFalse,
        );
        expect(isTransientNetworkError(errorMsg('401 unauthorized')), isFalse);
        expect(
          isTransientNetworkError(
            errorMsg(
              'no events from the endpoint for 300s (stream idle timeout)',
            ),
          ),
          isFalse,
        );
      },
    );

    test(
      'verbatim incident 500 is retried and the turn completes (AC1)',
      () async {
        var calls = 0;
        final delays = <Duration>[];
        transientRetrySleeper = (delay, token) async {
          delays.add(delay);
          return true;
        };
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls == 1) return failWith(incidentError);
          return FakeStreamFunction([
            textTurn('recovered'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(
          calls,
          2,
          reason: 'the gateway 500 must be replayed, not surfaced',
        );
        expect(message.stopReason, StopReason.stop);
        expect(
          message.content.whereType<TextContent>().single.text,
          'recovered',
        );
        expect(delays, [const Duration(seconds: 5)]);
      },
    );

    test(
      'exhausted budget tells the retry story, not a raw dump (AC2)',
      () async {
        final wrapped = transientRetryStreamFunction(
          (model, context, {cancelToken}) => failWith(incidentError),
          maxAttempts: 2,
          delay: const Duration(milliseconds: 10),
        );

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(message.stopReason, StopReason.error);
        // Snapshot: attempts + elapsed + per-attempt reasons; the raw provider
        // line is only evidence inside the story, never the headline.
        expect(
          message.errorMessage,
          startsWith(
            'Provider call failed after 2 attempt(s) over <1s — the endpoint '
            'kept failing. Attempts: ${incidentError.substring(0, incidentError.length - 1)}; '
            '${incidentError.substring(0, incidentError.length - 1)}. Check '
            'the provider status or try again later.',
          ),
        );
      },
    );

    test(
      'post-commit 500 is a clean mid-answer error, never replayed (AC4)',
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
            final partial = AssistantMessage(
              content: const [TextContent(text: 'partial')],
              api: 'test-api',
              provider: 'test-provider',
              model: 'test-model',
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.utc(2026),
            );
            stream
              ..push(
                TextDeltaEvent(
                  delta: 'partial',
                  contentIndex: 0,
                  partial: partial,
                ),
              )
              ..push(
                ErrorEvent(
                  reason: StopReason.error,
                  error: AssistantMessage(
                    content: const [],
                    api: 'test-api',
                    provider: 'test-provider',
                    model: 'test-model',
                    usage: Usage.zero,
                    stopReason: StopReason.error,
                    errorMessage: incidentError,
                    timestamp: DateTime.utc(2026),
                  ),
                ),
              );
            stream.end();
          });
          return stream;
        });

        final events = await wrapped(
          testModel,
          const Context(messages: []),
        ).toList();

        expect(
          calls,
          1,
          reason: 'output committed — a replay would duplicate it',
        );
        expect(events.whereType<TextDeltaEvent>(), hasLength(1));
        final terminal = events.whereType<ErrorEvent>().single;
        expect(
          terminal.error.errorMessage,
          startsWith('Provider failed mid-answer'),
        );
        expect(
          terminal.error.errorMessage,
          contains('Internal network failure'),
        );
      },
    );
  });
}
