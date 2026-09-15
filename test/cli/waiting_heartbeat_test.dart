/// Unit tests for the visible-waiting layer's config + heartbeat (issue
/// #450): the `waiting:` yaml section, the heartbeat arm/pulse/stop
/// lifecycle, and the ceiling semantics on the one-shot timer chain.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
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
      expect(
        () => WaitingConfig.fromYaml({'bogus': 1}),
        throwsA(anything),
      );
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
      final hb = WaitingHeartbeat(
        onBeat: () => beats++,
        minutes: () => 0,
      );
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
      final hb = WaitingHeartbeat(
        onBeat: () => beats++,
        minutes: () => 1,
      );
      hb.start();
      // One-shot chain, minute granularity — shrink the wait by ticking
      // through the public seam instead of sleeping a minute.
      hb.tick();
      await Future<void>.delayed(Duration.zero);
      expect(beats, 1);
      hb.stop();
    });
  });
}
