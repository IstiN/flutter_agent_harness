/// The shared idle inbox-wake lane policy (gh-1180): user-kind mail
/// always wakes; delivered scheduled self-reminders are exempt from the
/// chatter cap; foreign chatter and plugin-inbox mail stay capped.
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

  /// Plugin-inbox (hub) mail with no fabric message in the batch: neither
  /// user input nor a scheduled cadence — capped exactly like [chatter].
  /// A named lane (not chatter folded by accident) so the receipts name
  /// what actually held the gate.
  plugin,

  /// Foreign agent-to-agent chatter: capped.
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
    this._clock,
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

  final DateTime Function()? _clock;

  DateTime _now() => _clock?.call() ?? DateTime.now();

  /// Consecutive inbox-triggered wakes without user input.
  int streak = 0;

  /// One visible refusal per episode: the gate holds until user input
  /// arrives or a wake succeeds, so a host announcing on every watcher
  /// tick would spam the terminal AND the receipt trail (gh-1180 review:
  /// ~43k duplicate lines/day for a weekend-long refusal). The latch
  /// lives HERE, next to the streak it mirrors, so the two cannot drift:
  /// [resetStreak] (every user-input path) closes the episode and the
  /// next refusal is announced and receipted again — the old
  /// standalone host flag never was, and a post-reset refusal could be
  /// silent AND unreceipted.
  bool _refusalAnnounced = false;

  /// The pending-batch ids the open refusal episode was announced for:
  /// the same batch re-firing on every tick stays silent, but new mail
  /// arriving while the gate holds re-opens the announcement — a new
  /// batch is new information for the post-mortem.
  String _announcedBatchIds = '';

  DateTime? _lastScheduledSelfWakeAt;

  /// A delivered user-kind message (or a typed line) IS the user talking.
  /// Also closes any open refusal episode: the next refusal must be
  /// announced (and receipted) again.
  void resetStreak() {
    streak = 0;
    _refusalAnnounced = false;
  }

  /// Whether [pending] still needs its refusal announced and receipted:
  /// true when no episode is open, or when the batch changed since the
  /// last announcement. Claims the announcement — the host prints its
  /// terminal line and appends the receipts right after.
  bool claimRefusalAnnouncement(List<AgentMessage> pending) {
    final ids = [for (final message in pending) message.id].join(',');
    if (_refusalAnnounced && ids == _announcedBatchIds) return false;
    _refusalAnnounced = true;
    _announcedBatchIds = ids;
    return true;
  }

  /// Whether [message] is the delivery of a scheduled self-reminder: the
  /// scheduler's `[scheduled] ` prefix addressed from the recipient's own
  /// mailbox (from == to). Foreign chatter cannot produce the shape by
  /// accident — its `fromId` is the sender's mailbox, never mine.
  ///
  /// Strict equality on purpose: the policy never guesses ownership from
  /// prefixes. A self-record re-addressed across a session-id change
  /// keeps the shape because the queue rewrites the stale pinned sender
  /// alongside the target (`_deliverDueInner`) — the reminder is FROM the
  /// session itself, so the resumed chain stays on this exempt lane.
  static bool isScheduledSelfMail(AgentMessage message) =>
      message.fromId == message.toId && message.text.startsWith('[scheduled] ');

  /// Decides — and books — the wake for one pending batch. Call only when
  /// mail is pending and the host is idle; a refused decision leaves the
  /// counters untouched, so the next tick retries under the same rules.
  ///
  /// [pluginPending]: a plugin inbox (hub) reports pending mail — when
  /// [pending] itself is empty the batch is classified into
  /// [InboxWakeLane.plugin] (capped like chatter); with fabric mail
  /// pending the lane is decided by the messages alone.
  InboxWakeDecision wakeDecisionFor(
    List<AgentMessage> pending, {
    bool pluginPending = false,
  }) {
    if (pending.any((message) => message.kind == AgentMessageKind.user)) {
      // The delivery resets the streak (_mainInboxMessages / sendText);
      // the wake itself never blocks on it. A successful non-exempt wake
      // also closes the refusal episode.
      _refusalAnnounced = false;
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
    // Foreign agent-to-agent chatter, or plugin-inbox mail with no fabric
    // message in the batch: the cap (anti-storm).
    final lane = pending.isEmpty && pluginPending
        ? InboxWakeLane.plugin
        : InboxWakeLane.chatter;
    if (streak >= maxStreak) {
      return InboxWakeDecision(
        lane: lane,
        wake: false,
        countsAgainstCap: true,
        refusalReason:
            'inbox-wake streak cap reached ($streak consecutive '
            'agent-kind wakes without user input) — mail stays queued '
            'until the next user input',
      );
    }
    streak++;
    // A successful non-exempt wake closes the refusal episode: the next
    // refusal is announced and receipted again.
    _refusalAnnounced = false;
    return InboxWakeDecision(lane: lane, wake: true, countsAgainstCap: true);
  }
}
