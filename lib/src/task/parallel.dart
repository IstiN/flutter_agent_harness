/// Concurrency primitives for the `task` tool: the session-scoped
/// [Semaphore] that bounds how many subagents run concurrently across all
/// `task` calls of a session.
///
/// Ported from oh-my-pi `packages/coding-agent/src/task/parallel.ts`. Only
/// the semaphore is ported: fan-out ordering is plain `Future.wait` over
/// per-item guarded spawns (each acquires the semaphore first), so omp's
/// worker-pool helpers (`mapWithConcurrencyLimit[AllSettled]`) have no
/// counterpart here.
library;

import 'dart:async';

import '../cancel_token.dart';

/// Normalizes a configured concurrency cap (omp's `normalizeConcurrencyLimit`):
/// `max <= 0` (or any non-finite input) means unbounded — every [Semaphore.acquire]
/// resolves immediately, matching `task.maxConcurrency = 0`'s "Unlimited"
/// semantics in omp's settings UI.
int normalizeConcurrencyLimit(num max) {
  final normalized = max.isFinite ? max.truncate() : 0;
  return normalized > 0 ? normalized : 0;
}

/// Simple counting semaphore for limiting concurrency across independently
/// scheduled async work (port of omp's `Semaphore`).
///
/// A [CancelToken] passed to [acquire] removes the waiter from the queue on
/// cancellation so an abandoned waiter can never be admitted later and
/// permanently shrink effective concurrency (omp issue #3464 feedback).
final class Semaphore {
  /// Creates a semaphore admitting at most [max] concurrent holders;
  /// `max <= 0` means unbounded.
  Semaphore(int max) : _max = max > 0 ? max : _unbounded;

  static const _unbounded = 1 << 62;

  int _max;
  var _current = 0;
  final _queue = <void Function()>[];

  /// The configured ceiling (a huge sentinel when unbounded).
  int get max => _max;

  /// The number of slots currently held.
  int get current => _current;

  /// Waiters still queued for a slot.
  int get queued => _queue.length;

  /// Resolves when a slot is available.
  ///
  /// Throws [CancelledException] when [cancelToken] is (or becomes) cancelled
  /// while waiting; an already-admitted caller is unaffected.
  Future<void> acquire([CancelToken? cancelToken]) {
    cancelToken?.throwIfCancelled();
    if (_current < _max) {
      _current++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    var settled = false;
    void waiter() {
      if (settled) return;
      settled = true;
      completer.complete();
    }

    _queue.add(waiter);
    if (cancelToken != null) {
      unawaited(
        cancelToken.onCancel.then((_) {
          if (settled) return;
          settled = true;
          _queue.remove(waiter);
          completer.completeError(CancelledException(cancelToken.cancelReason));
          // Nobody may await the future (caller raced away); never crash.
          completer.future.ignore();
        }),
      );
    }
    return completer.future;
  }

  /// Releases one slot, admitting the next queued waiter when under the
  /// (possibly just-lowered) ceiling.
  void release() {
    if (_current > 0) _current--;
    if (_current < _max && _queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      _current++;
      next();
    }
  }

  /// Adjusts the maximum concurrency in place (omp's `resize`). Raising the
  /// ceiling immediately admits queued waiters that now fit; lowering it lets
  /// in-flight holders drain naturally.
  void resize(int max) {
    _max = max > 0 ? max : _unbounded;
    while (_current < _max && _queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      _current++;
      next();
    }
  }
}
