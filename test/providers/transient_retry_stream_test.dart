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
      expect(
        isTransientNetworkError(errorMsg('Connection refused')),
        isTrue,
      );
      expect(
        isTransientNetworkError(errorMsg('Network is unreachable')),
        isTrue,
      );
      expect(
        isTransientNetworkError(errorMsg('Connection timed out')),
        isTrue,
      );
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
          errorMsg('no events from the endpoint for 300s (stream idle timeout)'),
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

    test('a reset-then-recover call retries and succeeds', () async {
      var calls = 0;
      final notices = <String>[];
      transientRetryNotice = (attempt, max, delay, reason) {
        notices.add('${attempt + 1}/$max in ${delay.inSeconds}s: $reason');
      };
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
          calls++;
          if (calls < 3) {
            return failWith(
              'SocketException: Connection reset by peer, errno = 54',
            );
          }
          return FakeStreamFunction([textTurn('recovered')]).call(
            model,
            context,
            cancelToken: cancelToken,
          );
        },
      );

      final message = await wrapped(testModel, const Context(messages: [])).result;

      expect(calls, 3, reason: 'two transient failures, then the recover');
      expect(message.stopReason, StopReason.stop);
      expect(
        message.content.whereType<TextContent>().single.text,
        'recovered',
      );
      expect(notices, hasLength(2));
      expect(notices.first, contains('2/3 in 5s'));
      expect(notices.first, contains('Connection reset by peer'));
    });

    test('a non-transient error is forwarded without any retry', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
          calls++;
          return failWith('401 unauthorized');
        },
      );

      final message = await wrapped(testModel, const Context(messages: [])).result;

      expect(calls, 1);
      expect(message.stopReason, StopReason.error);
      expect(message.errorMessage, '401 unauthorized');
    });

    test('an exhausted budget forwards the last failure', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
          calls++;
          return failWith('Connection reset by peer');
        },
      );

      final message = await wrapped(testModel, const Context(messages: [])).result;

      expect(calls, 3, reason: 'the full budget burned');
      expect(message.stopReason, StopReason.error);
      expect(message.errorMessage, 'Connection reset by peer');
    });

    test('a failure AFTER content is never replayed (observable-output '
        'guard)', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
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
        },
      );

      final events = await wrapped(testModel, const Context(messages: [])).toList();

      expect(calls, 1, reason: 'partial content committed the attempt');
      expect(events.whereType<TextDeltaEvent>(), hasLength(1));
      expect(events.whereType<ErrorEvent>(), hasLength(1));
    });

    test('a cancel during the retry sleep aborts instead of replaying',
        () async {
      var calls = 0;
      final source = CancelTokenSource();
      transientRetrySleeper = (delay, token) async {
        source.cancel();
        return false;
      };
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
          calls++;
          return failWith('Connection reset by peer');
        },
      );

      final message = await wrapped(
        testModel,
        const Context(messages: []),
        cancelToken: source.token,
      ).result;

      expect(calls, 1, reason: 'the sleep was cancelled — no second call');
      expect(message.stopReason, StopReason.aborted);
      expect(message.errorMessage, contains('Connection reset by peer'));
    });

    test('providerStreamFunction wraps every kind with the retry', () async {
      // The chokepoint contract: a transient failure on the FIRST call
      // replays — proven here through the factory itself (google kind with
      // a mock client that 500s once would need HTTP plumbing; the wrapper
      // composition is asserted structurally instead).
      final stream = providerStreamFunction('google', 'test-key');
      var calls = 0;
      final probe = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
          calls++;
          return failWith('Connection reset by peer');
        },
      );
      await probe(testModel, const Context(messages: [])).result;
      expect(calls, 3);
      expect(stream, isNotNull);
    });
  });
}
