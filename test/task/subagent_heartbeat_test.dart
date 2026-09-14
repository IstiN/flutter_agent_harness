import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The background-subagent heartbeat (issue #383): the unit ACs —
/// UT-zombie, UT-healthy-quiet, UT-digest-merge, UT-kill-switch — driven
/// against a real [SubagentManager] with a fake clock and manual ticks.
void main() {
  // Only differences matter; the incident's spawn evening, in UTC.
  final t0 = DateTime.utc(2026, 9, 14, 18, 4);

  late DateTime now;
  late SubagentManager manager;
  final notices = <String>[];

  SubagentHeartbeat buildHeartbeat({
    int Function()? heartbeatMinutes,
    int Function()? stallMinutes,
  }) {
    return SubagentHeartbeat(
      manager: manager,
      notify: notices.add,
      heartbeatMinutes: heartbeatMinutes ?? (() => 12),
      stallMinutes: stallMinutes ?? (() => 12),
      now: () => now,
    );
  }

  Future<void> spawnRunning(String id, {String agentType = 'task'}) async {
    await manager.register(
      id: id,
      name: id,
      agentType: agentType,
      task: 'job $id',
    );
    await manager.update(id, status: SubagentStatus.running);
  }

  setUp(() {
    now = t0;
    manager = SubagentManager(parentSessionId: 'p', clock: () => now);
    notices.clear();
  });

  group('AC1 UT-zombie', () {
    test('a child with no provider request flags [WARN] STALLED at the first '
        'tick and [WARN][WARN] at twice the stall threshold', () async {
      await spawnRunning('fix355');
      final heartbeat = buildHeartbeat();

      now = t0.add(const Duration(minutes: 12));
      final first = heartbeat.tick();
      expect(notices, hasLength(1), reason: 'exactly one digest at +12 min');
      expect(first, isNotNull);
      expect(first!, contains('[WARN] STALLED'));
      expect(first, contains('0 requests'));
      expect(first, contains('no-progress-since-spawn'));
      expect(first, contains('task_status → task_cancel → respawn'));
      expect(
        first,
        isNot(contains('[WARN][WARN]')),
        reason: 'not escalated yet',
      );
      expect(first, contains('age 12m'));

      now = t0.add(const Duration(minutes: 24));
      final second = heartbeat.tick();
      expect(notices, hasLength(2));
      expect(second, isNotNull);
      expect(second!, contains('[WARN][WARN]'));
      expect(second, contains('age 24m'));
    });

    test('E1/E3: a child finished before the tick leaves no zombie-ghost '
        'line — the completion notice is the only word', () async {
      await spawnRunning('done-early');
      final heartbeat = buildHeartbeat();
      await manager.update(
        'done-early',
        status: SubagentStatus.completed,
        requests: 3,
        tokens: 900,
      );
      now = t0.add(const Duration(minutes: 12));
      expect(heartbeat.tick(), isNull);
      expect(notices, isEmpty);
    });
  });

  group('AC2 UT-healthy-quiet', () {
    test('climbing tokens for 30 minutes yield three healthy digests, '
        'zero stall flags', () async {
      await spawnRunning('worker');
      final heartbeat = buildHeartbeat(
        heartbeatMinutes: () => 10,
        stallMinutes: () => 20,
      );
      for (var i = 1; i <= 3; i++) {
        now = t0.add(Duration(minutes: 10 * i));
        await manager.update('worker', requests: 2, tokens: 500);
        final digest = heartbeat.tick();
        expect(digest, isNotNull);
        expect(digest!, contains('healthy'));
        expect(digest, isNot(contains('[WARN]')));
        expect(digest, contains('${2 * i} requests'));
        expect(digest, contains('${500 * i} tokens'));
      }
      expect(notices, hasLength(3));
    });
  });

  group('AC3 UT-digest-merge', () {
    test('three running children merge into ONE notice per tick', () async {
      await spawnRunning('alpha');
      await spawnRunning('beta');
      await spawnRunning('gamma');
      final heartbeat = buildHeartbeat();
      now = t0.add(const Duration(minutes: 12));
      final digest = heartbeat.tick();
      expect(notices, hasLength(1), reason: 'one merged digest, never three');
      expect(digest, isNotNull);
      expect(digest!, contains('3 running'));
      expect(digest, contains('alpha (task)'));
      expect(digest, contains('beta (task)'));
      expect(digest, contains('gamma (task)'));
    });
  });

  group('AC6 UT-kill-switch', () {
    test('heartbeatMinutes 0 arms nothing and ticks report nothing', () async {
      await spawnRunning('zombie');
      final heartbeat = buildHeartbeat(heartbeatMinutes: () => 0);
      heartbeat.start();
      now = t0.add(const Duration(hours: 1));
      expect(heartbeat.tick(), isNull);
      expect(notices, isEmpty);
    });

    test('stallMinutes 0 disables stall flagging — facts still flow', () async {
      await spawnRunning('zombie');
      final heartbeat = buildHeartbeat(stallMinutes: () => 0);
      now = t0.add(const Duration(minutes: 12));
      final digest = heartbeat.tick();
      expect(digest, isNotNull);
      expect(digest!, contains('zombie'));
      expect(digest, isNot(contains('[WARN]')));
    });
  });

  group('E6 config re-read', () {
    test('the getters are consulted every tick — a changed value applies '
        'at the next tick without a restart', () async {
      await spawnRunning('worker');
      var heartbeatMinutes = 10;
      final heartbeat = buildHeartbeat(
        heartbeatMinutes: () => heartbeatMinutes,
      );
      now = t0.add(const Duration(minutes: 10));
      await manager.update('worker', requests: 1, tokens: 100);
      expect(heartbeat.tick(), isNotNull);
      heartbeatMinutes = 0; // the kill switch, flipped mid-run
      now = t0.add(const Duration(minutes: 20));
      expect(heartbeat.tick(), isNull);
      expect(notices, hasLength(1));
    });
  });

  group('in-flight liveness', () {
    test('the executor touch feeds live request/token counts into the '
        'digest', () async {
      await spawnRunning('worker');
      now = t0.add(const Duration(minutes: 10));
      manager.touch('worker', tokens: 1500, requests: 4);
      final heartbeat = buildHeartbeat();
      now = t0.add(const Duration(minutes: 12));
      final digest = heartbeat.tick();
      expect(digest, isNotNull);
      expect(digest!, contains('4 requests'));
      expect(digest, contains('1500 tokens'));
      expect(digest, contains('healthy'));
    });
  });
}
