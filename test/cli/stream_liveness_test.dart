/// Unit tests for the stream liveness heartbeat (gh-1430): the gh-1198
/// tier-2 reasoning line covers the PRE-first-event window only — the
/// first event of a reasoning model is a thinking delta, which headless
/// does not render, so the pane used to go byte-silent for whole thinking
/// bursts. `StreamLivenessHeartbeat` keeps a `(streaming)` line flowing
/// while events the current output mode does not render keep arriving,
/// and never prints for a stream that stopped emitting (a dead stream
/// must not heartbeat — fa's own stream-idle watchdog arbitrates death).
library;

import 'package:flutter_agent_harness/src/cli/reasoning_liveness.dart';
import 'package:flutter_agent_harness/src/cli/tool_liveness.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1, 12);
  var lines = <String>[];

  DateTime clockForTest() => now;
  void recordLine(int elapsed) => lines.add(streamLivenessLine(elapsed));
  int cadenceSeconds() => 60;
  int tickCadenceSeconds() => 60;

  StreamLivenessHeartbeat build({
    int Function()? cadence,
    int Function()? tick,
  }) => StreamLivenessHeartbeat(
    onRemind: recordLine,
    livenessSeconds: cadence ?? cadenceSeconds,
    tickSeconds: tick ?? tickCadenceSeconds,
    clock: clockForTest,
  );

  setUp(() {
    now = DateTime.utc(2026, 1, 1, 12);
    lines = [];
  });

  group('streamLivenessLine', () {
    test('distinct (streaming) suffix over the pinned grep anchor', () {
      // Open question 1 resolved: the suffix lets post-mortems tell
      // pre-first-event silence (bare tier-2 line) from streaming
      // silence, while `… reasoning` stays the one grep anchor.
      expect(streamLivenessLine(60), '… reasoning 60s (streaming)');
      expect(streamLivenessLine(125), '… reasoning 125s (streaming)');
      // The tier-2 line is untouched.
      expect(reasoningLivenessLine(60), '… reasoning 60s');
    });
  });

  group('AC1: heartbeat while unrendered events flow', () {
    test('prints at the cadence; elapsed counts from the request start', () {
      final tracker = build();
      tracker.requestStarted();
      expect(tracker.armed, isTrue);

      // The first unrendered thinking delta lands at t=5s.
      now = now.add(const Duration(seconds: 5));
      tracker.unrenderedEvent();

      // Before the threshold: silent.
      now = now.add(const Duration(seconds: 30));
      tracker.tick();
      expect(lines, isEmpty);

      // Past the threshold the line fires with the request elapsed.
      now = now.add(const Duration(seconds: 25));
      tracker.tick();
      expect(lines, ['… reasoning 60s (streaming)']);

      // More events, more lines — the pane grows monotonically (AC3).
      now = now.add(const Duration(seconds: 10));
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: 50));
      tracker.tick();
      expect(lines, [
        '… reasoning 60s (streaming)',
        '… reasoning 120s (streaming)',
      ]);
    });

    test('events arriving before the threshold still produce the first '
        'line at the first tick past it (dirty survives a silent tick)', () {
      final tracker = build();
      tracker.requestStarted();
      now = now.add(const Duration(seconds: 5));
      tracker.unrenderedEvent();

      now = now.add(const Duration(seconds: 30));
      tracker.tick(); // below the threshold — must not consume the event
      expect(lines, isEmpty);

      now = now.add(const Duration(seconds: 25));
      tracker.tick();
      expect(lines, ['… reasoning 60s (streaming)']);
    });

    test('disarms the moment a renderable byte prints (text delta)', () {
      final tracker = build();
      tracker.requestStarted();
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      expect(lines, hasLength(1));

      tracker.renderedOutput();
      expect(tracker.armed, isFalse);

      // Ticks after the disarm never print — the run is visibly moving.
      now = now.add(const Duration(seconds: 60));
      tracker.unrenderedEvent();
      tracker.tick();
      expect(lines, hasLength(1));
    });

    test('per-request lifecycle: the next request re-arms (E2)', () {
      final tracker = build();
      // Request 1: thinking burst, one heartbeat, then a tool row
      // (rendered) disarms.
      tracker.requestStarted();
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      tracker.renderedOutput();

      // Request 2 goes out at t=200: fresh elapsed base.
      now = now.add(const Duration(seconds: 140));
      tracker.requestStarted();
      expect(tracker.armed, isTrue);
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      expect(lines, [
        '… reasoning 60s (streaming)',
        '… reasoning 60s (streaming)',
      ]);
    });

    test('re-arming resets the dirty window (a fresh request starts '
        'silent until its own first event)', () {
      final tracker = build();
      tracker.requestStarted();
      tracker.unrenderedEvent(); // request 1's delta
      tracker.renderedOutput(); // tool row

      tracker.requestStarted(); // request 2 — no events yet
      now = now.add(const Duration(seconds: 600));
      tracker.tick();
      expect(lines, isEmpty);
    });
  });

  group('AC2: dead-stream discrimination', () {
    test('a request that emits NO events never heartbeats (tier-2 owns '
        'that window)', () {
      final tracker = build();
      tracker.requestStarted();
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(seconds: 60));
        tracker.tick();
      }
      expect(lines, isEmpty);
    });

    test('a request that heartbeats and then goes event-silent prints at '
        'most one more line, then silence — the watchdog still arbitrates',
        () {
      final tracker = build();
      tracker.requestStarted();

      // Events flow through t=90, then the stream dies.
      now = now.add(const Duration(seconds: 90));
      tracker.unrenderedEvent();

      now = now.add(const Duration(seconds: 60));
      tracker.tick(); // t=150: one line, the last proof of the event
      expect(lines, ['… reasoning 150s (streaming)']);

      // No further events: every later tick stays silent — the pane must
      // stop growing so fa's stream-idle watchdog remains the arbiter.
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 60));
        tracker.tick();
      }
      expect(lines, hasLength(1));
    });
  });

  group('E6: misconfigured cadence falls back, never spins', () {
    test('toolLivenessSeconds 0 falls back to the tool-liveness default', () {
      final tracker = build(cadence: () => 0);
      tracker.requestStarted();
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: defaultToolLivenessSeconds));
      tracker.tick();
      expect(lines, [
        '… reasoning ${defaultToolLivenessSeconds}s (streaming)',
      ]);
      // No fresh events: an immediate re-tick must not spin another line.
      tracker.tick();
      expect(lines, hasLength(1));
    });

    test('a negative cadence falls back too', () {
      final tracker = build(cadence: () => -5);
      tracker.requestStarted();
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: defaultToolLivenessSeconds));
      tracker.tick();
      expect(lines, [
        '… reasoning ${defaultToolLivenessSeconds}s (streaming)',
      ]);
    });

    test('tickSeconds 0 disables the production chain; the tick seam still '
        'evaluates', () {
      final tracker = build(tick: () => 0);
      tracker.requestStarted();
      tracker.unrenderedEvent();
      now = now.add(const Duration(seconds: 60));
      tracker.tick();
      expect(lines, ['… reasoning 60s (streaming)']);
    });
  });

  group('lifecycle edges', () {
    test('stop() disarms and drops the dirty window (message end, E4)', () {
      final tracker = build();
      tracker.requestStarted();
      tracker.unrenderedEvent();
      tracker.stop();
      expect(tracker.armed, isFalse);
      now = now.add(const Duration(seconds: 600));
      tracker.tick();
      expect(lines, isEmpty);
    });

    test('events on a disarmed tracker are no-ops (host hooks fire on '
        'every event; the tracker stays out when the feature is not '
        'active — TUI / --stream-thinking)', () {
      final tracker = build();
      tracker.unrenderedEvent();
      tracker.renderedOutput();
      tracker.tick();
      expect(lines, isEmpty);
      expect(tracker.armed, isFalse);
    });
  });
}
