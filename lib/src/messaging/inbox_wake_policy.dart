// The constructor params keep their public names (env/path/clock) while
// the fields stay private — same shape as scheduled_messages.dart.
// ignore_for_file: prefer_initializing_formals
library;

import 'agent_message.dart';

/// Why a wake was refused (null when the wake is allowed).
final class InboxWakeDecision {
  const InboxWakeDecision({
    required this.lane,
    required this.wake,
    required this.countsAgainstCap,
    this.refusalReason,
  });

  /// Which lane the pending batch was classified into.
  final InboxWakeLane lane;

  /// Whether the host may start a turn.
  final bool wake;

  /// Whether an allowed wake consumes one unit of the chatter cap.
  final bool countsAgainstCap;

  /// Why the wake was refused — persisted in the wake receipts.
  final String? refusalReason;
}

/// The wake lane a pending batch was classified into (gh-1180).
enum InboxWakeLane {
  /// User input (typed line, attached client, hub user mail): always
  /// wakes; the delivery resets the streak.
  userInput,

  /// A delivered scheduled self-reminder: exempt from the chatter cap,
  /// cadence-floored against a disguised busy-spin.
  scheduledSelf,

  /// Foreign agent-to-agent chatter (or plugin-inbox mail): capped.
  chatter,
}

/// The idle inbox-wake lane policy (gh-1180).
///
/// The hosts' idle inbox watchers (CLI, app) start a turn when mail
/// arrives while idle. Two protections share that gate:
///
/// - the agent-chatter anti-storm cap: at most [maxStreak] consecutive
///   wakes without user input, so two chatty instances cannot ping-pong
///   forever;
/// - the user-input guarantee: mail of kind [AgentMessageKind.user] IS
///   the user talking and must always wake — its delivery resets the
///   streak, so gating it on the counter would deadlock
///   (no run → no reset → no run).
///
/// gh-1180 adds the missing third lane: a delivered `schedule_message`
/// self-reminder (`[scheduled] ` prefix, from == to == the recipient's
/// own mailbox) is a DELIBERATE, agent-chosen cadence — a night watch,
/// a periodic sweep, a delayed follow-up — not chatter. It is EXEMPT
/// from the cap so a self-chain wakes forever, with one guard: wakes
/// arriving faster than [scheduledSelfCadenceFloor] are a busy-spin
/// disguised as self-scheduling (a zero-delay re-schedule loop) and
/// count against the ordinary cap, bounding the storm exactly like
/// foreign chatter.
final class InboxWakePolicy {
  InboxWakePolicy({
    this.maxStreak = defaultMaxInboxWakeStreak,
    this.scheduledSelfCadenceFloor = defaultScheduledSelfCadenceFloor,
    DateTime Function()? clock,
  }) : _clock = clock;

  /// The anti-storm cap for foreign agent-to-agent chatter (unchanged
  /// behavior — the old `_maxInboxWakeStreak`).
  static const int defaultMaxInboxWakeStreak = 10;

  /// Wakes closer together than this are a spin, not a cadence (gh-1180
  /// E5): the exemption must not open a busy-spin.
  static const Duration defaultScheduledSelfCadenceFloor = Duration(
    seconds: 30,
  );

  /// Consecutive chatter wakes allowed without user input.
  final int maxStreak;

  /// Minimum spacing between two EXEMPT scheduled-self wakes; anything
  /// faster counts against the cap. Mutable so a host test can collapse
  /// it (zero: every self wake exempt) or exercise the spin guard.
  Duration scheduledSelfCadenceFloor;

  final DateTime Function()? _clock;

  DateTime _now() => _clock?.call() ?? DateTime.now();

  /// Consecutive inbox-triggered wakes without user input.
  int streak = 0;

  DateTime? _lastScheduledSelfWakeAt;

  /// A delivered user-kind message (or a typed line) IS the user talking.
  void resetStreak() => streak = 0;

  /// Whether [message] is the delivery of a scheduled self-reminder: the
  /// scheduler's `[scheduled] ` prefix addressed from the recipient's own
  /// mailbox (from == to). Foreign chatter cannot produce the shape by
  /// accident — its `fromId` is the sender's mailbox, never mine.
  static bool isScheduledSelfMail(AgentMessage message) =>
      message.fromId == message.toId && message.text.startsWith('[scheduled] ');

  /// Decides — and books — the wake for one pending batch. Call only when
  /// mail is pending and the host is idle; a refused decision leaves the
  /// counters untouched, so the next tick retries under the same rules.
  InboxWakeDecision wakeDecisionFor(
    List<AgentMessage> pending, {
    bool pluginPending = false,
  }) {
    if (pending.any((message) => message.kind == AgentMessageKind.user)) {
      // The delivery resets the streak (_mainInboxMessages / sendText);
      // the wake itself never blocks on it.
      return const InboxWakeDecision(
        lane: InboxWakeLane.userInput,
        wake: true,
        countsAgainstCap: false,
      );
    }
    if (pending.any(isScheduledSelfMail)) {
      final now = _now();
      final last = _lastScheduledSelfWakeAt;
      final rapid =
          last != null && now.difference(last) < scheduledSelfCadenceFloor;
      _lastScheduledSelfWakeAt = now;
      if (!rapid) {
        // A deliberate cadence (>= floor since the last self wake, or the
        // first after startup): exempt forever — the night-watch lane.
        return const InboxWakeDecision(
          lane: InboxWakeLane.scheduledSelf,
          wake: true,
          countsAgainstCap: false,
        );
      }
      // A storm disguised as self-scheduling (gh-1180 E5): bounded like
      // chatter. The shared streak keeps foreign-chatter accounting
      // intact — a spin is abuse of the same budget.
      if (streak >= maxStreak) {
        return InboxWakeDecision(
          lane: InboxWakeLane.scheduledSelf,
          wake: false,
          countsAgainstCap: true,
          refusalReason:
              'scheduled self-mail is arriving faster than the '
              '${scheduledSelfCadenceFloor.inSeconds}s cadence floor with '
              'the chatter cap exhausted (busy-spin guard) — re-schedule '
              'with a slower delay or send user input to reset',
        );
      }
      streak++;
      return InboxWakeDecision(
        lane: InboxWakeLane.scheduledSelf,
        wake: true,
        countsAgainstCap: true,
      );
    }
    // Foreign agent-to-agent chatter (or plugin-inbox mail): the cap.
    if (streak >= maxStreak) {
      return InboxWakeDecision(
        lane: InboxWakeLane.chatter,
        wake: false,
        countsAgainstCap: true,
        refusalReason:
            'inbox-wake streak cap reached ($streak consecutive '
            'agent-kind wakes without user input) — mail stays queued '
            'until the next user input',
      );
    }
    streak++;
    return InboxWakeDecision(
      lane: InboxWakeLane.chatter,
      wake: true,
      countsAgainstCap: true,
    );
  }
}
