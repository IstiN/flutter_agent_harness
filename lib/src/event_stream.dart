/// Push-based event streams with an awaitable final result.
///
/// Ported from pi-mono `packages/ai/src/utils/event-stream.ts`. pi implements
/// its own queue/waiter machinery on top of async iterators; in Dart the same
/// semantics are provided by a single-subscription [StreamController]: events
/// pushed before a consumer starts listening are buffered, and the stream is
/// consumed with `await for` or any `Stream` operator.
library;

import 'dart:async';

import 'types.dart';

/// A push-based stream of events with an awaitable final result.
///
/// Ported from pi's `EventStream<T, R>`. Producers [push] events and finally
/// call [end]; consumers iterate the stream (this class *is* a `Stream<T>`)
/// and/or await [result] for the terminal value extracted from the
/// completion event.
///
/// One deliberate divergence from pi: if [end] is called without a result and
/// no completion event was ever pushed, pi's `result()` promise hangs
/// forever; here [result] completes with a [StateError] instead, so awaiting
/// callers cannot deadlock.
class EventStream<T, R> extends Stream<T> {
  /// Creates an event stream.
  ///
  /// [isComplete] marks the terminal event; [extractResult] turns that event
  /// into the value [result] completes with.
  EventStream({required this.isComplete, required this.extractResult});

  /// Predicate marking the terminal event of the stream.
  final bool Function(T event) isComplete;

  /// Extracts the terminal value from a completion event.
  final R Function(T event) extractResult;
  final _controller = StreamController<T>();
  final _resultCompleter = Completer<R>();
  var _done = false;

  /// Pushes [event] to consumers.
  ///
  /// Ignored after the stream has completed ([end] was called or a completion
  /// event was pushed). When [event] is the completion event, [result]
  /// resolves with the extracted value.
  void push(T event) {
    if (_done) return;

    if (isComplete(event)) {
      _done = true;
      _completeResult(extractResult(event));
    }

    _controller.add(event);
  }

  /// Marks the stream as finished and closes it.
  ///
  /// If [result] is provided, the [result] future resolves with it (the first
  /// resolution wins, mirroring pi's promise semantics). If neither [result]
  /// nor a completion event materializes, [result] completes with a
  /// [StateError] (pi's promise would hang forever; a hanging future is worse
  /// than a thrown error). Idempotent.
  void end([R? result]) {
    _done = true;
    if (result != null) {
      _completeResult(result);
    }
    if (!_resultCompleter.isCompleted) {
      _resultCompleter.completeError(
        StateError('EventStream ended without a completion event'),
      );
      // Suppress the unhandled-async-error report when nobody awaits
      // [result]; listeners on [result] itself still receive the error.
      _resultCompleter.future.ignore();
    }
    unawaited(_controller.close());
  }

  /// A future that completes with the terminal value: the result extracted
  /// from the completion event, or the value passed to [end].
  Future<R> get result => _resultCompleter.future;

  void _completeResult(R value) {
    if (!_resultCompleter.isCompleted) {
      _resultCompleter.complete(value);
    }
  }

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// The event stream returned by provider `stream` calls.
///
/// Ported from pi's `AssistantMessageEventStream`. Completes when a
/// [DoneEvent] or [ErrorEvent] is pushed; [result] then yields the final
/// [AssistantMessage] (the error message for [ErrorEvent], per the
/// providers-never-throw contract).
///
/// ```dart
/// final stream = provider.stream(model, context);
/// await for (final event in stream) {
///   if (event is TextDeltaEvent) write(event.delta);
/// }
/// final message = await stream.result;
/// ```
class AssistantMessageEventStream
    extends EventStream<AssistantMessageEvent, AssistantMessage> {
  AssistantMessageEventStream()
    : super(
        isComplete: (event) => event is DoneEvent || event is ErrorEvent,
        extractResult: (event) => switch (event) {
          DoneEvent(:final message) => message,
          ErrorEvent(:final error) => error,
          _ => throw StateError(
            'Unexpected event type for final result: $event',
          ),
        },
      );
}

/// Creates an [AssistantMessageEventStream].
///
/// Ported from pi's `createAssistantMessageEventStream` factory, intended for
/// use in extensions.
AssistantMessageEventStream createAssistantMessageEventStream() {
  return AssistantMessageEventStream();
}
