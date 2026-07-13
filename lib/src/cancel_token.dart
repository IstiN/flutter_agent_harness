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
