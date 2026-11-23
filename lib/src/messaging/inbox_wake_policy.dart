library;

import 'agent_message.dart';
import 'chain_loop_guard.dart';
import 'messaging_config.dart';

/// Why a wake was refused (null when the wake is allowed).
final class InboxWakeDecision {
  const InboxWakeDecision({
    required this.lane,
    required this.wake,
    required this.countsAgainstCap,
    this.refusalReason,
    this.pauseReason,
  });

  /// Which lane the pending batch was classified into.
  final InboxWakeLane lane;

  /// Whether the host may start a turn.
  final bool wake;

  /// Whether an allowed wake consumes one unit of the chatter cap.
  final bool countsAgainstCap;

  /// Why the wake was refused — persisted in the wake receipts.
  final String? refusalReason;

  /// The pause bound that fired (issue #2226): `cap` (the legacy streak),
  /// `loop` / `budget` (the smart chain guard). Receipts distinguish
  /// `wake_refused` (legacy cap) from `chain_paused:<reason>`; hosts use
  /// it to pick the digest card.
  final String? pauseReason;
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

/// The idle inbox-wake lane policy (gh-1180, reworked by issue #2226).
///
/// The hosts' idle inbox watchers (CLI, app) start a turn when mail
/// arrives while idle. Three protections share that gate:
///
/// - the user-input guarantee: mail of kind [AgentMessageKind.user] IS
///   the user talking and must always wake — its delivery resets the
///   streak, so gating it on the counter would deadlock
///   (no run → no reset → no run);
/// - the smart chain guard ([chainGuard], issue #2226): the DEFAULT
///   bound — loop detection (content-similarity + no-progress signals)
///   and an autonomous-chain token budget pause a looping or runaway
///   chain with a user-facing digest, while productive long
///   collaborations (fresh ids/state every round) never trigger;
/// - the LEGACY chatter cap ([maxStreak]): the raw consecutive-wake
///   counter, now **OFF by default** (0) — volume is not looping, and
///   the money-project incident (10 productive exchanges refused) is the
///   pinned regression. A positive `messaging.wakeChatterCap` re-enables
///   the pre-#2226 behavior verbatim.
///
/// gh-1180's third lane: a delivered `schedule_message` self-reminder
/// (`[scheduled] ` prefix, from == to == the recipient's own mailbox) is
/// a DELIBERATE, agent-chosen cadence — a night watch, a periodic sweep,
/// a delayed follow-up — not chatter. It is EXEMPT from every bound so a
/// self-chain wakes forever, with one guard when the legacy cap is on:
/// wakes arriving faster than [scheduledSelfCadenceFloor] are a
/// busy-spin disguised as self-scheduling (a zero-delay re-schedule
/// loop) and count against the ordinary cap, bounding the storm exactly
/// like foreign chatter. With the cap OFF (default) the spin is bounded
/// by the chain guard's budget instead.
final class InboxWakePolicy {
  InboxWakePolicy({
    this.maxStreak = defaultMaxInboxWakeStreak,
    this.scheduledSelfCadenceFloor = defaultScheduledSelfCadenceFloor,
    this.chainGuard,
    this.clock,
  });

  /// The one construction from a `messaging:` section (issue #2226): the
  /// guard rides [chainGuard], the legacy cap from `wakeChatterCap`.
  factory InboxWakePolicy.forConfig(
    MessagingConfig config,
    ChainLoopGuard guard,
  ) => InboxWakePolicy(maxStreak: config.wakeChatterCap, chainGuard: guard);

  /// The legacy anti-storm cap for foreign agent-to-agent chatter.
  /// `0` (the issue #2226 default) disables the cap entirely; hosts
  /// wire `messaging.wakeChatterCap` here (10 was the pre-#2226 value).
  static const int defaultMaxInboxWakeStreak = 0;

  /// Wakes closer together than this are a spin, not a cadence (gh-1180
  /// E5): the exemption must not open a busy-spin.
  static const Duration defaultScheduledSelfCadenceFloor = Duration(
    seconds: 30,
  );

  /// Consecutive chatter wakes allowed without user input. `0` (the
  /// issue #2226 default) disables the cap — [chainGuard] is the bound.
  final int maxStreak;

  /// The smart chain guard (issue #2226): loop detection + the
  /// autonomous-chain token budget. Null keeps bare cap gating (and no
  /// bound at all when [maxStreak] is 0). The guard rides THIS policy's
  /// user-input reset so the two cannot drift apart.
  final ChainLoopGuard? chainGuard;

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
  /// The chain guard resets with it (issue #2226: the human is watching —
  /// streaks reset, the budget re-arms, pause verdicts clear).
  void resetStreak() {
    streak = 0;
    _refusalAnnounced = false;
    chainGuard?.resetFromUserInput();
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
      // intact — a spin is abuse of the same budget. With the cap OFF
      // (issue #2226 default) the spin is bounded by the chain guard's
      // budget instead, not here.
      if (maxStreak > 0 && streak >= maxStreak) {
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
    // fabric mail pending, see [pluginPending]): the smart chain guard
    // first (issue #2226 — the loop verdict / budget exhaustion pause
    // with a digest, never booking the streak), then the LEGACY cap
    // (default 0 = off; positive `messaging.wakeChatterCap` re-enables).
    final pause = chainGuard?.evaluate(pending);
    if (pause != null) {
      return InboxWakeDecision(
        lane: InboxWakeLane.chatter,
        wake: false,
        countsAgainstCap: false,
        refusalReason: pause.evidence,
        pauseReason: pause.reason.name,
      );
    }
    if (maxStreak > 0 && streak >= maxStreak) {
      return InboxWakeDecision(
        lane: InboxWakeLane.chatter,
        wake: false,
        countsAgainstCap: true,
        refusalReason:
            'inbox-wake streak cap reached ($streak consecutive '
            'agent-kind wakes without user input) — mail stays queued '
            'until the next user input',
        pauseReason: 'cap',
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
