/// Unit tests for the per-call foreground liveness layer (gh-1055): the
/// `waiting:` yaml knobs, the tracker lifecycle (thresholds, cadence,
/// exactly-once escalation per stuck call), and the pure line formatters.
///
/// The tracker is transport-free (the host wires the print + clock), the
/// same seam shape as [WaitingHeartbeat] for issue #450.
library;

import 'package:flutter_agent_harness/src/cli/tool_liveness.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:test/test.dart';

void main() {
  group('WaitingConfig liveness knobs', () {
    test('defaults: 60s start, 60s tick, 300s escalation', () {
      const config = WaitingConfig();
      expect(config.toolLivenessSeconds, defaultToolLivenessSeconds);
      expect(config.toolLivenessTickSeconds, defaultToolLivenessTickSeconds);
      expect(config.toolEscalateSeconds, defaultToolEscalateSeconds);
      expect(config.toolLivenessSeconds, 60);
      expect(config.toolLivenessTickSeconds, 60);
      expect(config.toolEscalateSeconds, 300);
    });

    test('fromYaml(null) keeps defaults', () {
      final config = WaitingConfig.fromYaml(null);
      expect(config.toolLivenessSeconds, 60);
      expect(config.toolLivenessTickSeconds, 60);
      expect(config.toolEscalateSeconds, 300);
    });

    test('fromYaml parses all five keys', () {
      final config = WaitingConfig.fromYaml({
        'waitHeartbeatMinutes': 5,
        'waitCeilingMinutes': 10,
        'toolLivenessSeconds': 30,
        'toolLivenessTickSeconds': 45,
        'toolEscalateSeconds': 600,
      });
      expect(config.waitHeartbeatMinutes, 5);
      expect(config.waitCeilingMinutes, 10);
      expect(config.toolLivenessSeconds, 30);
      expect(config.toolLivenessTickSeconds, 45);
      expect(config.toolEscalateSeconds, 600);
    });

    test('fromYaml rejects unknown and negative values', () {
      expect(
        () => WaitingConfig.fromYaml({'toolLivenessSeconds': -1}),
        throwsA(anything),
      );
      expect(
        () => WaitingConfig.fromYaml({'toolEscalateSeconds': -5}),
        throwsA(anything),
      );
      expect(
        () => WaitingConfig.fromYaml({'toolLivenessTickSeconds': 1.5}),
        throwsA(anything),
      );
      expect(() => WaitingConfig.fromYaml({'bogus': 1}), throwsA(anything));
    });

    test('fromYaml rejects an escalation threshold below an enabled liveness '
        'start (the hint is supposed to come at a longer threshold)', () {
      expect(
        () => WaitingConfig.fromYaml({
          'toolLivenessSeconds': 600,
          'toolEscalateSeconds': 120,
        }),
        throwsA(anything),
      );
    });

    test('fromYaml accepts escalate == liveness and 0-disabled sides', () {
      expect(
        () => WaitingConfig.fromYaml({
          'toolLivenessSeconds': 600,
          'toolEscalateSeconds': 600,
        }),
        returnsNormally,
        reason: 'equal thresholds = hint-only mode, a coherent choice',
      );
      expect(
        () => WaitingConfig.fromYaml({
          'toolLivenessSeconds': 600,
          'toolEscalateSeconds': 0,
        }),
        returnsNormally,
      );
      expect(
        () => WaitingConfig.fromYaml({
          'toolLivenessSeconds': 0,
          'toolEscalateSeconds': 120,
        }),
        returnsNormally,
        reason: 'liveness 0 is the feature kill switch — nothing to order',
      );
    });

    test('toYaml round-trips the liveness knobs', () {
      const config = WaitingConfig(
        toolLivenessSeconds: 90,
        toolLivenessTickSeconds: 30,
        toolEscalateSeconds: 240,
      );
      expect(config.toYaml(), contains('toolLivenessSeconds: 90'));
      expect(config.toYaml(), contains('toolLivenessTickSeconds: 30'));
      expect(config.toYaml(), contains('toolEscalateSeconds: 240'));
    });
  });

  group('ToolLivenessTracker', () {
    late DateTime now;
    late List<String> reminds;
    late List<String> escalates;
    late ToolLivenessTracker tracker;

    void buildTracker({
      int Function()? livenessSeconds,
      int Function()? tickSeconds,
      int Function()? escalateSeconds,
    }) {
      tracker = ToolLivenessTracker(
        onRemind: (call) => reminds.add(toolLivenessReminderLine(call, now)),
        onEscalate: (call) =>
            escalates.add(toolLivenessEscalationLine(call, now)),
        clock: () => now,
        livenessSeconds: livenessSeconds,
        tickSeconds: tickSeconds,
        escalateSeconds: escalateSeconds,
      );
    }

    setUp(() {
      now = DateTime.utc(2026, 1, 1, 12);
      reminds = [];
      escalates = [];
      buildTracker();
    });

    test('a fresh tracker watches nothing', () {
      expect(tracker.inFlight, isEmpty);
      tracker.tick();
      expect(reminds, isEmpty);
      expect(escalates, isEmpty);
    });

    test('AC2: quiet below the threshold — silence-is-progress preserved', () {
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 30));
      tracker.tick();
      expect(reminds, isEmpty);
      expect(escalates, isEmpty);
    });

    test('AC1/AC5: the reminder cites elapsed from the injected clock', () {
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 120));
      tracker.tick();
      expect(reminds, ['⏳ [bash] sleep 500 — running 120s']);
      expect(escalates, isEmpty);
      // The state carries the same clock's start — one clock, no second
      // source for the elapsed value (AC5).
      expect(now.difference(tracker.inFlight.single.startedAt).inSeconds, 120);
    });

    test('the reminder repeats at every evaluation past the threshold', () {
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      expect(reminds, [
        '⏳ [bash] sleep 500 — running 60s',
        '⏳ [bash] sleep 500 — running 120s',
      ]);
    });

    test('AC3: the escalation fires exactly once per stuck call', () {
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 300));
      tracker.tick();
      expect(escalates, hasLength(1));
      expect(escalates.single, contains('bash background: true'));
      // The escalation IS the liveness line of its tick — no duplicate
      // reminder beside it.
      expect(reminds, isEmpty);
      // Subsequent ticks keep reminding but never re-escalate.
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      expect(escalates, hasLength(1));
      expect(reminds, hasLength(2));
    });

    test('a NEW stuck call escalates afresh (per-call, not per-tracker)', () {
      tracker.callStarted('t1', 'bash', 'sleep 1');
      now = now.add(const Duration(seconds: 300));
      tracker.tick();
      expect(escalates, hasLength(1));
      tracker.callEnded('t1');
      tracker.callStarted('t2', 'bash', 'sleep 2');
      now = now.add(const Duration(seconds: 300));
      tracker.tick();
      expect(escalates, hasLength(2));
    });

    test('a call ended under the threshold never reminds', () {
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 10));
      tracker.callEnded('t1');
      now = now.add(const Duration(seconds: 600));
      tracker.tick();
      expect(reminds, isEmpty);
      expect(escalates, isEmpty);
      expect(tracker.inFlight, isEmpty);
    });

    test('two concurrent calls each get their own line, oldest first', () {
      tracker.callStarted('a', 'bash', 'sleep 1');
      now = now.add(const Duration(seconds: 10));
      tracker.callStarted('b', 'bash', 'sleep 2');
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      expect(reminds, [
        '⏳ [bash] sleep 1 — running 70s',
        '⏳ [bash] sleep 2 — running 60s',
      ]);
      // Both escalate at their own threshold, one line each this tick.
      now = now.add(const Duration(seconds: 240));
      tracker.tick();
      expect(escalates, hasLength(2));
    });

    test('livenessSeconds 0 is the reminder kill switch', () {
      buildTracker(livenessSeconds: () => 0);
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 3600));
      tracker.tick();
      expect(reminds, isEmpty);
      expect(escalates, isEmpty);
    });

    test('escalateSeconds 0 disables the hint; reminders continue', () {
      buildTracker(escalateSeconds: () => 0);
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 600));
      tracker.tick();
      expect(escalates, isEmpty);
      expect(reminds, hasLength(1));
    });

    test('callEnded clears the escalated state with the call', () {
      tracker.callStarted('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 300));
      tracker.tick();
      expect(escalates, hasLength(1));
      tracker.callEnded('t1');
      expect(tracker.inFlight, isEmpty);
    });
  });

  group('ToolLivenessTracker timer chain (production legs)', () {
    // The production chain is a real Timer chain; fake_async is not a
    // dependency, so the legs run shrunk to 1-2s with the real clock and
    // the assertions poll. Cancel-before-fire is synchronous
    // (Timer.cancel), so the disarm assertions stay deterministic; only
    // the fire moments carry jitter, and every fire assertion polls with
    // slack. (Clock sourcing/elapsed math is the seam group's job above —
    // this group exercises the chain itself.)
    late List<String> reminds;
    late List<String> escalates;

    ToolLivenessTracker build({
      int livenessSeconds = 1,
      int tickSeconds = 1,
      int escalateSeconds = 0,
    }) => ToolLivenessTracker(
      onRemind: (call) =>
          reminds.add(toolLivenessReminderLine(call, DateTime.now())),
      onEscalate: (call) =>
          escalates.add(toolLivenessEscalationLine(call, DateTime.now())),
      livenessSeconds: () => livenessSeconds,
      tickSeconds: () => tickSeconds,
      escalateSeconds: () => escalateSeconds,
    );

    Future<void> waitForCount(
      List<String> lines,
      int count, {
      String? reason,
    }) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (lines.length < count) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'timed out waiting for $count line(s): '
            '${reason ?? lines.join(' | ')}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    /// Waits [seconds] of real time without asserting anything — used to
    /// prove a negative (a cancelled/disarmed chain must stay silent).
    Future<void> realSeconds(double seconds) =>
        Future<void>.delayed(Duration(microseconds: (seconds * 1e6).round()));

    setUp(() {
      reminds = [];
      escalates = [];
    });

    test('callStarted arms the chain; the fired leg ticks, re-arms, and '
        'escalates through the real chain', () async {
      final tracker = build(escalateSeconds: 2);
      tracker.callStarted('t1', 'bash', 'sleep 500');
      await waitForCount(reminds, 1, reason: 'first armed leg fired');
      await waitForCount(escalates, 1, reason: 'escalation leg fired');
      // The chain re-armed past the escalation: reminders resume.
      await waitForCount(reminds, 2, reason: 'the leg re-armed and re-fired');
      tracker.stop();
      expect(reminds.first, startsWith('⏳ [bash] sleep 500 —'));
    });

    test('the last callEnded disarms the chain — no fire after', () async {
      final tracker = build();
      tracker.callStarted('t1', 'bash', 'sleep 500');
      await waitForCount(reminds, 1);
      tracker.callEnded('t1');
      final count = reminds.length;
      // More than a full cadence of real time: a live leg would have
      // fired again — a cancelled one never does (deterministic).
      await realSeconds(1.6);
      expect(reminds.length, count, reason: 'the chain was disarmed');
    });

    test('tickSeconds: 0 keeps the chain disarmed; the tick seam still '
        'evaluates', () async {
      final tracker = build(tickSeconds: 0);
      tracker.callStarted('t1', 'bash', 'sleep 500');
      await realSeconds(1.6);
      expect(reminds, isEmpty, reason: 'no chain was ever armed');
      tracker.tick();
      expect(reminds, hasLength(1), reason: 'the manual seam evaluates');
    });

    test('a manual tick restarts the full leg (the WaitingHeartbeat '
        'mirror: tick cancels the pending leg)', () async {
      final tracker = build(tickSeconds: 2);
      tracker.callStarted('t1', 'bash', 'sleep 500');
      // Three quarters into the leg, fire the seam: the pending leg must
      // be cancelled and re-armed from NOW — the next fire comes a full
      // cadence after the tick, not at the original 2s mark.
      await realSeconds(1.5);
      tracker.tick();
      expect(reminds, hasLength(1), reason: 'the seam evaluation itself');
      await realSeconds(1.0);
      expect(
        reminds.length,
        1,
        reason:
            'the original leg was cancelled by the tick — '
            'it must not fire at its old 2s deadline',
      );
      await waitForCount(reminds, 2, reason: 'the re-armed leg fires');
      tracker.stop();
    });
  });

  group('liveness line formatters', () {
    final start = DateTime.utc(2026, 1, 1, 12);
    final at120 = start.add(const Duration(seconds: 120));

    ToolLivenessCall call(String detail, {String name = 'bash'}) =>
        ToolLivenessCall(
          id: 't1',
          toolName: name,
          detail: detail,
          startedAt: start,
        );

    test('the reminder line is single-line, tool + detail + elapsed', () {
      expect(
        toolLivenessReminderLine(call('sleep 500'), at120),
        '⏳ [bash] sleep 500 — running 120s',
      );
    });

    test('the escalation line names the whole background escape hatch', () {
      final line = toolLivenessEscalationLine(call('sleep 500'), at120);
      expect(line, startsWith('⏳ [bash] sleep 500 — running 120s'));
      expect(line, contains('background candidate'));
      expect(line, contains('bash background: true'));
      expect(line, contains('/tasks'));
      expect(line, contains('--wait-for-jobs'));
    });

    test('AC6: the escalation line carries the cancellation affordance '
        '(background stop + foreground levers + unwinding note)', () {
      final line = toolLivenessEscalationLine(call('sleep 500'), at120);
      // The background case: once backgrounded, the job board's stop lever.
      expect(line, contains('cancel: fa bash_job stop <id> once backgrounded'));
      // The foreground case: the two levers that exist mid-call, plus the
      // honest caveat that they land only once the call unwinds (#1053).
      expect(line, contains('Ctrl+C / inbox steering'));
      expect(line, contains('takes effect once the call unwinds'));
      expect(line, contains('#1053'));
    });

    test('a multi-line detail flattens to one physical line', () {
      final line = toolLivenessReminderLine(
        call('flutter test --tag slow\n--coverage'),
        at120,
      );
      expect(line.contains('\n'), isFalse);
      expect(line, contains('flutter test --tag slow --coverage'));
    });

    test('a very long detail clips at the budget with an ellipsis', () {
      final line = toolLivenessReminderLine(call('x' * 500), at120);
      expect(line.length, lessThan(500));
      expect(line, startsWith('⏳ [bash] '));
      expect(line, contains('${'x' * toolLivenessDetailClip}…'));
    });

    test('an empty detail degrades to glyph + tool + elapsed', () {
      expect(
        toolLivenessReminderLine(call(''), at120),
        '⏳ [bash] running 120s',
      );
      expect(
        toolLivenessEscalationLine(call(''), at120),
        contains('⏳ [bash] running 120s · background candidate'),
      );
    });

    test('the elapsed floors fractional seconds', () {
      final line = toolLivenessReminderLine(
        call('sleep 500'),
        start.add(const Duration(milliseconds: 59900)),
      );
      expect(line, '⏳ [bash] sleep 500 — running 59s');
    });
  });
}
