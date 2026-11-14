// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';
import 'package:test/test.dart';

/// Fake clock + manually-fired timers: presence tests drive every tick
/// deterministically (no real waits).
final class FakeClock implements ConnectorClock {
  DateTime _now = DateTime.utc(2026, 11, 12, 10);

  @override
  DateTime now() => _now;

  void advance(Duration delta) => _now = _now.add(delta);
}

final class FakeTimer implements ConnectorTimer {
  FakeTimer({required this.fire});
  final void Function() fire;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class FakeTimers implements ConnectorTimers {
  final periodicTimers = <FakeTimer>[];
  final delayedTimers = <FakeTimer>[];

  @override
  ConnectorTimer periodic(Duration interval, void Function() onTick) {
    final timer = FakeTimer(fire: onTick);
    periodicTimers.add(timer);
    return timer;
  }

  @override
  ConnectorTimer delayed(Duration duration, void Function() onFire) {
    final timer = FakeTimer(fire: onFire);
    delayedTimers.add(timer);
    return timer;
  }

  void fireHeartbeats([int count = 1]) {
    for (var i = 0; i < count; i++) {
      for (final timer in List.of(periodicTimers)) {
        if (!timer.cancelled) timer.fire();
      }
    }
  }

  void fireDelayed() {
    for (final timer in List.of(delayedTimers)) {
      if (!timer.cancelled) timer.fire();
    }
  }
}

/// Broadcast streams deliver asynchronously — drain the event queue so
/// synchronously-emitted frames land in [frames].
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeClock clock;
  late FakeTimers timers;
  late PresenceEngine engine;
  late List<PresenceFrame> frames;
  late StreamSubscription<PresenceFrame> subscription;

  setUp(() {
    clock = FakeClock();
    timers = FakeTimers();
    engine = PresenceEngine(clock: clock, timers: timers);
    frames = <PresenceFrame>[];
    subscription = engine.frames.listen(frames.add);
  });

  tearDown(() async {
    await subscription.cancel();
    engine.dispose();
  });

  test('heartbeat constant sits inside the contract §5 window (15–30 s)', () {
    expect(
      PresenceEngine.presenceHeartbeatInterval.inSeconds,
      inInclusiveRange(15, 30),
    );
  });

  test('offline grace default is the ~45 s contract window', () {
    expect(PresenceEngine.defaultOfflineGrace, const Duration(seconds: 45));
  });

  test(
    'start emits an initial offline snapshot and arms the heartbeat',
    () async {
      engine.start();
      await pump();
      expect(engine.isRunning, isTrue);
      expect(frames, hasLength(1));
      expect(frames.single.machine, MachinePresence.offline);
      expect(timers.periodicTimers, hasLength(1));
      expect(frames.single.ts, '2026-11-12T10:00:00.000Z');
    },
  );

  test('heartbeat ticks emit a snapshot per tick', () async {
    engine.start();
    await pump();
    frames.clear();
    timers.fireHeartbeats(3);
    await pump();
    expect(frames, hasLength(3));
  });

  test(
    'markConnected flips online immediately; heartbeat keeps flowing',
    () async {
      engine
        ..start()
        ..markConnected();
      await pump();
      expect(frames.last.machine, MachinePresence.online);
      expect(engine.machineState, MachinePresence.online);
      frames.clear();
      timers.fireHeartbeats(1);
      await pump();
      expect(frames.single.machine, MachinePresence.online);
    },
  );

  test(
    'socket lost: degraded immediately, offline after the grace window',
    () async {
      engine
        ..start()
        ..markConnected()
        ..markSocketLost();
      await pump();
      expect(frames.last.machine, MachinePresence.degraded);
      expect(timers.delayedTimers, hasLength(1));
      frames.clear();
      timers.fireDelayed();
      await pump();
      expect(frames, hasLength(1), reason: '§5: flip emits immediately');
      expect(frames.single.machine, MachinePresence.offline);
      expect(engine.machineState, MachinePresence.offline);
    },
  );

  test('reconnect inside the grace window cancels the offline flip', () async {
    engine
      ..start()
      ..markConnected()
      ..markSocketLost()
      ..markConnected();
    await pump();
    frames.clear();
    timers.fireDelayed();
    await pump();
    expect(frames, isEmpty, reason: 'grace timer was cancelled');
    expect(engine.machineState, MachinePresence.online);
  });

  test('agent states flip immediately and ride the machine frame', () async {
    engine
      ..start()
      ..setAgentState('goal_builder@macbook', AgentRunState.busy);
    await pump();
    expect(frames.last.agents['goal_builder@macbook'], AgentRunState.busy);
    engine.setAgentState('goal_builder@macbook', AgentRunState.busy);
    expect(frames, hasLength(2), reason: 'no flip, no frame');
    engine.setAgentStates({
      'goal_builder@macbook': AgentRunState.live,
      'scout@macbook': AgentRunState.busy,
    });
    await pump();
    expect(frames.last.agents['goal_builder@macbook'], AgentRunState.live);
    expect(frames.last.agents['scout@macbook'], AgentRunState.busy);
  });

  test('session presence derives from exposure + lease delegates', () async {
    final leased = PresenceEngine(
      clock: clock,
      timers: timers,
      exposedSessions: () => {'sess-live', 'sess-asleep'},
      liveLeases: () => {'sess-live'},
    );
    final seen = <PresenceFrame>[];
    final sub = leased.frames.listen(seen.add);
    leased
      ..start()
      ..markConnected();
    await pump();
    expect(seen.last.sessions['sess-live'], ConnectorSessionPresence.live);
    expect(
      seen.last.sessions['sess-asleep'],
      ConnectorSessionPresence.wakeOnDm,
    );
    // Device offline → every session offline, lease or not.
    leased.markSocketLost();
    timers.fireDelayed();
    await pump();
    expect(seen.last.sessions['sess-live'], ConnectorSessionPresence.offline);
    expect(seen.last.sessions['sess-asleep'], ConnectorSessionPresence.offline);
    sub.cancel();
    leased.dispose();
  });

  test('clean stop deregisters immediately and stops all timers', () async {
    engine
      ..start()
      ..markConnected()
      ..stop();
    await pump();
    expect(frames.last.machine, MachinePresence.offline);
    expect(engine.isRunning, isFalse);
    expect(timers.periodicTimers.every((timer) => timer.cancelled), isTrue);
    frames.clear();
    timers.fireHeartbeats(1);
    timers.fireDelayed();
    await pump();
    expect(frames, isEmpty);
    engine.stop();
    await pump();
    expect(frames, isEmpty, reason: 'stop is idempotent');
  });

  test(
    'frame round trips with presence collections at the wire top level',
    () async {
      final engine2 = PresenceEngine(
        clock: clock,
        timers: timers,
        exposedSessions: () => {'sess-1'},
        liveLeases: () => const <String>{},
        idFactory: () => 'fixed-id',
      );
      engine2
        ..start()
        ..markConnected()
        ..setAgentState('goal_builder@macbook', AgentRunState.live);
      await pump();
      final envelope = engine2.snapshot().toEnvelope(
        idFactory: () => 'fixed-id',
      );
      expect(envelope.kind, NetworkEnvelopeKind.presence);
      expect(envelope.network, isNull, reason: 'device-level frame, §3');
      expect(envelope.channel, isNull);
      expect(envelope.isValid, isTrue);
      expect(envelope.toJson(), {
        'v': 1,
        'kind': 'presence',
        'msgId': 'fixed-id',
        'ts': '2026-11-12T10:00:00.000Z',
        'machine': 'online',
        'agents': [
          {'address': 'goal_builder@macbook', 'state': 'live'},
        ],
        'sessions': [
          {'id': 'sess-1', 'state': 'wake_on_dm'},
        ],
      });
      final parsed = PresenceFrame.fromEnvelope(
        NetworkEnvelope.fromJson(envelope.toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.msgId, 'fixed-id');
      expect(parsed.machine, MachinePresence.online);
      expect(parsed.agents, {'goal_builder@macbook': AgentRunState.live});
      expect(parsed.sessions, {'sess-1': ConnectorSessionPresence.wakeOnDm});
      expect(
        PresenceFrame.fromEnvelope(
          NetworkEnvelope(
            kind: NetworkEnvelopeKind.mail,
            msgId: 'm',
            network: 'n',
            channel: 'c',
            ts: '2026-11-12T10:00:00.000Z',
            ciphertext: 'c',
          ),
        ),
        isNull,
      );
      engine2.dispose();
    },
  );

  test('session metadata is additive and legacy id-only rows still decode', () {
    final engine2 = PresenceEngine(
      clock: clock,
      timers: timers,
      exposedSessions: () => {'sess-rich', 'sess-legacy'},
      liveLeases: () => {'sess-rich'},
      idFactory: () => 'metadata-id',
    );
    engine2.sessionMetadata = () => const {
      'sess-rich': ConnectorSessionMetadata(
        title: 'Release plan',
        path: '/work/flutter_agent',
        lastActivity: null,
      ),
    };
    final rich = PresenceFrame(
      msgId: 'metadata-id',
      ts: '2026-11-12T10:00:00.000Z',
      machine: MachinePresence.online,
      sessions: const {
        'sess-rich': ConnectorSessionPresence.live,
        'sess-legacy': ConnectorSessionPresence.wakeOnDm,
      },
      sessionMetadata: const {
        'sess-rich': ConnectorSessionMetadata(
          title: 'Release plan',
          path: '/work/flutter_agent',
          lastActivity: null,
        ),
      },
    );
    final envelope = rich.toEnvelope();
    final rows = envelope.payload['sessions'] as List;
    expect(rows[0], {
      'id': 'sess-rich',
      'state': 'live',
      'title': 'Release plan',
      'path': '/work/flutter_agent',
    });
    expect(rows[1], {'id': 'sess-legacy', 'state': 'wake_on_dm'});
    final decoded = PresenceFrame.fromEnvelope(envelope)!;
    expect(decoded.sessionMetadata['sess-rich']?.title, 'Release plan');
    expect(decoded.sessionMetadata['sess-rich']?.path, '/work/flutter_agent');
    expect(decoded.sessionMetadata.containsKey('sess-legacy'), isFalse);
    expect(decoded.sessions['sess-legacy'], ConnectorSessionPresence.wakeOnDm);
    expect(
      ConnectorSessionPresence.tryParse('wake-on-DM'),
      ConnectorSessionPresence.wakeOnDm,
    );
    engine2.dispose();
  });

  test('ConnectorSessionMetadata equality and hashCode cover every field', () {
    final activity = DateTime.utc(2026, 11, 14, 12);
    const base = ConnectorSessionMetadata(
      title: 'Release plan',
      path: '/work/flutter_agent',
    );
    final full = ConnectorSessionMetadata(
      title: 'Release plan',
      path: '/work/flutter_agent',
      lastActivity: activity,
    );
    expect(base == base, isTrue);
    expect(base == full, isFalse); // lastActivity differs
    expect(
      base,
      const ConnectorSessionMetadata(
        title: 'Release plan',
        path: '/work/flutter_agent',
      ),
    );
    expect(base.hashCode, base.hashCode);
    expect(
      base ==
          const ConnectorSessionMetadata(
            title: 'Other title',
            path: '/work/flutter_agent',
          ),
      isFalse,
    );
    expect(
      base ==
          const ConnectorSessionMetadata(
            title: 'Release plan',
            path: '/other/path',
          ),
      isFalse,
    );
    expect(base == Object(), isFalse);
    expect(full == base, isFalse);
    expect(
      full,
      ConnectorSessionMetadata(
        title: 'Release plan',
        path: '/work/flutter_agent',
        lastActivity: activity,
      ),
    );
    expect(
      full.hashCode,
      ConnectorSessionMetadata(
        title: 'Release plan',
        path: '/work/flutter_agent',
        lastActivity: activity,
      ).hashCode,
    );
  });

  test('toString hides payload details (diagnostics hygiene)', () async {
    engine.start();
    await pump();
    expect(engine.snapshot().toString(), contains('machine: offline'));
  });
}
