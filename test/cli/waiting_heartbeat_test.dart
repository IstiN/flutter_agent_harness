/// Unit tests for the visible-waiting layer's config + heartbeat (issue
/// #450): the `waiting:` yaml section, the heartbeat arm/pulse/stop
/// lifecycle, and the ceiling semantics on the one-shot timer chain.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:flutter_agent_harness/src/cli/agent_cli.dart';
import 'package:test/test.dart';

void main() {
  group('WaitingConfig', () {
    test('defaults: 20-minute heartbeat, 30-minute ceiling', () {
      const config = WaitingConfig();
      expect(config.waitHeartbeatMinutes, 20);
      expect(config.waitCeilingMinutes, 30);
    });

    test('fromYaml(null) keeps defaults', () {
      final config = WaitingConfig.fromYaml(null);
      expect(config.waitHeartbeatMinutes, 20);
      expect(config.waitCeilingMinutes, 30);
    });

    test('fromYaml parses both keys', () {
      final config = WaitingConfig.fromYaml({
        'waitHeartbeatMinutes': 5,
        'waitCeilingMinutes': 10,
      });
      expect(config.waitHeartbeatMinutes, 5);
      expect(config.waitCeilingMinutes, 10);
    });

    test('fromYaml rejects unknown and negative values', () {
      expect(
        () => WaitingConfig.fromYaml({'waitHeartbeatMinutes': -1}),
        throwsA(anything),
      );
      expect(() => WaitingConfig.fromYaml({'bogus': 1}), throwsA(anything));
    });
  });

  group('WaitingHeartbeat', () {
    test('tick fires the beat only while armed', () {
      var beats = 0;
      final hb = WaitingHeartbeat(onBeat: () => beats++);
      hb.tick();
      expect(beats, 0, reason: 'disarmed heartbeat never beats');
      hb.start();
      hb.tick();
      expect(beats, 1);
    });

    test('zero cadence disables arming (kill switch)', () {
      var beats = 0;
      final hb = WaitingHeartbeat(onBeat: () => beats++, minutes: () => 0);
      hb.start();
      hb.tick();
      expect(beats, 0);
    });

    test('pulse arms when idle and keeps the chain alive when running', () {
      var beats = 0;
      final hb = WaitingHeartbeat(onBeat: () => beats++);
      hb.pulse();
      hb.tick();
      expect(beats, 1, reason: 'pulse on an idle heartbeat arms it');
      hb.pulse();
      hb.tick();
      expect(beats, 2, reason: 'pulse while running restarts, not stops');
      hb.stop();
      hb.tick();
      expect(beats, 2, reason: 'stop disarms the chain');
    });

    test('the real timer fires the beat after the cadence', () async {
      var beats = 0;
      final hb = WaitingHeartbeat(onBeat: () => beats++, minutes: () => 1);
      hb.start();
      // One-shot chain, minute granularity — shrink the wait by ticking
      // through the public seam instead of sleeping a minute.
      hb.tick();
      await Future<void>.delayed(Duration.zero);
      expect(beats, 1);
      hb.stop();
    });
  });
  group('wait-loop pure helpers', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    final deadline = now.add(const Duration(minutes: 30));
    test('heartbeat cadence beats a farther ceiling', () {
      expect(
        nextWakeDelay(
          now: now,
          deadline: deadline,
          heartbeatMin: 20,
          lastHeartbeat: now,
          timerDueMs: const [],
        ),
        const Duration(minutes: 20),
      );
    });
    test('the nearest timer wins', () {
      expect(
        nextWakeDelay(
          now: now,
          deadline: deadline,
          heartbeatMin: 20,
          lastHeartbeat: now,
          timerDueMs: [
            now.millisecondsSinceEpoch + 60_000,
            now.millisecondsSinceEpoch + 240_000,
          ],
        ),
        const Duration(minutes: 1), // the nearer timer
      );
    });
    test('heartbeat cadence can be the nearest wake', () {
      final lastBeat = now.subtract(const Duration(minutes: 15));
      expect(
        nextWakeDelay(
          now: now,
          deadline: deadline,
          heartbeatMin: 20,
          lastHeartbeat: lastBeat,
          timerDueMs: const [],
        ),
        const Duration(minutes: 5),
      );
    });
    test('disabled heartbeat never wakes', () {
      final lastBeat = now.subtract(const Duration(minutes: 90));
      expect(
        nextWakeDelay(
          now: now,
          deadline: deadline,
          heartbeatMin: 0,
          lastHeartbeat: lastBeat,
          timerDueMs: const [],
        ),
        const Duration(minutes: 30),
      );
    });
    test('waitingBeatDue gates on cadence and elapsed time', () {
      final lastBeat = now.subtract(const Duration(minutes: 21));
      expect(
        waitingBeatDue(now: now, lastHeartbeat: lastBeat, heartbeatMin: 20),
        isTrue,
      );
      expect(
        waitingBeatDue(
          now: now,
          lastHeartbeat: now.subtract(const Duration(minutes: 19)),
          heartbeatMin: 20,
        ),
        isFalse,
      );
      expect(
        waitingBeatDue(now: now, lastHeartbeat: lastBeat, heartbeatMin: 0),
        isFalse,
      );
    });
  });
}
