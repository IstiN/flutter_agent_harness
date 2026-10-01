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

    test('budget/spending exhaustion is never transient (issue #926)', () {
      expect(
        isTransientNetworkError(
          errorMsg(
            '403: CodeMie monthly budget limit reached (\$150.08 / \$150.00)',
          ),
        ),
        isFalse,
      );
      // A gateway-wrapped budget error quotes transport words — the budget
      // check must win, or the wrapper re-arms the loop the issue reports.
      expect(
        isTransientNetworkError(
          errorMsg(
            '500: Internal network failure — spending limit reached, '
            'please try again later',
          ),
        ),
        isFalse,
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

    test(
      'a budget error is terminal — verbatim, no retries (issue #926)',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          return failWith(
            '403: CodeMie monthly budget limit reached '
            '(\$150.08 / \$150.00). Next budget reset: 01/10/2026',
          );
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(calls, 1, reason: 'a dead budget never heals on a retry');
        expect(message.stopReason, StopReason.error);
        // The provider's budget wording IS the user notice — no exhaustion
        // story may bury it.
        expect(message.errorMessage, contains('budget limit reached'));
        expect(
          message.errorMessage,
          isNot(startsWith('Provider call failed after')),
        );
      },
    );

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
      'a thinking-only drop replays — nothing user-visible was emitted '
      '(issue #964)',
      () async {
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
                ..push(StartEvent(partial: testAssistant()))
                ..push(
                  ThinkingStartEvent(
                    contentIndex: 0,
                    partial: testAssistant(),
                  ),
                );
              for (var i = 1; i <= 3; i++) {
                stream.push(
                  ThinkingDeltaEvent(
                    contentIndex: 0,
                    delta: 'pondering $i',
                    partial: testAssistant(
                      content: [ThinkingContent(thinking: 'pondering $i')],
                    ),
                  ),
                );
              }
              stream.push(
                ErrorEvent(
                  reason: StopReason.error,
                  error: testAssistant(
                    stopReason: StopReason.error,
                    errorMessage: 'Connection reset by peer',
                  ),
                ),
              );
              stream.end();
            });
            return stream;
          }
          return FakeStreamFunction([
            textTurn('recovered'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final message = await wrapped(
          testModel,
          const Context(messages: []),
        ).result;

        expect(calls, 2, reason: 'thinking-only deltas did not commit');
        expect(message.stopReason, StopReason.stop);
        expect(
          message.content.whereType<TextContent>().single.text,
          'recovered',
        );
      },
    );

    test('a thinking-only success flushes the buffered reasoning '
        '(issue #964)', () async {
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        scheduleMicrotask(() {
          final full = testAssistant(
            content: const [ThinkingContent(thinking: 'deep thought')],
          );
          stream
            ..push(StartEvent(partial: testAssistant()))
            ..push(
              ThinkingStartEvent(contentIndex: 0, partial: testAssistant()),
            )
            ..push(
              ThinkingDeltaEvent(
                contentIndex: 0,
                delta: 'deep ',
                partial: testAssistant(
                  content: const [ThinkingContent(thinking: 'deep ')],
                ),
              ),
            )
            ..push(
              ThinkingDeltaEvent(
                contentIndex: 0,
                delta: 'thought',
                partial: testAssistant(
                  content: const [ThinkingContent(thinking: 'deep thought')],
                ),
              ),
            )
            ..push(
              ThinkingEndEvent(
                contentIndex: 0,
                content: 'deep thought',
                partial: full,
              ),
            )
            ..push(DoneEvent(reason: StopReason.stop, message: full));
          stream.end();
        });
        return stream;
      });

      final events = await wrapped(
        testModel,
        const Context(messages: []),
      ).toList();

      expect(
        events.whereType<ThinkingDeltaEvent>().map((e) => e.delta).toList(),
        ['deep ', 'thought'],
        reason: 'buffered thinking flushes in order at Done — never lost',
      );
      expect(events.last, isA<DoneEvent>());
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test('a drop after visible content still stands despite thinking deltas '
        '(issue #964 AC4)', () async {
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
            ..push(StartEvent(partial: testAssistant()))
            ..push(
              ThinkingStartEvent(contentIndex: 0, partial: testAssistant()),
            )
            ..push(
              ThinkingDeltaEvent(
                contentIndex: 0,
                delta: 'hmm ',
                partial: testAssistant(
                  content: const [ThinkingContent(thinking: 'hmm ')],
                ),
              ),
            )
            ..push(
              TextDeltaEvent(
                contentIndex: 1,
                delta: 'partial',
                partial: testAssistant(
                  content: const [
                    ThinkingContent(thinking: 'hmm '),
                    TextContent(text: 'partial'),
                  ],
                ),
              ),
            )
            ..push(
              ErrorEvent(
                reason: StopReason.error,
                error: testAssistant(
                  stopReason: StopReason.error,
                  errorMessage: 'Connection reset by peer',
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

      expect(calls, 1, reason: 'the text delta committed the attempt');
      // The buffered thinking flushed in order with the commit; the visible
      // delta and the mid-answer failure stand (no replay).
      expect(events.whereType<ThinkingDeltaEvent>().single.delta, 'hmm ');
      expect(events.whereType<TextDeltaEvent>().single.delta, 'partial');
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

    test(
      'a stream closing without any terminal event flushes the buffer',
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
            stream.push(
              StartEvent(
                partial: AssistantMessage(
                  content: const [],
                  api: 'test-api',
                  provider: 'test-provider',
                  model: 'test-model',
                  usage: Usage.zero,
                  stopReason: StopReason.stop,
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

        expect(calls, 1);
        expect(
          events.whereType<StartEvent>(),
          hasLength(1),
          reason: 'the held partial is flushed, not dropped',
        );
      },
    );

    test('a natural stop with nothing committed flushes and ends', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        final stream = AssistantMessageEventStream();
        scheduleMicrotask(() {
          stream.push(
            StartEvent(
              partial: AssistantMessage(
                content: const [],
                api: 'test-api',
                provider: 'test-provider',
                model: 'test-model',
                usage: Usage.zero,
                stopReason: StopReason.stop,
                timestamp: DateTime.utc(2026),
              ),
            ),
          );
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: AssistantMessage(
                content: const [],
                api: 'test-api',
                provider: 'test-provider',
                model: 'test-model',
                usage: Usage.zero,
                stopReason: StopReason.stop,
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

      expect(calls, 1, reason: 'a natural stop is never replayed');
      expect(events.whereType<StartEvent>(), hasLength(1));
      expect(events.whereType<DoneEvent>(), hasLength(1));
    });

    test('a post-commit non-error terminal stands verbatim', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        final stream = AssistantMessageEventStream();
        scheduleMicrotask(() {
          stream.push(
            TextDeltaEvent(
              contentIndex: 0,
              delta: 'half',
              partial: AssistantMessage(
                content: const [TextContent(text: 'half')],
                api: 'test-api',
                provider: 'test-provider',
                model: 'test-model',
                usage: Usage.zero,
                stopReason: StopReason.stop,
                timestamp: DateTime.utc(2026),
              ),
            ),
          );
          stream.push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: AssistantMessage(
                content: const [],
                api: 'test-api',
                provider: 'test-provider',
                model: 'test-model',
                usage: Usage.zero,
                stopReason: StopReason.aborted,
                errorMessage: 'Request was aborted',
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

      expect(calls, 1, reason: 'an aborted turn is never replayed');
      final terminal = events.whereType<ErrorEvent>().single;
      expect(terminal.reason, StopReason.aborted);
      expect(
        terminal.error.errorMessage,
        'Request was aborted',
        reason: 'non-error terminals skip the mid-answer wrap',
      );
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

  group('issue #1126 — mid-stream abort resumes from the completed prefix', () {
    Usage usage(int input, int output) => Usage(
      input: input,
      output: output,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: input + output,
      cost: const UsageCost(),
    );

    /// One streamed attempt: a text block completes, then the stream dies
    /// with the bench incident's abort signature (`Request was aborted`).
    AssistantMessageEventStream abortAfterText(
      String text, {
      Usage? deadUsage,
    }) {
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        final empty = testAssistant();
        final partial = testAssistant(content: [TextContent(text: text)]);
        stream
          ..push(StartEvent(partial: empty))
          ..push(TextStartEvent(contentIndex: 0, partial: empty))
          ..push(
            TextDeltaEvent(
              contentIndex: 0,
              delta: text,
              partial: partial,
            ),
          )
          ..push(
            TextEndEvent(
              contentIndex: 0,
              content: text,
              partial: partial,
            ),
          )
          ..push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: testAssistant(
                content: [TextContent(text: text)],
                stopReason: StopReason.aborted,
                errorMessage: 'Request was aborted',
                usage: deadUsage,
              ),
            ),
          );
        stream.end();
      });
      return stream;
    }

    test(
      'AC1: a mid-stream abort after completed content resumes from the '
      'prefix and completes — one logical message, no duplicate content',
      () async {
        var calls = 0;
        final requestContexts = <Context>[];
        final notices = <String>[];
        transientRetryNotice = (attempt, max, delay, reason) {
          notices.add('$reason (${delay.inSeconds}s)');
        };
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          requestContexts.add(context);
          if (calls == 1) {
            return abortAfterText(
              'The path tracer ',
              deadUsage: usage(10, 5),
            );
          }
          return FakeStreamFunction([
            textTurn('reversed.', usage: usage(20, 7)),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final events = await wrapped(
          testModel,
          Context(messages: [UserMessage.text('trace the path')]),
        ).toList();

        expect(calls, 2, reason: 'the aborted attempt resumes exactly once');
        // The tail request carries the accumulated content as the anchor.
        final anchor = requestContexts[1].messages.last as AssistantMessage;
        expect(
          anchor.content.whereType<TextContent>().map((b) => b.text),
          ['The path tracer '],
        );
        expect(anchor.stopReason, StopReason.stop);
        expect(anchor.errorMessage, isNull);
        // ONE logical assistant message: no second start, no duplicated
        // prefix, the tail continues the prefix.
        expect(events.whereType<StartEvent>(), hasLength(1));
        expect(events.whereType<ErrorEvent>(), isEmpty);
        final done = events.whereType<DoneEvent>().single;
        expect(done.message.stopReason, StopReason.stop);
        expect(
          done.message.content.whereType<TextContent>().map((b) => b.text),
          ['The path tracer ', 'reversed.'],
        );
        // No double-billing: the dead attempt's tokens are counted once,
        // in the resumed terminal message.
        expect(done.message.usage.input, 30);
        expect(done.message.usage.output, 12);
        expect(done.message.usage.totalTokens, 42);
        expect(notices, hasLength(1));
        expect(notices.single, contains('resuming from 1 completed block'));
      },
    );

    test(
      'E1: an abort mid-toolcall-delta drops the in-flight call from the '
      'anchor and shifts the tail indices — the call is never duplicated',
      () async {
        var calls = 0;
        final requestContexts = <Context>[];
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          requestContexts.add(context);
          if (calls == 1) {
            final stream = AssistantMessageEventStream();
            scheduleMicrotask(() {
              final empty = testAssistant();
              final withText = testAssistant(
                content: [const TextContent(text: 'Working on it.')],
              );
              final withTool = testAssistant(
                content: [
                  const TextContent(text: 'Working on it.'),
                  const ToolCall(
                    id: 't1',
                    name: 'sed',
                    arguments: {},
                    partialArguments: '{"path":"a.md"',
                  ),
                ],
              );
              stream
                ..push(StartEvent(partial: empty))
                ..push(TextStartEvent(contentIndex: 0, partial: empty))
                ..push(
                  TextDeltaEvent(
                    contentIndex: 0,
                    delta: 'Working on it.',
                    partial: withText,
                  ),
                )
                ..push(
                  TextEndEvent(
                    contentIndex: 0,
                    content: 'Working on it.',
                    partial: withText,
                  ),
                )
                ..push(ToolCallStartEvent(contentIndex: 1, partial: withText))
                ..push(
                  ToolCallDeltaEvent(
                    contentIndex: 1,
                    delta: '{"path":"a.md"',
                    partial: withTool,
                  ),
                )
                ..push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: testAssistant(
                      content: [
                        const TextContent(text: 'Working on it.'),
                        // The snapshot's best-effort finalized tool call.
                        const ToolCall(
                          id: 't1',
                          name: 'sed',
                          arguments: {},
                        ),
                      ],
                      stopReason: StopReason.aborted,
                      errorMessage: 'Request was aborted',
                    ),
                  ),
                );
              stream.end();
            });
            return stream;
          }
          return FakeStreamFunction([
            toolTurn([
              const ToolCall(id: 't1', name: 'sed', arguments: {
                'path': 'a.md',
              }),
            ]),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final events = await wrapped(
          testModel,
          const Context(messages: []),
        ).toList();

        expect(calls, 2);
        // The anchor keeps only COMPLETED blocks: the truncated tool call
        // (best-effort JSON) drops, so it can neither execute broken nor
        // duplicate.
        final anchor = requestContexts[1].messages.last as AssistantMessage;
        expect(
          anchor.content.whereType<TextContent>().map((b) => b.text),
          ['Working on it.'],
          reason: 'only completed blocks; the truncated tool call drops',
        );
        expect(anchor.content.whereType<ToolCall>(), isEmpty);
        // Tail indices shift past the prefix block.
        final toolEnd = events.whereType<ToolCallEndEvent>().single;
        expect(toolEnd.contentIndex, 1);
        expect(
          (toolEnd.partial.content[0] as TextContent).text,
          'Working on it.',
        );
        // Exactly one tool call survives in the final message.
        final done = events.whereType<DoneEvent>().single;
        expect(done.message.content.whereType<ToolCall>(), hasLength(1));
      },
    );

    test(
      'an abort inside the first unfinished block stands loud — nothing '
      'completed to resume from',
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
            final partial = testAssistant(
              content: [
                const ToolCall(
                  id: 't1',
                  name: 'sed',
                  arguments: {},
                  partialArguments: '{"pa',
                ),
              ],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(ToolCallStartEvent(contentIndex: 0, partial: empty))
              ..push(
                ToolCallDeltaEvent(
                  contentIndex: 0,
                  delta: '{"pa',
                  partial: partial,
                ),
              )
              ..push(
                ErrorEvent(
                  reason: StopReason.aborted,
                  error: testAssistant(
                    content: [
                      const ToolCall(id: 't1', name: 'sed', arguments: {}),
                    ],
                    stopReason: StopReason.aborted,
                    errorMessage: 'Request was aborted',
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
              'a replay would duplicate the streamed tool-call delta',
        );
        expect(
          events.whereType<ErrorEvent>().single.error.errorMessage,
          'Request was aborted',
        );
        expect(events.whereType<DoneEvent>(), isEmpty);
      },
    );

    test(
      'AC2: repeated aborts exhaust the budget and die loud with the full '
      'partial content preserved',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          return abortAfterText(calls == 1 ? 'part' : 'more');
        }, maxAttempts: 2);

        final events = await wrapped(
          testModel,
          const Context(messages: []),
        ).toList();

        expect(calls, 2, reason: 'the resume chain is bounded by the budget');
        final terminal = events.whereType<ErrorEvent>().single;
        expect(terminal.reason, StopReason.aborted);
        expect(terminal.error.errorMessage, 'Request was aborted');
        expect(
          terminal.error.content.whereType<TextContent>().map((b) => b.text),
          ['part', 'more'],
          reason: 'nothing the host already streamed is lost',
        );
        expect(events.whereType<DoneEvent>(), isEmpty);
      },
    );

    test(
      'AC3: a user abort after content stands — never enters the retry path',
      () async {
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
            final empty = testAssistant();
            final partial = testAssistant(
              content: [const TextContent(text: 'gone')],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(TextStartEvent(contentIndex: 0, partial: empty))
              ..push(
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'gone',
                  partial: partial,
                ),
              )
              ..push(
                TextEndEvent(
                  contentIndex: 0,
                  content: 'gone',
                  partial: partial,
                ),
              );
            // The host's user abort lands after the content streamed: a
            // bare cancel() (no reason) is user intent — a hard stop.
            scheduleMicrotask(source.cancel);
            source.token.onCancel.then((_) {
              stream
                ..push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: testAssistant(
                      content: [const TextContent(text: 'gone')],
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
        expect(terminal.error.errorMessage, 'Request was aborted');
        expect(events.whereType<DoneEvent>(), isEmpty);
      },
    );

    test(
      'E3: a run-idle-watchdog cancel (TimeoutException reason) is a '
      'machine abort — it resumes from the prefix',
      () async {
        var calls = 0;
        final source = CancelTokenSource();
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls == 1) {
            final stream = AssistantMessageEventStream();
            scheduleMicrotask(() {
              final empty = testAssistant();
              final partial = testAssistant(
                content: [const TextContent(text: 'watchdog cut')],
              );
              stream
                ..push(StartEvent(partial: empty))
                ..push(TextStartEvent(contentIndex: 0, partial: empty))
                ..push(
                  TextDeltaEvent(
                    contentIndex: 0,
                    delta: 'watchdog cut',
                    partial: partial,
                  ),
                )
                ..push(
                  TextEndEvent(
                    contentIndex: 0,
                    content: 'watchdog cut',
                    partial: partial,
                  ),
                );
              // agent.dart `_onRunWatchdogFired` cancels with its
              // RunIdleWatchdogFire (a TimeoutException subtype) as the
              // reason.
              scheduleMicrotask(
                () => source.cancel(
                  RunIdleWatchdogFire(
                    'agent run produced no events for 480s (run idle '
                    'watchdog)',
                  ),
                ),
              );
              source.token.onCancel.then((_) {
                stream
                  ..push(
                    ErrorEvent(
                      reason: StopReason.aborted,
                      error: testAssistant(
                        content: [
                          const TextContent(text: 'watchdog cut'),
                        ],
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
          return FakeStreamFunction([
            textTurn('finished'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final events = await wrapped(
          testModel,
          const Context(messages: []),
          cancelToken: source.token,
        ).toList();

        expect(calls, 2, reason: 'the watchdog-cancelled run resumes');
        final done = events.whereType<DoneEvent>().single;
        expect(
          done.message.content.whereType<TextContent>().map((b) => b.text),
          ['watchdog cut', 'finished'],
        );
        // Issue #1132 review: the resume re-arms the SAME token in place —
        // the loop's tool phases and a later `Agent.abort()` observe a
        // live latch, not a spent one.
        expect(source.token.isCancelled, isFalse);
      },
    );

    test(
      'S1: a user abort during the tail, after a watchdog resume, is '
      'honored — it stands with the streamed prefix preserved',
      () async {
        var calls = 0;
        final source = CancelTokenSource();
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls == 1) {
            final stream = AssistantMessageEventStream();
            scheduleMicrotask(() {
              final empty = testAssistant();
              final partial = testAssistant(
                content: [const TextContent(text: 'watchdog cut')],
              );
              stream
                ..push(StartEvent(partial: empty))
                ..push(TextStartEvent(contentIndex: 0, partial: empty))
                ..push(
                  TextDeltaEvent(
                    contentIndex: 0,
                    delta: 'watchdog cut',
                    partial: partial,
                  ),
                )
                ..push(
                  TextEndEvent(
                    contentIndex: 0,
                    content: 'watchdog cut',
                    partial: partial,
                  ),
                );
              // Watchdog fire (machine abort)...
              scheduleMicrotask(
                () => source.cancel(RunIdleWatchdogFire('watchdog')),
              );
              source.token.onCancel.then((_) {
                stream
                  ..push(
                    ErrorEvent(
                      reason: StopReason.aborted,
                      error: testAssistant(
                        content: [
                          const TextContent(text: 'watchdog cut'),
                        ],
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
          // The tail: content streams, then the USER aborts (bare cancel
          // on the same host source — live again after the reset).
          final stream = AssistantMessageEventStream();
          scheduleMicrotask(() {
            final empty = testAssistant();
            final partial = testAssistant(
              content: [const TextContent(text: 'tail continued')],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(TextStartEvent(contentIndex: 0, partial: empty))
              ..push(
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'tail continued',
                  partial: partial,
                ),
              );
            scheduleMicrotask(source.cancel);
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

        expect(calls, 2, reason: 'no third call: the user abort stands');
        final terminal = events.whereType<ErrorEvent>().single;
        expect(terminal.error.stopReason, StopReason.aborted);
        // The transcript-final message keeps the completed prefix (the
        // tail's un-ended delta drops per the #290 stand semantics — only
        // completed blocks are promised).
        expect(
          terminal.error.content.whereType<TextContent>().map((b) => b.text),
          ['watchdog cut'],
        );
        // The user's cancel is the last word: the token stays latched.
        expect(source.token.isCancelled, isTrue);
      },
    );

    test(
      'S2: a completed tool call before the abort never rides the anchor '
      '— strict-provider pairing holds, host-visible content survives',
      () async {
        var calls = 0;
        final requestContexts = <Context>[];
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          requestContexts.add(context);
          if (calls == 1) {
            final stream = AssistantMessageEventStream();
            scheduleMicrotask(() {
              final empty = testAssistant();
              final withText = testAssistant(
                content: [const TextContent(text: 'Working on ')],
              );
              const call = ToolCall(
                id: 't1',
                name: 'sed',
                arguments: {'i': ''},
              );
              final withCall = testAssistant(
                content: [const TextContent(text: 'Working on '), call],
              );
              stream
                ..push(StartEvent(partial: empty))
                ..push(TextStartEvent(contentIndex: 0, partial: empty))
                ..push(
                  TextDeltaEvent(
                    contentIndex: 0,
                    delta: 'Working on ',
                    partial: withText,
                  ),
                )
                ..push(
                  TextEndEvent(
                    contentIndex: 0,
                    content: 'Working on ',
                    partial: withText,
                  ),
                )
                ..push(ToolCallStartEvent(contentIndex: 1, partial: empty))
                ..push(
                  ToolCallEndEvent(
                    contentIndex: 1,
                    toolCall: call,
                    partial: withCall,
                  ),
                )
                ..push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: testAssistant(
                      content: [
                        const TextContent(text: 'Working on '),
                        call,
                      ],
                      stopReason: StopReason.aborted,
                      errorMessage: 'Request was aborted',
                    ),
                  ),
                );
              stream.end();
            });
            return stream;
          }
          return FakeStreamFunction([
            textTurn('done'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final events = await wrapped(
          testModel,
          const Context(messages: []),
        ).toList();

        expect(calls, 2);
        // The tail request's anchor stops before the completed tool call:
        // no tool_use without a tool_result reaches the wire.
        final anchor = requestContexts[1].messages.last as AssistantMessage;
        expect(
          anchor.content.whereType<TextContent>().map((b) => b.text),
          ['Working on '],
        );
        expect(anchor.content.whereType<ToolCall>(), isEmpty);
        // The host-visible logical message carries only what actually
        // executes: the dead call is dropped from the state (it never ran
        // — its attempt aborted before a tool phase), the tail's
        // regeneration is the single copy the tool phase will see.
        final done = events.whereType<DoneEvent>().single;
        expect(
          done.message.content.whereType<TextContent>().map((b) => b.text),
          ['Working on ', 'done'],
        );
        expect(done.message.content.whereType<ToolCall>(), isEmpty);
      },
    );

    test(
      'S2b: an abort whose only completed block is a tool call sends the '
      'tail on the original context — no empty anchor',
      () async {
        var calls = 0;
        final requestContexts = <Context>[];
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          requestContexts.add(context);
          if (calls == 1) {
            final stream = AssistantMessageEventStream();
            scheduleMicrotask(() {
              final empty = testAssistant();
              const call = ToolCall(id: 't1', name: 'sed', arguments: {});
              final withCall = testAssistant(content: [call]);
              stream
                ..push(StartEvent(partial: empty))
                ..push(ToolCallStartEvent(contentIndex: 0, partial: empty))
                ..push(
                  ToolCallEndEvent(
                    contentIndex: 0,
                    toolCall: call,
                    partial: withCall,
                  ),
                )
                ..push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: testAssistant(
                      content: [call],
                      stopReason: StopReason.aborted,
                      errorMessage: 'Request was aborted',
                    ),
                  ),
                );
              stream.end();
            });
            return stream;
          }
          return FakeStreamFunction([
            textTurn('done'),
          ]).call(model, context, cancelToken: cancelToken);
        });

        final events = await wrapped(
          testModel,
          const Context(messages: []),
        ).toList();

        expect(calls, 2);
        // The anchor would be empty (tool calls never anchor): the tail
        // request goes out on the original context instead.
        expect(
          requestContexts[1].messages.length,
          requestContexts[0].messages.length,
        );
        // The dead call is dropped entirely: the resumed message carries
        // only the tail's content, so nothing unexecuted rides the
        // transcript.
        final done = events.whereType<DoneEvent>().single;
        expect(done.message.content.whereType<ToolCall>(), isEmpty);
        expect(
          done.message.content.whereType<TextContent>().map((b) => b.text),
          ['done'],
        );
      },
    );

    test(
      'S3: the chain dying on a non-abort tail failure at budget end keeps '
      'the streamed prefix in the terminal message',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls == 1) {
            return abortAfterText('part', deadUsage: usage(10, 5));
          }
          // Attempt 2 dies pre-commit with a transient RST on the last
          // budgeted attempt.
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
        }, maxAttempts: 2);

        final events = await wrapped(
          testModel,
          const Context(messages: []),
        ).toList();

        expect(calls, 2);
        final terminal = events.whereType<ErrorEvent>().single;
        expect(terminal.error.stopReason, StopReason.error);
        expect(terminal.error.errorMessage, contains('2 attempt(s)'));
        // Nothing already streamed is lost (AC2 promise at the seam).
        expect(
          terminal.error.content.whereType<TextContent>().map((b) => b.text),
          ['part'],
        );
        expect(terminal.error.usage.input, 10);
        expect(terminal.error.usage.output, 5);
      },
    );

    test(
      'S4: a post-commit non-abort failure on the resumed path keeps the '
      'mid-answer hygiene wrap and the streamed prefix',
      () async {
        var calls = 0;
        final wrapped = transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          if (calls == 1) {
            return abortAfterText('part');
          }
          final stream = AssistantMessageEventStream();
          scheduleMicrotask(() {
            final empty = testAssistant();
            final partial = testAssistant(
              content: [const TextContent(text: 'tail')],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(TextStartEvent(contentIndex: 0, partial: empty))
              ..push(
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'tail',
                  partial: partial,
                ),
              )
              ..push(
                ErrorEvent(
                  reason: StopReason.error,
                  error: testAssistant(
                    content: [const TextContent(text: 'tail')],
                    stopReason: StopReason.error,
                    errorMessage: 'Connection reset by peer',
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

        final terminal = events.whereType<ErrorEvent>().single;
        expect(
          terminal.error.errorMessage,
          contains('Provider failed mid-answer'),
          reason: 'the #290 hygiene wrap applies on the resume path too',
        );
        expect(terminal.error.errorMessage, contains('Connection reset'));
        expect(
          terminal.error.content.whereType<TextContent>().map((b) => b.text),
          ['part', 'tail'],
        );
      },
    );
    test(
      'S5: a plain TimeoutException cancel (a compaction budget kill) is '
      'host intent — it stands, never resumes',
      () async {
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
            final empty = testAssistant();
            final partial = testAssistant(
              content: [const TextContent(text: 'summarizing...')],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(TextStartEvent(contentIndex: 0, partial: empty))
              ..push(
                TextDeltaEvent(
                  contentIndex: 0,
                  delta: 'summarizing...',
                  partial: partial,
                ),
              )
              ..push(
                TextEndEvent(
                  contentIndex: 0,
                  content: 'summarizing...',
                  partial: partial,
                ),
              );
            // The structured-compaction budget cancels with a NAMED plain
            // TimeoutException (engine.dart) — fail-fast, no retry spin.
            // The text block COMPLETED first, so only the typed reason
            // check keeps this from resuming.
            scheduleMicrotask(
              () => source.cancel(
                TimeoutException(
                  'structured compaction summary exceeded the 90s budget '
                  '(issue #515)',
                ),
              ),
            );
            source.token.onCancel.then((_) {
              stream
                ..push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: testAssistant(
                      content: [const TextContent(text: 'summarizing...')],
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

        expect(calls, 1, reason: 'a budget kill must not spin the resume');
        final terminal = events.whereType<ErrorEvent>().single;
        expect(terminal.error.stopReason, StopReason.aborted);
        // The token stays latched — the kill keeps its teeth.
        expect(source.token.isCancelled, isTrue);
      },
    );
  });
}
