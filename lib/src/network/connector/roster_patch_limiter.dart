// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The coalescing rate limiter for `PATCH /api/devices/{deviceId}/roster`
/// — the ONE writer both roster hosts ([NetworkPresenceController] and
/// [MultiSessionConnectorHost]) share (contract
/// `docs/fa_network_connector.md` §5/§9).
///
/// Why it exists (production "eviction storm"): fa_network admits 60
/// roster PATCHes per minute per device, while N CLI processes on one
/// machine used to patch on a bare 500 ms debounce after every reconnect —
/// full-catalog bodies at ~120/min, 500+ HTTP 429s, with no 429 handling
/// anywhere. Rules encoded here:
/// - **budget**: two PATCHes of one device process never start closer than
///   [minInterval] (default [rosterPatchMinInterval], 2 s ⇒ ≤ 30/min, half
///   the server limit). Every page of a large catalog spends a slot.
/// - **coalescing**: [enqueue] merges entries by key (latest wins) behind a
///   [debounce] window, so bursts collapse into one PATCH.
/// - **throttle**: a 429 / `throttled` answer puts the refused batch back
///   (merged under newer pending changes — never dropped) and waits the
///   server's `Retry-After`, or a jittered exponential backoff
///   ([rosterThrottleBackoff]) when it sent none; a timer retries.
/// - **shutdown**: [close] cancels every timer; [flush] never waits out a
///   throttle cooldown, only the ≤ [minInterval] budget slot.
///
/// Pure Dart: no `dart:io`, no Flutter. Time rides the presence-engine
/// seams ([ConnectorClock]/[ConnectorTimers]) so the budget is unit-tested
/// as numbers on a fake clock.
library;

import 'dart:async';
import 'dart:math' show Random, min;

import '../../session/session_catalog.dart' show sessionCatalogRosterPageSize;
import 'device_api.dart';
import 'presence_engine.dart'
    show
        ConnectorClock,
        ConnectorTimer,
        ConnectorTimers,
        SystemClock,
        SystemTimers;
import 'rate_backoff.dart';

/// Coalescing window between a change and its flush (the legacy
/// `rosterDebounce`): repeated changes inside it collapse into one PATCH.
const rosterPatchDebounce = Duration(milliseconds: 500);

/// Minimum spacing of two roster PATCHes from ONE device process: 2 s ⇒
/// ≤ 30/min, half of fa_network's 60/min/device limit, so sibling CLI
/// processes on the same enrolled device cannot drain the budget together.
const rosterPatchMinInterval = Duration(seconds: 2);

/// First step of the throttle backoff when a 429 carries no `Retry-After`.
const rosterThrottleBackoffBase = Duration(seconds: 5);

/// Ceiling of the throttle backoff (the server's window is one minute).
const rosterThrottleBackoffCap = Duration(seconds: 60);

/// Backoff after the [streak]-th (1-based) consecutive throttled PATCH:
/// [rosterThrottleBackoffBase] doubling up to [rosterThrottleBackoffCap],
/// with equal jitter.
Duration rosterThrottleBackoff(int streak, double jitterFraction) {
  final step = min((streak < 1 ? 1 : streak) - 1, 16);
  final nominal = Duration(
    milliseconds: rosterThrottleBackoffBase.inMilliseconds * (1 << step),
  );
  return withEqualJitter(
    nominal > rosterThrottleBackoffCap ? rosterThrottleBackoffCap : nominal,
    jitterFraction,
  );
}

/// The cooldown after the [streak]-th consecutive throttled PATCH: the
/// jittered ladder step, or the server's `Retry-After` when it asked for
/// LONGER. A throttle hint is a floor, never a shortcut (the rule of
/// `upstreamRetryDelay`): a zero or sub-ladder hint must not keep the
/// device patching at the full budget cadence under a continuous 429.
Duration rosterThrottleDelay(
  int streak,
  double jitterFraction, {
  Duration? retryAfter,
}) {
  final ladder = rosterThrottleBackoff(streak, jitterFraction);
  if (retryAfter == null || retryAfter <= ladder) return ladder;
  return retryAfter;
}

/// One serialized roster writer: pending agents/sessions by key, the
/// debounce timer, the budget/cooldown bookkeeping and the retry timer.
final class RosterPatchLimiter {
  /// Builds a limiter for one device. [client] null keeps it inert
  /// ([isEnabled] false — embedders without the REST projection).
  RosterPatchLimiter({
    required this.baseUrl,
    required this.deviceId,
    required this.deviceToken,
    this.client,
    this.debounce = rosterPatchDebounce,
    this.minInterval = rosterPatchMinInterval,
    double Function()? jitterFraction,
    ConnectorClock? clock,
    ConnectorTimers? timers,
    this.onLog,
  }) : _jitter = jitterFraction ?? Random().nextDouble,
       _clock = clock ?? const SystemClock(),
       _timers = timers ?? const SystemTimers();

  /// fa_network REST root.
  final String baseUrl;

  /// The enrolled device whose roster is patched.
  final String deviceId;

  /// Device bearer — never logged.
  final String deviceToken;

  /// The roster REST client; null disables the limiter.
  final DeviceEnrollmentClient? client;

  /// Coalescing window for a burst of changes.
  final Duration debounce;

  /// Minimum spacing of two PATCHes (the per-device budget).
  final Duration minInterval;

  /// Soft diagnostics sink (null = drop); never receives secrets.
  final void Function(String message)? onLog;

  final double Function() _jitter;
  final ConnectorClock _clock;
  final ConnectorTimers _timers;

  final _pendingAgents = <String, DeviceRosterAgent>{};
  final _pendingSessions = <String, DeviceRosterSession>{};
  final _budgetWaits = <void Function()>[];
  Future<void> _writes = Future<void>.value();
  ConnectorTimer? _debounceTimer;
  ConnectorTimer? _throttleRetryTimer;
  DateTime? _lastPatchAt;
  DateTime? _notBefore;
  int _throttleStreak = 0;
  int _patchCount = 0;
  bool _closed = false;

  /// Whether a roster client is wired (false ⇒ [enqueue] is a no-op).
  bool get isEnabled => client != null;

  /// PATCH requests sent so far, successful or refused (assertion seam).
  int get patchCount => _patchCount;

  /// Entries waiting for the next budget slot (assertion seam).
  int get pendingCount => _pendingAgents.length + _pendingSessions.length;

  /// Whether a refused PATCH put the device in a cooldown.
  bool get inThrottleCooldown =>
      _notBefore != null && _clock.now().isBefore(_notBefore!);

  /// Merges [agents]/[sessions] into the pending set (latest entry per
  /// agent name / session id wins) and schedules one debounced flush.
  void enqueue({
    List<DeviceRosterAgent> agents = const [],
    List<DeviceRosterSession> sessions = const [],
  }) {
    if (!isEnabled || _closed) return;
    for (final agent in agents) {
      _pendingAgents[agent.name] = agent;
    }
    for (final session in sessions) {
      _pendingSessions[session.id] = session;
    }
    _debounceTimer?.cancel();
    _debounceTimer = _timers.delayed(debounce, () {
      _debounceTimer = null;
      unawaited(flush());
    });
  }

  /// Drains the pending set as soon as the per-device budget allows — the
  /// stop-path/unregister seam: skips the debounce, waits at most one
  /// budget slot (≤ [minInterval]), and never waits out a throttle
  /// cooldown (the armed retry timer owns that). Serialized: at most one
  /// PATCH is in flight per limiter. Never throws.
  Future<void> flush() {
    if (_closed) return Future<void>.value();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final run = _writes.then((_) => _drain());
    _writes = run;
    return run;
  }

  /// Cancels the debounce, the throttle retry and any budget wait. Pending
  /// changes are dropped (the process is going away). Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _throttleRetryTimer?.cancel();
    _throttleRetryTimer = null;
    for (final finish in List.of(_budgetWaits)) {
      finish();
    }
  }

  Future<void> _drain() async {
    final client = this.client;
    if (client == null) return;
    while (!_closed && pendingCount > 0) {
      if (inThrottleCooldown) {
        _armThrottleRetry();
        return;
      }
      await _waitForBudget();
      if (_closed) return;
      final pages = _takePendingPages();
      if (!await _sendPages(client, pages)) return;
    }
  }

  /// Sends every page (one budget slot each); false = stop this drain —
  /// throttled (retry armed) or failed (left pending for the next trigger).
  Future<bool> _sendPages(
    DeviceEnrollmentClient client,
    List<RosterPatchPage> pages,
  ) async {
    for (var i = 0; i < pages.length; i++) {
      if (i > 0) {
        await _waitForBudget();
        if (_closed) {
          _mergeBack(pages, i);
          return false;
        }
      }
      try {
        _lastPatchAt = _clock.now();
        _patchCount++;
        await client.patchRoster(
          baseUrl: baseUrl,
          deviceId: deviceId,
          deviceToken: deviceToken,
          agents: pages[i].agents,
          sessions: pages[i].sessions,
        );
        _throttleStreak = 0;
      } on Object catch (error) {
        _mergeBack(pages, i);
        return _onPatchRefused(error);
      }
    }
    return true;
  }

  /// A refused PATCH: the refused remainder is already merged back under
  /// newer pending changes; a throttle starts the cooldown + retry, any
  /// other failure is best-effort and waits for the next change.
  bool _onPatchRefused(Object error) {
    if (error is! ConnectorThrottleSignal) {
      onLog?.call('device roster patch failed');
      return false;
    }
    _throttleStreak++;
    final delay = rosterThrottleDelay(
      _throttleStreak,
      _jitter(),
      retryAfter: error.retryAfter,
    );
    _notBefore = _clock.now().add(delay);
    onLog?.call(
      'device roster patch throttled (429); retrying in ${delay.inSeconds} s',
    );
    _armThrottleRetry();
    return false;
  }

  void _armThrottleRetry() {
    if (_closed || _throttleRetryTimer != null) return;
    final remaining = _notBefore?.difference(_clock.now()) ?? Duration.zero;
    _throttleRetryTimer = _timers.delayed(
      remaining < Duration.zero ? Duration.zero : remaining,
      () {
        _throttleRetryTimer = null;
        unawaited(flush());
      },
    );
  }

  /// Resolves when the next PATCH may start: the previous one is at least
  /// [minInterval] old. [close] finishes an open wait at once.
  Future<void> _waitForBudget() {
    final last = _lastPatchAt;
    final wait = last == null
        ? Duration.zero
        : last.add(minInterval).difference(_clock.now());
    if (wait <= Duration.zero) return Future<void>.value();
    final done = Completer<void>();
    ConnectorTimer? timer;
    void finish() {
      timer?.cancel();
      _budgetWaits.remove(finish);
      if (!done.isCompleted) done.complete();
    }

    _budgetWaits.add(finish);
    timer = _timers.delayed(wait, finish);
    return done.future;
  }

  /// Takes the whole pending set as PATCH pages: agents ride the first
  /// page, sessions chunk by [sessionCatalogRosterPageSize].
  List<RosterPatchPage> _takePendingPages() {
    final agents = _pendingAgents.values.toList(growable: false);
    final sessions = _pendingSessions.values.toList(growable: false);
    _pendingAgents.clear();
    _pendingSessions.clear();
    if (sessions.isEmpty) return [RosterPatchPage(agents, const [])];
    return [
      for (
        var start = 0;
        start < sessions.length;
        start += sessionCatalogRosterPageSize
      )
        RosterPatchPage(
          start == 0 ? agents : const [],
          sessions.sublist(
            start,
            (start + sessionCatalogRosterPageSize).clamp(0, sessions.length),
          ),
        ),
    ];
  }

  /// Puts the unsent pages [from].. back into the pending set WITHOUT
  /// overriding newer changes enqueued meanwhile (those win).
  void _mergeBack(List<RosterPatchPage> pages, int from) {
    for (final page in pages.skip(from)) {
      for (final agent in page.agents) {
        _pendingAgents.putIfAbsent(agent.name, () => agent);
      }
      for (final session in page.sessions) {
        _pendingSessions.putIfAbsent(session.id, () => session);
      }
    }
  }
}

/// One `PATCH …/roster` request body.
final class RosterPatchPage {
  /// Builds a page.
  const RosterPatchPage(this.agents, this.sessions);

  /// Agent rows of this page.
  final List<DeviceRosterAgent> agents;

  /// Session rows of this page.
  final List<DeviceRosterSession> sessions;
}
