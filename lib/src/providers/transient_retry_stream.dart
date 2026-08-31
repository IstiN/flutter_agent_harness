/// Transient network retry: a [StreamFunction] wrapper that replays a
/// provider call when the failure is a socket-level disconnect — the
/// laptop switches Wi-Fi networks mid-turn and the stream dies with
/// "Connection reset by peer". Policy (user-specified): sleep a fixed
/// delay (5s default), then retry the call.
///
/// Boundary discipline:
/// - Only socket-level failures classify (reset/refused/unreachable/timed
///   out/broken pipe/TLS handshake cut). Rate limits stay with the roles
///   layer ([FallbackStreamFunction]), auth failures stand, context
///   overflow belongs to compaction, and the idle watchdog's own
///   `TimeoutException` wording deliberately does NOT match (that error
///   means "the endpoint went silent", which a retry re-arms anyway).
/// - omp's observable-output guard is kept: a stream that already emitted
///   content is never replayed — its failure stands (a retried generation
///   would duplicate text in the transcript).
/// - Providers-never-throw is preserved: a defensive catch converts a
///   throwing inner stream into an error event.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../types.dart';

/// Patterns classifying a provider error as a transient network failure:
/// the wordings `dart:io` sockets and the http client produce when the
/// link drops (Wi-Fi switch, VPN flap, gateway restart).
final _transientNetworkPatterns = [
  RegExp(r'connection reset', caseSensitive: false),
  RegExp(r'socketexception', caseSensitive: false),
  RegExp(r'connection refused', caseSensitive: false),
  RegExp(r'connection timed? ?out', caseSensitive: false),
  RegExp(r'network is unreachable', caseSensitive: false),
  RegExp(r'connection aborted', caseSensitive: false),
  RegExp(r'broken pipe', caseSensitive: false),
  RegExp(r'no route to host', caseSensitive: false),
  RegExp(r'host is (down|unreachable)', caseSensitive: false),
  RegExp(r'software caused connection abort', caseSensitive: false),
  RegExp(r'handshake ?exception', caseSensitive: false),
];

/// Whether [message] is a transient socket-level failure worth replaying.
/// Requires an error stop with a message; certificate problems are excluded
/// (a bad cert never heals in 5 seconds — that's a config error).
bool isTransientNetworkError(AssistantMessage message) {
  if (message.stopReason != StopReason.error) return false;
  final text = message.errorMessage;
  if (text == null || text.isEmpty) return false;
  if (text.toLowerCase().contains('certificate')) return false;
  return _transientNetworkPatterns.any((pattern) => pattern.hasMatch(text));
}

/// The no-silent-retry note: fired before each retry sleep so the user
/// sees "connection lost — retrying in 5s (attempt 2/3)" instead of a
/// mysterious pause. [attempt] is the 1-based attempt that just failed;
/// [maxAttempts] the total budget; [reason] the truncated provider error.
typedef TransientRetryNotice =
    void Function(int attempt, int maxAttempts, Duration delay, String reason);

/// The host-visible retry hook (the CLI prints it + logs to fa.log).
/// Null keeps retries silent. Global like `providerTimeoutsOverride`: the
/// wrap happens deep inside [providerStreamFunction], far from any host io.
TransientRetryNotice? transientRetryNotice;

/// The retry sleep — injectable so tests don't wait real seconds. Returns
/// false when the wait was cancelled (the retry is abandoned).
Future<bool> Function(Duration delay, CancelToken? cancelToken)
transientRetrySleeper = _realTransientSleep;

Future<bool> _realTransientSleep(Duration delay, CancelToken? token) async {
  if (token == null) {
    await Future<void>.delayed(delay);
    return true;
  }
  return Future.any([
    Future<void>.delayed(delay).then((_) => true),
    token.onCancel.then((_) => false),
  ]);
}

/// Wraps [inner] with the transient-network retry policy: up to
/// [maxAttempts] total attempts (1 = no retry), [delay] between them.
StreamFunction transientRetryStreamFunction(
  StreamFunction inner, {
  int maxAttempts = 3,
  Duration delay = const Duration(seconds: 5),
}) {
  assert(maxAttempts >= 1, 'maxAttempts must be at least 1');
  return (Model model, Context context, {CancelToken? cancelToken}) {
    final out = AssistantMessageEventStream();
    unawaited(
      _drive(out, inner, model, context, cancelToken, maxAttempts, delay)
          .catchError((Object error) {
            // Defensive (providers never throw; a fake in tests might).
            out.push(
              ErrorEvent(
                reason: StopReason.error,
                error: AssistantMessage(
                  content: const [],
                  api: model.api,
                  provider: model.provider,
                  model: model.id,
                  usage: Usage.zero,
                  stopReason: StopReason.error,
                  errorMessage: '$error',
                  timestamp: DateTime.now(),
                ),
              ),
            );
          })
          .whenComplete(out.end),
    );
    return out;
  };
}

Future<void> _drive(
  AssistantMessageEventStream out,
  StreamFunction inner,
  Model model,
  Context context,
  CancelToken? cancelToken,
  int maxAttempts,
  Duration delay,
) async {
  AssistantMessage? lastFailure;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    if (cancelToken?.isCancelled ?? false) {
      _pushAborted(out, model, lastFailure);
      return;
    }
    final outcome = await _runAttempt(
      out,
      inner,
      model,
      context,
      cancelToken,
    );
    switch (outcome) {
      case _Forwarded():
        return;
      case _TransientFailure(:final error):
        lastFailure = error;
        if (attempt >= maxAttempts) {
          // Budget exhausted: the last failure stands (forward verbatim).
          out.push(
            ErrorEvent(reason: StopReason.error, error: error),
          );
          return;
        }
        final reason = (error.errorMessage ?? 'network error');
        transientRetryNotice?.call(
          attempt,
          maxAttempts,
          delay,
          reason.length > 120 ? reason.substring(0, 120) : reason,
        );
        final survived = await transientRetrySleeper(delay, cancelToken);
        if (!survived) {
          _pushAborted(out, model, lastFailure);
          return;
        }
    }
  }
}

/// Pushes a terminal aborted event, reusing the last failure's text when
/// one exists (the transcript shows WHAT was interrupted).
void _pushAborted(
  AssistantMessageEventStream out,
  Model model,
  AssistantMessage? lastFailure,
) {
  out.push(
    ErrorEvent(
      reason: StopReason.aborted,
      error: AssistantMessage(
        content: const [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.aborted,
        errorMessage:
            lastFailure?.errorMessage ?? 'Request was aborted',
        timestamp: DateTime.now(),
      ),
    ),
  );
}

sealed class _AttemptOutcome {
  const _AttemptOutcome();
}

/// The attempt's events (or its terminal failure) reached the caller.
final class _Forwarded extends _AttemptOutcome {
  const _Forwarded();
}

/// The attempt failed transiently before any observable output.
final class _TransientFailure extends _AttemptOutcome {
  const _TransientFailure(this.error);

  /// The terminal error message (kept for the final forward on exhaustion).
  final AssistantMessage error;
}

/// Runs one attempt, buffering until the first observable output commits
/// it (the same guard as the roles fallback: a pre-content failure leaves
/// no trace, a post-content failure stands).
Future<_AttemptOutcome> _runAttempt(
  AssistantMessageEventStream out,
  StreamFunction inner,
  Model model,
  Context context,
  CancelToken? cancelToken,
) async {
  final buffer = <AssistantMessageEvent>[];
  var committed = false;
  await for (final event in inner(model, context, cancelToken: cancelToken)) {
    if (committed) {
      out.push(event);
      if (event is DoneEvent || event is ErrorEvent) {
        return const _Forwarded();
      }
      continue;
    }
    switch (event) {
      case DoneEvent():
        buffer.forEach(out.push);
        out.push(event);
        return const _Forwarded();
      case ErrorEvent():
        if (event.reason == StopReason.error &&
            isTransientNetworkError(event.error)) {
          // Not forwarded: the buffer is discarded and the call retries.
          return _TransientFailure(event.error);
        }
        buffer.forEach(out.push);
        out.push(event);
        return const _Forwarded();
      case StartEvent():
        buffer.add(event);
      default:
        // Any content event commits the attempt.
        committed = true;
        buffer.forEach(out.push);
        out.push(event);
    }
  }
  // The stream closed without a terminal event: flush what we held.
  buffer.forEach(out.push);
  return const _Forwarded();
}
