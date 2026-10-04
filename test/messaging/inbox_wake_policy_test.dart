import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The idle inbox-wake lane policy (gh-1180): user-kind mail always wakes;
/// scheduled self-mail is exempt from the chatter cap; foreign chatter
/// stays capped (anti-storm REG); a busy-spin disguised as self-scheduling
/// is bounded like chatter (E5).
void main() {
  AgentMessage mail(
    String id, {
    String from = 'peer/main',
    String to = 'me/main',
    String text = 'hello',
    AgentMessageKind kind = AgentMessageKind.agent,
  }) => AgentMessage(
    id: id,
    fromId: from,
    toId: to,
    text: text,
    kind: kind,
    sentAt: DateTime.now().toUtc().toIso8601String(),
  );

  /// What the scheduler's `_deliverDueInner` produces for a self-record.
  AgentMessage scheduledSelf(String id) => mail(
    id,
    from: 'me/main',
    to: 'me/main',
    text: '[scheduled] night-watch sweep',
  );

  test('AC1: a self-chain wakes forever — 25 consecutive fires, the exempt '
      'wake never touches the streak (cap is 10)', () async {
    final policy = InboxWakePolicy(scheduledSelfCadenceFloor: Duration.zero);
    for (var fire = 1; fire <= 25; fire++) {
      final decision = policy.wakeDecisionFor([scheduledSelf('m$fire')]);
      expect(decision.wake, isTrue, reason: 'fire $fire must wake');
      expect(decision.lane, InboxWakeLane.scheduledSelf);
      expect(
        decision.countsAgainstCap,
        isFalse,
        reason: 'fire $fire must not consume the chatter cap',
      );
      expect(
        policy.streak,
        0,
        reason: 'the exempt lane must leave the streak untouched',
      );
    }
  });

  test('AC2 REG: foreign agent chatter is capped at 10 consecutive wakes — '
      '15 wakes produce 10 turns and 5 refusals with a reason', () async {
    final policy = InboxWakePolicy();
    var turns = 0;
    var refusals = 0;
    var lastReason = '';
    for (var fire = 1; fire <= 15; fire++) {
      final decision = policy.wakeDecisionFor([mail('f$fire')]);
      if (decision.wake) {
        turns++;
        expect(decision.lane, InboxWakeLane.chatter);
      } else {
        refusals++;
        lastReason = decision.refusalReason ?? '';
      }
    }
    expect(turns, 10);
    expect(refusals, 5);
    expect(lastReason, isNotEmpty);
  });

  test('AC3: user-kind mail always wakes — even with the streak exhausted — '
      'and the reset lets capped chatter flow again', () async {
    final policy = InboxWakePolicy();
    // Burn the cap on foreign chatter.
    for (var fire = 0; fire < 10; fire++) {
      expect(policy.wakeDecisionFor([mail('f$fire')]).wake, isTrue);
    }
    expect(policy.wakeDecisionFor([mail('f-more')]).wake, isFalse);
    // User input: always wakes, never blocked by the counter.
    final user = policy.wakeDecisionFor([
      mail('u1', kind: AgentMessageKind.user),
    ]);
    expect(user.wake, isTrue);
    expect(user.lane, InboxWakeLane.userInput);
    expect(user.countsAgainstCap, isFalse);
    // The delivery resets the streak (the host calls this on drain).
    policy.resetStreak();
    expect(policy.wakeDecisionFor([mail('f-after')]).wake, isTrue);
  });

  test('E5: a storm disguised as self-scheduling (0-delay re-schedule loop) '
      'is bounded — rapid self-wakes count against the cap, and the lane '
      'recovers at a deliberate cadence', () async {
    // Real-clock policy: consecutive calls land microseconds apart —
    // far inside the 30s cadence floor — exactly a 0-delay spin.
    final policy = InboxWakePolicy();
    var turns = 0;
    var refused = false;
    for (var fire = 0; fire < 25 && !refused; fire++) {
      final decision = policy.wakeDecisionFor([scheduledSelf('s$fire')]);
      if (decision.wake) {
        turns++;
        expect(decision.lane, InboxWakeLane.scheduledSelf);
      } else {
        refused = true;
        expect(decision.refusalReason, isNotNull);
      }
    }
    expect(refused, isTrue, reason: 'a spin must hit the bound');
    // 10 capped wakes + the startup grace: the FIRST self wake has no
    // cadence history, so it cannot yet be judged a spin.
    expect(turns, 11, reason: 'the spin is bounded like chatter');
    expect(policy.streak, 10);
    // A deliberate cadence (>= floor since the last self wake) is exempt
    // again: a policy whose clock jumps past the floor between wakes.
    var now = DateTime.utc(2026, 10, 3, 12);
    final cadenced = InboxWakePolicy(clock: () => now);
    expect(cadenced.wakeDecisionFor([scheduledSelf('a')]).wake, isTrue);
    now = now.add(const Duration(minutes: 10));
    expect(cadenced.wakeDecisionFor([scheduledSelf('b')]).wake, isTrue);
  });

  test('the cadence floor is host-tunable: zero collapses it (every self wake '
      'exempt) — the knob tests use it to model long chains', () async {
    final policy = InboxWakePolicy(scheduledSelfCadenceFloor: Duration.zero);
    for (var fire = 0; fire < 30; fire++) {
      expect(policy.wakeDecisionFor([scheduledSelf('s$fire')]).wake, isTrue);
    }
  });

  test('isScheduledSelfMail matches only the scheduler shape: own mailbox '
      'sender AND the [scheduled] prefix — foreign chatter with either '
      'alone is still chatter', () async {
    expect(InboxWakePolicy.isScheduledSelfMail(scheduledSelf('x')), isTrue);
    expect(
      InboxWakePolicy.isScheduledSelfMail(mail('y', text: '[scheduled] spoof')),
      isFalse,
      reason: 'foreign sender with the prefix is NOT self-mail',
    );
    expect(
      InboxWakePolicy.isScheduledSelfMail(mail('z', from: 'me/main')),
      isFalse,
      reason: 'own sender without the prefix is NOT self-mail',
    );
    // A subagent mailbox chain (gh-970): the child addressing itself is
    // self-mail for THAT mailbox pair.
    expect(
      InboxWakePolicy.isScheduledSelfMail(
        mail('c', from: 'me/child-1', to: 'me/child-1', text: '[scheduled] x'),
      ),
      isTrue,
    );
  });

  test('mixed batches: a user message anywhere in the pending batch wins '
      '(user lane, always wakes)', () async {
    final policy = InboxWakePolicy();
    for (var fire = 0; fire < 10; fire++) {
      policy.wakeDecisionFor([mail('f$fire')]);
    }
    final decision = policy.wakeDecisionFor([
      mail('chat'),
      mail('u9', kind: AgentMessageKind.user),
      scheduledSelf('self'),
    ]);
    expect(decision.wake, isTrue);
    expect(decision.lane, InboxWakeLane.userInput);
  });

  test('plugin-only pending is its own lane — capped like chatter, named '
      'for the receipts (the contract is code, not a folded accident)', () {
    final policy = InboxWakePolicy();
    for (var fire = 0; fire < 10; fire++) {
      final decision = policy.wakeDecisionFor(const [], pluginPending: true);
      expect(decision.wake, isTrue);
      expect(decision.lane, InboxWakeLane.plugin);
    }
    final refused = policy.wakeDecisionFor(const [], pluginPending: true);
    expect(refused.wake, isFalse, reason: 'plugin mail rides the same cap');
    expect(refused.lane, InboxWakeLane.plugin);
    // A mixed batch is decided by its fabric messages, never by the flag.
    final mixed = policy.wakeDecisionFor([
      mail('u1', kind: AgentMessageKind.user),
    ], pluginPending: true);
    expect(mixed.lane, InboxWakeLane.userInput);
    expect(mixed.wake, isTrue);
  });

  test('refusal episodes: one announcement per episode, and a user-input '
      'reset RE-OPENS the episode — the next refusal is visible again', () {
    final policy = InboxWakePolicy();
    for (var fire = 0; fire < 10; fire++) {
      expect(policy.wakeDecisionFor([mail('f$fire')]).wake, isTrue);
    }
    final held = [mail('held')];
    expect(policy.wakeDecisionFor(held).wake, isFalse);
    // Episode 1 opens: the host announces + receipts once…
    expect(policy.claimRefusalAnnouncement(held), isTrue);
    // …the same batch re-firing on every watcher tick stays silent.
    expect(policy.claimRefusalAnnouncement(held), isFalse);
    // User input resets the streak AND closes the episode: the next
    // refusal must announce + receipt again — the old standalone host
    // flag never was reset, and swallowed the post-input refusal.
    policy.resetStreak();
    // The freshly reset cap must burn again before the gate refuses (in
    // the reported case: a rapid scheduled-self spin did it).
    for (var fire = 0; fire < 10; fire++) {
      expect(policy.wakeDecisionFor([mail('g$fire')]).wake, isTrue);
    }
    expect(policy.wakeDecisionFor(held).wake, isFalse);
    expect(
      policy.claimRefusalAnnouncement(held),
      isTrue,
      reason: 'a new refusal episode must be visible AND receipted',
    );
  });

  test('a NEW pending batch while the gate holds re-opens the announcement '
      '(new mail is new information; a repeated tick is not)', () {
    final policy = InboxWakePolicy();
    for (var fire = 0; fire < 10; fire++) {
      policy.wakeDecisionFor([mail('f$fire')]);
    }
    final held = [mail('held')];
    policy.wakeDecisionFor(held);
    expect(policy.claimRefusalAnnouncement(held), isTrue);
    expect(policy.claimRefusalAnnouncement(held), isFalse);
    expect(
      policy.claimRefusalAnnouncement([mail('held'), mail('more')]),
      isTrue,
      reason: 'new mail arriving under the gate is worth a fresh row',
    );
  });
}
