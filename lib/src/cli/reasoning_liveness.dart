/// The reasoning-phase liveness line (gh-1198, tier 2): the headless/
/// line-mode console heartbeat for a provider request that streams
/// NOTHING — the analog of the per-call tool liveness (`⏳ [bash] …
/// running Ns`, gh-1055), which covers tool waits only. Reasoning models
/// can sit minutes before the first stream event; without a line, that
/// window reads as a hang in CI/ssh logs.
///
/// While a provider request is in flight and has produced no events yet,
/// the tracker (one instance per CLI host) evaluates on the waiting
/// cadence: past `waiting.toolLivenessSeconds` every tick prints ONE
/// grep-friendly `… reasoning Ns` line; the watch disarms the moment the
/// first event lands (the run is visibly moving) and re-arms per request.
///
/// One clock only: every elapsed value derives from the host's
/// waiting-clock seam — the same `waitingClock` the #450 waiting layer and
/// the gh-1055 tool liveness use. The class is transport-free; the host
/// (CLI) wires the print sink through [ReasoningLivenessTracker.onRemind].
library;

import 'dart:async';

import 'tool_liveness.dart';

/// The pinned line format (gh-1198 AC4): `… reasoning Ns` — single line,
/// elapsed seconds, grep anchor `… reasoning`.
String reasoningLivenessLine(int elapsedSeconds) =>
    '… reasoning ${elapsedSeconds}s';

/// Watches the provider-side reasoning window (request sent → first
/// event) and fires the liveness lines.
///
/// One-shot timer chain, not [Timer.periodic] — the cadence getter is read
/// every leg so a config change applies at the next tick, and the chain
/// disarms the moment the watch clears. Transport-free.
final class ReasoningLivenessTracker {
  ReasoningLivenessTracker({
    required void Function(int elapsedSeconds) onRemind,
    int Function()? livenessSeconds,
    int Function()? tickSeconds,
    DateTime Function()? clock,
  }) : _onRemind = onRemind,
       _livenessSeconds = livenessSeconds ?? (() => defaultToolLivenessSeconds),
       _tickSeconds = tickSeconds ?? (() => defaultToolLivenessTickSeconds),
       _clock = clock ?? DateTime.now;

  final void Function(int elapsedSeconds) _onRemind;
  final int Function() _livenessSeconds;
  final int Function() _tickSeconds;
  final DateTime Function() _clock;

  /// When the watched request went out — null when nothing is watched.
  DateTime? _since;

  Timer? _timer;

  /// True while a provider request is being watched (no events yet).
  bool get armed => _since != null;

  /// A provider request went out: begin watching its silent window. Arms
  /// over a stale watch (a new request restarts the elapsed base — the
  /// old request is over).
  void requestStarted() {
    _since = _clock();
    if (_timer == null) _arm();
  }

  /// The first event landed (or the request ended): the watch stops —
  /// the run is visibly moving again. A disarm without an arm is a no-op
  /// (host hooks fire on every event; the tracker stays out when the
  /// feature is not active).
  void progress() {
    if (_since == null) return;
    stop();
  }

  /// Disarms the chain (first event landed, or the host is shutting
  /// down).
  void stop() {
    _since = null;
    _timer?.cancel();
    _timer = null;
  }

  /// One evaluation now: fire the line when the silent window passed the
  /// threshold (`toolLivenessSeconds`; `0` is the kill switch) and re-arm
  /// a full cadence from NOW.
  ///
  /// Mirrors the sibling trackers (ToolLivenessTracker.tick,
  /// WaitingHeartbeat.tick): the pending leg is cancelled first and the
  /// chain re-arms a full cadence from now — the manual seam is
  /// observable and can never double-fire with the production leg. The
  /// production timer legs land here; tests call it directly.
  void tick() {
    _timer?.cancel();
    _timer = null;
    _evaluate();
    if (_since != null) _arm();
  }

  void _evaluate() {
    final since = _since;
    if (since == null) return;
    final remindAfter = _livenessSeconds();
    if (remindAfter <= 0) return;
    final elapsed = _clock().difference(since).inSeconds;
    if (elapsed < remindAfter) return;
    _onRemind(elapsed);
  }

  void _arm() {
    if (_since == null) return;
    final seconds = _tickSeconds();
    if (seconds <= 0) return;
    _timer = Timer(Duration(seconds: seconds), () {
      _timer = null;
      tick();
    });
  }
}
