// Background DOM extraction without a visible tab (issue #30, 'offscreen
// documents' + E22): a thin lifecycle manager over chrome.offscreen plus a
// lifetime-capped work scope. Everything runs on the injected clock — no
// wall timers — so tests drive expiry deterministically. Every facade
// failure degrades to OffscreenUnavailableException carrying the facade's
// machine code (E22: fail with a documented reason string, never hang).
library;

import 'dart:async';
import 'dart:math' as math;

import '../chrome_api.dart';

/// Where the manager's offscreen documents live. One document at a time
/// (chrome's own budget): parsing, audio and research runs reuse it.
const offscreenDocUrl = 'offscreen.html';

/// Offscreen document creation failed. [code] mirrors the facade's machine
/// vocabulary ('invalid_reason', 'quota_exceeded', ...) so callers can
/// degrade on codes, not message text.
final class OffscreenUnavailableException implements Exception {
  OffscreenUnavailableException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'OffscreenUnavailableException($code): $message';
}

/// A `within()` scope outlived its cap: the work was abandoned (its future
/// stays pending — Dart futures cannot be cancelled) and the document was
/// closed. [elapsedMs] is what the injected clock measured, [reason] the
/// MV3 reason the document was opened with.
final class OffscreenLifetimeExceededException implements Exception {
  OffscreenLifetimeExceededException({
    required this.elapsedMs,
    required this.reason,
  });

  final int elapsedMs;
  final String reason;

  @override
  String toString() =>
      'OffscreenLifetimeExceededException(reason: $reason, '
      'elapsedMs: $elapsedMs)';
}

/// One open offscreen document. Returned by [OffscreenManager.open]; the
/// scoped way to use it is [within] — run the extraction under a cap and
/// the document always closes, on success, on abort and on error alike.
final class OffscreenHandle {
  OffscreenHandle._(this._manager, this.reason, this.lifetimeCap);

  final OffscreenManager _manager;

  /// The MV3 reason string the document was created with; rides the
  /// lifetime exception so logs say what kind of run overran.
  final String reason;

  /// The document-level lifetime budget `open` was configured with. [within]
  /// enforces the per-call cap it is handed; this is the metadata the wiring
  /// layer may use to budget multiple scopes on one document.
  final Duration lifetimeCap;

  /// Closes the document. Idempotent: a second call is a no-op.
  Future<void> close() => _manager.close();

  /// Runs [work] under the offscreen document, aborting if the injected
  /// clock measures more than [cap] elapsed: the returned future then
  /// completes with [OffscreenLifetimeExceededException] and the document
  /// is closed. On normal completion and on work failure the document
  /// closes too — `within` is a scoped session.
  Future<T> within<T>(Duration cap, Future<T> Function() work) =>
      _manager._within(this, cap, work);
}

/// Owns the single MV3 offscreen document the background uses for DOM
/// extraction without a visible tab.
final class OffscreenManager {
  OffscreenManager(
    this._offscreen, {
    int Function()? nowMs,
    Future<void> Function(Duration)? delay,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _delay = delay ?? ((d) => Future<void>.delayed(d));

  final OffscreenApi _offscreen;

  /// The only time source. Determinism contract: expiry is detected when
  /// this clock is read, never by real timers.
  final int Function() _nowMs;

  /// Scheduler for the expiry watcher. Production parks a real timer for
  /// exactly the remaining budget; tests inject an immediate future and
  /// drive [_nowMs] instead.
  final Future<void> Function(Duration) _delay;

  bool _documentOpen = false;

  /// Whether this manager currently has a document open (its own state
  /// mirror of chrome.offscreen.hasDocument, without the await).
  bool get hasDocument => _documentOpen;

  /// Creates the offscreen document. Throws
  /// [OffscreenUnavailableException] with the facade's code if chrome
  /// refuses (E22). A document leaked by a previous service-worker life
  /// ('document_exists') is adopted via close + recreate instead of
  /// wedging every future open.
  Future<OffscreenHandle> open({
    required String reason,
    required String justification,
    Duration lifetimeCap = const Duration(minutes: 5),
  }) async {
    await _create(reason, justification);
    _documentOpen = true;
    return OffscreenHandle._(this, reason, lifetimeCap);
  }

  /// Closes the document if this manager has one. Idempotent and safe
  /// before any [open].
  Future<void> close() async {
    if (!_documentOpen) return;
    _documentOpen = false;
    try {
      await _offscreen.closeDocument();
    } on ChromeApiException {
      // Facade says there is nothing left to close — that is the state we
      // wanted; swallow and stay idempotent.
    }
  }

  /// Slices [bytes] into chunks of at most [chunkSize] for long extractions:
  /// feed slice by slice so each slice fits the remaining lifetime budget.
  /// 10 bytes / 3 → [3, 3, 3, 1]; empty input → no chunks; an exact
  /// multiple emits no empty remainder chunk.
  static Stream<List<int>> chunked(List<int> bytes, int chunkSize) async* {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      yield bytes.sublist(offset, math.min(offset + chunkSize, bytes.length));
    }
  }

  Future<void> _create(String reason, String justification) async {
    try {
      await _offscreen.createDocument(
        url: offscreenDocUrl,
        reasons: {reason},
        justification: justification,
      );
      return;
    } on ChromeApiException catch (e) {
      if (e.code != 'document_exists') {
        throw OffscreenUnavailableException(e.code, e.message);
      }
      // MV3 offscreen documents outlive the service worker. A doc leaked by
      // a previous SW life must not wedge every future open (E22): adopt by
      // close + recreate, and degrade if even that is refused.
      _documentOpen = false;
      try {
        await _offscreen.closeDocument();
      } on ChromeApiException {
        // Already gone.
      }
      try {
        await _offscreen.createDocument(
          url: offscreenDocUrl,
          reasons: {reason},
          justification: justification,
        );
      } on ChromeApiException catch (e) {
        throw OffscreenUnavailableException(e.code, e.message);
      }
    }
  }

  Future<T> _within<T>(
    OffscreenHandle handle,
    Duration cap,
    Future<T> Function() work,
  ) async {
    final startMs = _nowMs();
    final capMs = cap.inMilliseconds;
    final aborted = Completer<Never>();
    var settled = false;

    // Expiry watcher: parks until the remaining budget is spent (on the
    // injected clock's terms), then aborts. Re-arms off real-clock drift so
    // a slightly-early timer cannot let the scope escape its cap.
    Future<void> watch() async {
      while (!settled) {
        final elapsedMs = _nowMs() - startMs;
        if (elapsedMs >= capMs) {
          if (!aborted.isCompleted) {
            aborted.completeError(
              OffscreenLifetimeExceededException(
                elapsedMs: elapsedMs,
                reason: handle.reason,
              ),
            );
          }
          return;
        }
        await _delay(Duration(milliseconds: capMs - elapsedMs));
      }
    }

    unawaited(watch());
    try {
      // Race work against expiry: first side wins, the loser's future is
      // dropped (still pending on abort — that is what "abandoned" means).
      return await Future.any<T>([work(), aborted.future]);
    } finally {
      settled = true;
      await close();
    }
  }
}
