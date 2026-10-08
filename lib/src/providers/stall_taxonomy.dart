/// Stall taxonomy (gh-1395): NAMES the alive-but-silence classes a provider
/// stream can die with, so the trace, the payload capture, and the recovery
/// policy all speak about the SAME failure instead of an undifferentiated
/// timeout.
///
/// The empirical refutation table (issue #1395) pinned the classes against
/// the real production stack:
///
/// - [ProviderStallKind.connectStall] — the request is sent, headers NEVER
///   arrive, the socket is open (or connecting): the connect watchdog kills
///   it (`connectWatchdogTag`). Distinct watchdog, distinct trace line,
///   distinct policy entry (E1) — a never-started request is already
///   replayed in place by `sendWatchedProviderRequest` and must NOT
///   re-enter the stall ladder.
/// - [ProviderStallKind.firstByteStall] — 200 + headers arrived, the SSE
///   stream opened, ZERO events were decoded, then event-level silence
///   until the idle watchdog fires (the bench's 300 s quantization
///   signature, scenario B1 pre-event).
/// - [ProviderStallKind.midStreamIdleStall] — at least one event was
///   decoded, then silence (a wedged gateway or a >5-min upstream
///   generation gap — scenario B1 post-event).
///
/// Classification matches TAG constants, never ad-hoc substrings: the
/// producer watchdogs build their error texts with the same constants this
/// file matches (the `connectWatchdogTag` discipline from issue #1121's
/// review — a rewording cannot silently drop a stall class out of the
/// taxonomy).
///
/// Internal to the package (exported through the barrel for hosts that
/// want to render stall kinds); no I/O, pure classification.
library;

import 'transient_retry_stream.dart' show connectWatchdogTag;

/// The structural tag both idle watchdogs build their errors with:
/// `createSseIterator` (`provider_common.dart`) and the chatgpt-codex
/// bypass both end their TimeoutException messages with
/// `(stream idle timeout)`. The taxonomy matches [idleStreamStallTag];
/// the tag pins the wording of all producers and consumers together.
const String idleStreamStallTag = '(stream idle timeout)';

/// The kinds of alive-but-silence a provider stream dies with (gh-1395).
enum ProviderStallKind {
  /// Headers never arrived — the connect watchdog fired (scenario B3).
  /// Already handled by the in-place connect-stall replay
  /// (`sendWatchedProviderRequest`); the SilentStreamPolicy does NOT
  /// ladder it again (E1: distinct policy entries).
  connectStall,

  /// Headers arrived, the stream opened, zero events were decoded, then
  /// event-level silence until the idle watchdog fired (B1 pre-event).
  firstByteStall,

  /// At least one event was decoded, then event-level silence (B1
  /// post-event — the wedged-gateway / long-generation-gap class).
  midStreamIdleStall,
}

/// One classified stall: the named kind plus what was known when the
/// watchdog fired. Produced by [classifyProviderStall]; carried into
/// ConnTrace lines, StallSentinel dumps, and the SilentStreamPolicy ledger
/// so every surface names the stall identically.
final class ProviderStallEvent {
  /// Creates a stall record.
  const ProviderStallEvent({
    required this.kind,
    required this.message,
    this.eventsSeen,
    this.idleSeconds,
  });

  /// The named stall class.
  final ProviderStallKind kind;

  /// The raw error text the watchdog produced (verbatim — the diagnostic
  /// contract the ladders classify on).
  final String message;

  /// How many SSE events were decoded before the silence, when the caller
  /// knows (`null` = unknown, e.g. a connect stall has no events by
  /// definition).
  final int? eventsSeen;

  /// The idle budget that was in effect when the watchdog fired, when the
  /// error text carries one (the `300s` in `(stream idle timeout)`).
  final int? idleSeconds;

  /// Human label for trace lines and notices (`connect stall`,
  /// `first-byte stall`, `mid-stream idle stall`).
  String get label => switch (kind) {
    ProviderStallKind.connectStall => 'connect stall',
    ProviderStallKind.firstByteStall => 'first-byte stall',
    ProviderStallKind.midStreamIdleStall => 'mid-stream idle stall',
  };

  @override
  String toString() =>
      'ProviderStallEvent($label'
      '${idleSeconds == null ? '' : ', idle ${idleSeconds}s'}'
      '${eventsSeen == null ? '' : ', $eventsSeen events'})';
}

/// The seconds figure in an idle-watchdog wording (`for 300s`), or null.
final RegExp _idleSecondsPattern = RegExp(r'for (\d+)s');

/// Classifies an error message into a [ProviderStallEvent], or `null` when
/// the failure is NOT the stall family (transport drops, 5xx, rate limits,
/// auth — they belong to the existing ladders, E1's distinct policy
/// entries).
///
/// [eventsSeen] is how many SSE events the caller observed before the
/// failure: it splits the idle-watchdog wording into first-byte vs
/// mid-stream stall.
ProviderStallEvent? classifyProviderStall(
  String? errorMessage, {
  int? eventsSeen,
}) {
  if (errorMessage == null || errorMessage.isEmpty) return null;
  if (errorMessage.contains(connectWatchdogTag)) {
    return ProviderStallEvent(
      kind: ProviderStallKind.connectStall,
      message: errorMessage,
      eventsSeen: null,
    );
  }
  if (errorMessage.contains(idleStreamStallTag)) {
    final seconds = _idleSecondsPattern.firstMatch(errorMessage)?.group(1);
    return ProviderStallEvent(
      kind: (eventsSeen ?? 0) > 0
          ? ProviderStallKind.midStreamIdleStall
          : ProviderStallKind.firstByteStall,
      message: errorMessage,
      eventsSeen: eventsSeen,
      idleSeconds: seconds == null ? null : int.tryParse(seconds),
    );
  }
  return null;
}

/// Whether [errorMessage] is a stall-class failure at all (connect,
/// first-byte, or mid-stream) — the gate the SilentStreamPolicy consults
/// before treating a death as a stall.
bool isProviderStallError(String? errorMessage) =>
    classifyProviderStall(errorMessage) != null;
