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

  /// Foreign agent-to-agent chatter, and a plugin-only pending batch (no
  /// fabric mail): capped by the same anti-storm budget.
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
    this.clock,
  });

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

  /// Injectable clock (tests); null uses [DateTime.now].
  final DateTime Function()? clock;

  DateTime _now() => clock?.call() ?? DateTime.now();

  /// Consecutive inbox-triggered wakes without user input.
  int streak = 0;

  bool _refusalAnnounced = false;

  DateTime? _lastScheduledSelfWakeAt;

  /// A delivered user-kind message (or a typed line) IS the user talking.
  /// Ends the refusal episode too (see [announceRefusal]): the two pieces
  /// of episode state live side by side so they cannot drift apart.
  void resetStreak() {
    streak = 0;
    _refusalAnnounced = false;
  }

  /// Whether THIS call may announce the current refusal: true exactly
  /// once per refusal episode. An episode opens on the first refusal and
  /// closes when the gate reopens — a user-input reset ([resetStreak])
  /// or any allowed cap-consuming (non-exempt) wake. Hosts gate their
  /// visible refusal line AND their refusal receipts on this: the gate
  /// holds until user input arrives, so per-tick announcements would
  /// append ~43k duplicate lines/day to the receipt trail (review: the
  /// wake_attempted spam) and spam the terminal.
  bool announceRefusal() {
    if (_refusalAnnounced) return false;
    _refusalAnnounced = true;
    return true;
  }

  /// Whether [message] is the delivery of a scheduled self-reminder: the
  /// scheduler's `[scheduled] ` prefix addressed from the recipient's own
  /// mailbox (from == to). Foreign chatter cannot produce the shape by
  /// accident — its `fromId` is the sender's mailbox, never mine.
  static bool isScheduledSelfMail(AgentMessage message) =>
      message.fromId == message.toId && message.text.startsWith('[scheduled] ');

  /// Decides — and books — the wake for one pending batch. Call only when
  /// mail is pending and the host is idle; a refused decision leaves the
  /// counters untouched, so the next tick retries under the same rules.
  ///
  /// [pluginPending] classifies a PLUGIN-ONLY batch (an empty [pending]
  /// with a pending plugin-inbox item) as [InboxWakeLane.chatter]: plugin
  /// mail rides the same anti-storm budget as fabric chatter. The flag is
  /// IGNORED when [pending] is non-empty — the fabric lanes own that
  /// classification — so passing it alongside real mail changes nothing.
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
      _refusalAnnounced = false;
      return InboxWakeDecision(
        lane: InboxWakeLane.scheduledSelf,
        wake: true,
        countsAgainstCap: true,
      );
    }
    // Foreign agent-to-agent chatter — and a PLUGIN-ONLY batch (no
    // fabric mail pending, see [pluginPending]): the cap.
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
    _refusalAnnounced = false;
    return InboxWakeDecision(
      lane: InboxWakeLane.chatter,
      wake: true,
      countsAgainstCap: true,
    );
  }
}
