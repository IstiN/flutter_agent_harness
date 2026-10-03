import 'dart:async';

/// Cooperative cancellation, the Dart counterpart of the web `AbortSignal`.
///
/// Provider adapters and the agent loop take a [CancelToken]; callers cancel
/// in-flight work via [CancelTokenSource.cancel]. Cancellation is delivered
/// asynchronously through [onCancel] so listeners never run reentrantly
/// inside [CancelTokenSource.cancel].
class CancelToken {
  CancelToken._();

  final _listeners = <void Function()>[];
  var _cancelled = false;
  Object? _reason;

  /// Whether [CancelTokenSource.cancel] has been called.
  bool get isCancelled => _cancelled;

  /// The reason passed to [CancelTokenSource.cancel], if any.
  Object? get cancelReason => _reason;

  /// A future that completes when the token is cancelled.
  ///
  /// Completes immediately if the token is already cancelled.
  Future<void> get onCancel {
    final completer = Completer<void>.sync();
    if (_cancelled) {
      completer.complete();
    } else {
      _listeners.add(completer.complete);
    }
    return completer.future;
  }

  /// Throws [CancelledException] if the token is cancelled.
  ///
  /// Intended for cheap guard checks at loop boundaries:
  /// `token.throwIfCancelled();`.
  void throwIfCancelled() {
    if (_cancelled) throw CancelledException(_reason);
  }

  void _cancel(Object? reason) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      scheduleMicrotask(listener);
    }
  }

  /// Re-opens the latch after a machine-initiated cancel that a resuming
  /// layer chose to recover from (issue #1126: the run-idle watchdog's
  /// [RunIdleWatchdogFire] cancel — the transient-retry wrapper resumes
  /// the generation and re-arms the SAME token in place).
  ///
  /// Every holder of this token — the loop's tool phases, a later
  /// `Agent.abort()`, the next provider request — keeps working through
  /// the same object: future [CancelTokenSource.cancel] calls re-latch and
  /// fire listeners normally. Never call this for a USER abort: that
  /// cancellation is intent and stands.
  ///
  /// Two sharp edges to know before reusing this on another latch:
  ///
  /// - **`onCancel` futures are one-shot.** Listeners registered before
  ///   the cancel have already completed and will never observe a
  ///   post-[reset] cancel; only listeners registered AFTER the reset
  ///   fire on the next cancel. A host that linked secondary work to the
  ///   token across a resume (the #1085 linking pattern) must
  ///   re-subscribe — nothing re-arms its link automatically.
  /// - **A cancel racing the reset is dropped.** The window between the
  ///   machine cancel and this reset is microtask-scale, but a
  ///   [CancelTokenSource.cancel] landing inside it is a no-op (first
  ///   reason wins) and its intent is lost — the run continues and the
  ///   user must abort again. Accepted for the watchdog resume; do not
  ///   copy the pattern onto latches where that loss matters.
  void reset() {
    _cancelled = false;
    _reason = null;
  }
}

/// The writable side of a [CancelToken]. Keep it private to the caller that
/// owns the operation; hand only the [token] to callees.
class CancelTokenSource {
  CancelTokenSource() : token = CancelToken._();

  /// The token to pass down to cancellable work.
  final CancelToken token;

  /// Cancels [token]. Idempotent; the first [reason] wins.
  void cancel([Object? reason]) => token._cancel(reason);
}

/// Thrown by [CancelToken.throwIfCancelled] and by operations that abort
/// early due to cancellation.
class CancelledException implements Exception {
  CancelledException(this.reason);

  /// The reason passed to [CancelTokenSource.cancel], if any.
  final Object? reason;

  @override
  String toString() => 'CancelledException${reason == null ? '' : ': $reason'}';
}

/// The run-idle watchdog's cancel reason (`agent.dart
/// _onRunWatchdogFired`): the one MACHINE-initiated token cancel. The
/// transient-retry wrapper discriminates on this type (issue #1126): a
/// mid-stream abort under a watchdog fire resumes from the completed
/// prefix, while ANY other cancel — a bare user abort, a compaction
/// budget's plain [TimeoutException] kill — stands. Still a
/// [TimeoutException], so existing `onRunIdleTimeout` consumers and
/// `isA<TimeoutException>()` assertions keep working.
class RunIdleWatchdogFire extends TimeoutException {
  RunIdleWatchdogFire([super.message, super.duration]);
}

/// Zone key under which the agent loop publishes the current tool phase's
/// soft-yield token (see [currentYieldToken]).
const Symbol yieldTokenZoneKey = #fahYieldToken;

/// The soft-yield token of the enclosing tool-call phase, or null.
///
/// Yielding is NOT cancellation: a steering message arriving mid-phase asks
/// long-running tools (bash, task) to finish the tool call early WITHOUT
/// stopping the underlying work — the work continues as a background job and
/// the loop delivers the user message at the next step boundary. Tools opt
/// in by reading this token; everyone else ignores it and the message simply
/// waits for the phase to complete (the classic behavior).
CancelToken? currentYieldToken() =>
    Zone.current[yieldTokenZoneKey] as CancelToken?;
