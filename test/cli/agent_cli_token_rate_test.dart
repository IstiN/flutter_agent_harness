// gh-1762 integration tests: the meter wiring through the real CLI run
// loop — snapshot carries the live rate mid-turn (AC1), hides when idle
// (AC2), the session average appears after the first completed turn and
// equals ledger output over active-stream time (AC3), turn-end
// calibration reaches the next turn through the run loop (AC4), a
// whole-message arrival still lands the burst (AC6), a long mid-turn gap
// decays the live window and stays out of the average denominator (AC7),
// and the classic footer carries the same two numbers (AC2 — the
// tuiClassic surface). Timing rides the injected `ledgerClock`, so every
// number is exact; the gate holds each run mid-turn while the test moves
// the clock (a large move IS the tool-execution gap of AC7).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The script clock: the test sets it, the meter (via `ledgerClock`) reads.
final class _ScriptClock {
  int ms;

  _ScriptClock(this.ms);

  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms);
}

/// A gated stream turn. Delta turns push one 40-char delta (10 tok at
/// factor 1), park the run on [gate], then finish after the gate with a
/// second delta and real usage — all timestamps RELATIVE to the clock
/// when the turn started, so sequential runs compose. With
/// [streamDeltas] off the message arrives whole (the no-delta provider
/// shape of AC6): Start → gate → Done.
final class _GatedRateStream {
  _GatedRateStream(this.clock, {this.streamDeltas = true});

  final _ScriptClock clock;

  /// One gate per turn — the test completes it (and swaps in a fresh one
  /// for the next run) to let the stream finish.
  Completer<void> gate = Completer<void>();

  /// Whole-message turns skip the delta events entirely.
  final bool streamDeltas;

  var usageOutput = 100;
  var deltasSeen = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    unawaited(_run(stream));
    return stream;
  }

  Future<void> _run(AssistantMessageEventStream stream) async {
    final text = 'abcdefghij' * 4; // 40 chars → 10 tok at factor 1
    final empty = testAssistant();
    stream.push(StartEvent(partial: empty));
    if (streamDeltas) {
      stream.push(TextStartEvent(contentIndex: 0, partial: empty));
      stream.push(TextDeltaEvent(contentIndex: 0, delta: text, partial: empty));
      deltasSeen++;
    }
    await gate.future;
    final full = testAssistant(
      content: [TextContent(text: streamDeltas ? text + text : text)],
      usage: Usage(
        input: 10,
        output: usageOutput,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 10 + usageOutput,
        cost: const UsageCost(),
      ),
    );
    if (streamDeltas) {
      stream.push(TextDeltaEvent(contentIndex: 0, delta: text, partial: full));
      deltasSeen++;
    }
    clock.ms = clock.ms + 1000;
    stream.push(DoneEvent(reason: StopReason.stop, message: full));
    stream.end();
  }
}

AgentCli _cliFor(_ScriptClock clock, _GatedRateStream script, FakeCliIO io) =>
    AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: script.call,
      ledgerClock: clock.call,
      version: '0.0.0-test',
    );

void main() {
  late _ScriptClock clock;
  late _GatedRateStream script;
  late FakeCliIO io;

  setUp(() {
    clock = _ScriptClock(0);
    script = _GatedRateStream(clock);
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'IT-RATE-1: the snapshot carries the live rate mid-turn (AC1), '
    'hides when idle, the average appears after the turn (AC2/AC3), and '
    'the classic footer shows the same numbers',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = _cliFor(clock, script, io);
      final run = cli.handleLineForTest('hi');
      await waitForIt(() => script.deltasSeen >= 1);

      // Parked mid-turn: advance the clock so the burst has elapsed time,
      // then the band shows 10 tok over 0.5s.
      clock.ms = 500;
      await waitForIt(
        () => cli.statusLineSnapshotForTest().tokensPerSecond != null,
      );
      final mid = cli.statusLineSnapshotForTest();
      expect(mid.tokensPerSecond, closeTo(20.0, 1e-9));
      expect(mid.idle, isFalse);
      // No completed turn yet: no average, and never a 0 placeholder.
      expect(mid.tokensPerSecondAvg, isNull);

      // The band renders it (the default preset carries the pair).
      final row = renderStatusLine(
        mid,
        resolveStatusLineSpec(null),
        120,
      ).join('\n');
      expect(row, contains('20 t/s'));
      expect(row, isNot(contains('avg '))); // no completed turn → hidden

      script.gate.complete();
      await run;
      // handleLineForTest resolves at turn end; the busy gate holds
      // through the post-run phase — wait for the settle the band dims on.
      await waitForIt(() => cli.statusLineSnapshotForTest().idle);

      // Settled: the live number hides (never a stale t/s); the session
      // average is ledger output (100) over active-stream time (the 1.5s
      // inter-delta gap caps at the 1s grace) = 100 t/s.
      final after = cli.statusLineSnapshotForTest();
      expect(after.tokensPerSecond, isNull);
      expect(after.idle, isTrue);
      expect(after.tokensPerSecondAvg, closeTo(100.0, 1e-9));

      // The classic footer shows the same numbers the band does: the
      // live part only while busy, the average persists after settle.
      final footer = cli.statusLineForTest();
      expect(footer, isNot(contains(' t/s')));
      expect(footer, contains('avg 100'));
    },
  );

  test(
    'IT-RATE-2: AC4 — turn-end calibration reaches the next turn '
    'through the run loop',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = _cliFor(clock, script, io);

      // Turn 1: 80 streamed chars estimate 20 tok; usage says 100 → the
      // factor jumps toward 100/20 and clamps at 4x.
      final run1 = cli.handleLineForTest('hi');
      await waitForIt(() => script.deltasSeen >= 1);
      script.gate.complete();
      await run1;
      await waitForIt(() => cli.statusLineSnapshotForTest().idle);

      // Idle past the rolling window, then a second turn on the SAME cli
      // (the same meter).
      clock.ms = 6000;
      script.gate = Completer<void>();
      final run2 = cli.handleLineForTest('again');
      await waitForIt(() => script.deltasSeen >= 3);

      // Turn 2's first burst estimates 10 tok × 4 (calibrated) = 40 —
      // the uncalibrated estimate would read 20 t/s here, not 80.
      clock.ms = 6500;
      await waitForIt(
        () => cli.statusLineSnapshotForTest().tokensPerSecond != null,
      );
      expect(
        cli.statusLineSnapshotForTest().tokensPerSecond,
        closeTo(80.0, 1e-9),
      );

      script.gate.complete();
      await run2;
      await waitForIt(() => cli.statusLineSnapshotForTest().idle);

      // The ledger now holds 200 output tokens; active-stream time is
      // turn 1's 1s + turn 2's capped 1s + real 1s = 3s.
      final after = cli.statusLineSnapshotForTest();
      expect(after.tokensPerSecondAvg, closeTo(200 * 1000 / 3000, 1e-6));
    },
  );

  test(
    'IT-RATE-3: AC7 — a long mid-turn gap decays the live rate to hidden '
    'and stays out of the average denominator',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = _cliFor(clock, script, io);
      final run = cli.handleLineForTest('hi');
      await waitForIt(() => script.deltasSeen >= 1);

      // The "tool execution" gap: the clock jumps 12s while the run sits
      // gated. The t0 sample is far older than the 5s window — hidden.
      clock.ms = 12000;
      await waitForIt(
        () => cli.statusLineSnapshotForTest().tokensPerSecond == null,
      );
      expect(cli.statusLineSnapshotForTest().tokensPerSecond, isNull);

      script.gate.complete();
      await run;
      await waitForIt(() => cli.statusLineSnapshotForTest().idle);

      // The average's denominator capped the 12s gap at the 1s grace:
      // 100 tok over ~1s of counted active time — not 100 tok / 12s.
      final after = cli.statusLineSnapshotForTest();
      expect(after.tokensPerSecondAvg, closeTo(100.0, 1e-9));
      expect(after.tokensPerSecondAvg, isNot(closeTo(100 / 12, 0.5)));
    },
  );

  test(
    'IT-RATE-4: AC6 — a whole-message (no-delta) arrival still feeds the '
    'meter: the burst counts, and the average exists across turns',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final script = _GatedRateStream(clock, streamDeltas: false);
      final cli = _cliFor(clock, script, io);

      // Turn 1: the message arrives whole — MessageEnd's estimateTokens
      // top-up is the burst. One burst alone has no elapsed print time,
      // so the average stays honestly hidden.
      final run1 = cli.handleLineForTest('hi');
      script.gate.complete();
      await run1;
      await waitForIt(() => cli.statusLineSnapshotForTest().idle);
      expect(cli.statusLineSnapshotForTest().tokensPerSecondAvg, isNull);

      // Turn 2: the second burst's gap against the first caps at the 1s
      // grace → 200 ledger tokens over ~1s of counted active time.
      clock.ms = 6000;
      script.gate = Completer<void>();
      final run2 = cli.handleLineForTest('again');
      script.gate.complete();
      await run2;
      await waitForIt(() => cli.statusLineSnapshotForTest().idle);

      final after = cli.statusLineSnapshotForTest();
      expect(after.tokensPerSecondAvg, closeTo(200.0, 1e-9));
    },
  );

  test('IT-RATE-5: fresh idle CLI — both numbers hidden (AC2); the classic '
      'footer is byte-identical to pre-gh-1762 (the part is empty)', () async {
    final cli = _cliFor(clock, script, io);
    final snapshot = cli.statusLineSnapshotForTest();
    expect(snapshot.tokensPerSecond, isNull);
    expect(snapshot.tokensPerSecondAvg, isNull);
    final footer = cli.statusLineForTest();
    expect(footer, isNot(contains(' t/s')));
    expect(footer, isNot(contains('avg ')));
  });
}
