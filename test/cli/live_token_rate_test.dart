// gh-1762 unit tests: the LiveTokenRateMeter pure math on an injected
// clock (UT-RATE-1..6), the shared rate formatter, the two band segments,
// and the `tui.statusLine.rateWindowMs` knob. The IT half (snapshot +
// footer wiring through the CLI harness) lives in agent_cli_token_rate_test.dart.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/live_token_rate_meter.dart';
import 'package:flutter_agent_harness/src/cli/tui_status_line.dart'
    show formatTokenRate;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// A mutable script clock: tests set the ms, the meter reads [call].
final class _ScriptClock {
  _ScriptClock(this.ms);

  int ms;

  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms);
}

LiveTokenRateMeter _meter(_ScriptClock clock, {int windowMs = 5000}) =>
    LiveTokenRateMeter(now: clock.call, windowMs: windowMs);

void main() {
  group('LiveTokenRateMeter live window', () {
    test('hidden before the first delta (never 0 t/s)', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      expect(meter.tokensPerSecond, isNull);
    });

    test('a same-ms burst has no elapsed time yet — still hidden', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40);
      expect(meter.tokensPerSecond, isNull);
    });

    test('UT-RATE-1: the rate tracks scripted delta timing', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40); // 10 tok at t0
      clock.ms = 1000;
      meter.observeDelta(40); // 10 tok at t1000
      expect(meter.tokensPerSecond, closeTo(20.0, 1e-9)); // 20 tok / 1s
    });

    test('UT-RATE-1: the window decays toward hidden (AC7)', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40);
      clock.ms = 1000;
      meter.observeDelta(40);
      // 5500: the t0 sample aged out, the rest decays.
      clock.ms = 5500;
      expect(meter.tokensPerSecond, closeTo(10 * 1000 / 4500, 1e-9));
      // 6001: the last sample is older than the window — hidden.
      clock.ms = 6001;
      expect(meter.tokensPerSecond, isNull);
    });

    test('the window length is the constructor knob (rateWindowMs seam)', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock, windowMs: 3000);
      meter.observeDelta(40);
      clock.ms = 2999;
      expect(meter.tokensPerSecond, isNotNull);
      clock.ms = 3001;
      expect(meter.tokensPerSecond, isNull);
    });

    test('E5: malformed (non-positive) deltas are skipped, never fatal', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(0);
      meter.observeDelta(-3);
      expect(meter.tokensPerSecond, isNull);
    });
  });

  group('LiveTokenRateMeter calibration (AC4)', () {
    test('turn-end usage corrects the char→token base for the next turn', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(480); // estimates 120 tok at factor 1
      meter.calibrate(100); // usage says 100 → factor 100/120
      clock.ms = 6000; // previous window fully aged out
      meter.observeDelta(480); // next turn estimates ~100 now
      clock.ms = 7000;
      expect(meter.tokensPerSecond, closeTo(100.0, 1e-6));
    });

    test('the factor is clamped: one outlier cannot swing it past 4x', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40); // est 10 tok
      meter.calibrate(1000); // raw factor 100 → clamped to 4
      clock.ms = 1000;
      meter.observeDelta(40); // est 40 tok now
      clock.ms = 2000;
      // Window holds both bursts: 10 + 40 = 50 tok over 2s.
      expect(meter.tokensPerSecond, closeTo(25.0, 1e-9));
    });

    test('the factor is clamped downward at 0.25', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(400); // est 100 tok
      meter.calibrate(1); // raw factor 0.01 → clamped to 0.25
      clock.ms = 1000;
      meter.observeDelta(400); // est 25 tok now
      clock.ms = 2000;
      // Window holds both bursts: 100 + 25 = 125 tok over 2s.
      expect(meter.tokensPerSecond, closeTo(62.5, 1e-9));
    });

    test('a zero-usage response skips calibration instead of zeroing', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40);
      meter.calibrate(0);
      clock.ms = 1000;
      meter.observeDelta(40); // still 10 tok at factor 1
      clock.ms = 2000;
      expect(meter.tokensPerSecond, closeTo(10.0, 1e-9));
    });
  });

  group('LiveTokenRateMeter session average (AC3/AC7)', () {
    test('hidden until real output AND real stream time exist', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      expect(meter.tokensPerSecondAvg(0), isNull);
      expect(meter.tokensPerSecondAvg(100), isNull); // no active time yet
      meter.observeDelta(40);
      expect(meter.tokensPerSecondAvg(0), isNull); // no output yet
    });

    test('equals output over accumulated active-stream time', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40); // t0
      clock.ms = 1000;
      meter.observeDelta(40); // t1000: +1000ms active
      clock.ms = 2000;
      meter.observeDelta(40); // t2000: +1000ms active
      expect(meter.tokensPerSecondAvg(100), 50.0); // 100 tok / 2s
    });

    test('UT-RATE-6: long tool gaps are capped out of the denominator', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40); // t0
      clock.ms = 12000; // a 12s tool execution gap
      meter.observeDelta(40);
      clock.ms = 13000;
      meter.observeDelta(40); // +1000ms active (the last gap is short)
      // 12s counted as the 1s grace cap + the real 1s: 2s denominator.
      expect(meter.tokensPerSecondAvg(100), 50.0);
    });
  });

  group('LiveTokenRateMeter whole-message arrival (AC6)', () {
    test('the unobserved remainder lands as one arrival burst', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.startMessage();
      meter.endMessage(100); // whole message, zero deltas
      clock.ms = 1000;
      expect(meter.tokensPerSecond, closeTo(100.0, 1e-9));
    });

    test('a fully-streamed message tops up ~nothing', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.startMessage();
      meter.observeDelta(80); // 20 tok streamed
      meter.endMessage(20); // whole-message estimate agrees
      clock.ms = 1000;
      expect(meter.tokensPerSecond, closeTo(20 * 1000 / 1000, 1e-9));
    });

    test('calibration sees the top-up baseline (estimate beats deltas)', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.startMessage();
      meter.endMessage(120); // whole-message estimate: 120 tok
      meter.calibrate(100); // factor 100/120
      clock.ms = 6000;
      meter.startMessage();
      meter.observeDelta(480);
      clock.ms = 7000;
      expect(meter.tokensPerSecond, closeTo(100.0, 1e-6));
    });
  });

  group('settled average (turn-granular, classic-footer seam)', () {
    test('frozen at the last settle while the next turn keeps streaming', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40); // t0
      clock.ms = 1000;
      meter.observeDelta(40); // t1000: activeMs 1000
      meter.calibrate(100); // settle: the denominator freezes at 1000
      clock.ms = 2000;
      meter.observeDelta(40); // the next turn keeps accruing
      expect(meter.activeMsSettled, 1000);
      expect(meter.settledAverageTokensPerSecond(100), 100.0);
      // The band's live average moved on (2s active now).
      expect(meter.tokensPerSecondAvg(100), closeTo(100 * 1000 / 2000, 1e-9));
    });

    test('hidden until the first settled turn', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40);
      expect(meter.settledAverageTokensPerSecond(100), isNull);
      clock.ms = 1000;
      meter.observeDelta(40);
      meter.calibrate(100);
      expect(meter.settledAverageTokensPerSecond(100), 100.0);
    });

    test('reset clears the settled denominator too', () {
      final clock = _ScriptClock(0);
      final meter = _meter(clock);
      meter.observeDelta(40);
      clock.ms = 1000;
      meter.observeDelta(40);
      meter.calibrate(100);
      meter.reset();
      expect(meter.activeMsSettled, 0);
      expect(meter.settledAverageTokensPerSecond(100), isNull);
    });
  });

  test('reset re-warms the meter (E6: no stale rate across a resume)', () {
    final clock = _ScriptClock(0);
    final meter = _meter(clock);
    meter.observeDelta(400);
    meter.calibrate(100);
    meter.reset();
    expect(meter.tokensPerSecond, isNull);
    expect(meter.tokensPerSecondAvg(100), isNull);
    clock.ms = 1000;
    meter.observeDelta(40); // factor back to 1 → 10 tok
    clock.ms = 2000;
    expect(meter.tokensPerSecond, closeTo(10.0, 1e-9));
  });

  group('formatTokenRate (the shared formatter)', () {
    test('thresholds: one decimal below 100, integer at and above', () {
      expect(formatTokenRate(99.9), '99.9');
      expect(formatTokenRate(99.96), '100'); // rounds up across the edge
      expect(formatTokenRate(100.4), '100');
      expect(formatTokenRate(42.0), '42');
      expect(formatTokenRate(7.24), '7.2');
    });
  });

  group('band segments', () {
    const empty = StatusLineSnapshot(cwd: '/');

    test('token_rate renders the live number, hidden when absent/zero', () {
      const s = StatusLineSnapshot(cwd: '/', tokensPerSecond: 42.0);
      expect(
        kStatusLineSegments['token_rate']!(s, _defaultSpec())!.text,
        '42 t/s',
      );
      // Never a `0 t/s` — data absence hides.
      expect(kStatusLineSegments['token_rate']!(empty, _defaultSpec()), isNull);
      const zero = StatusLineSnapshot(cwd: '/', tokensPerSecond: 0);
      expect(kStatusLineSegments['token_rate']!(zero, _defaultSpec()), isNull);
    });

    test('token_rate_avg renders beside it, hidden until a turn exists', () {
      const s = StatusLineSnapshot(cwd: '/', tokensPerSecondAvg: 38.0);
      expect(
        kStatusLineSegments['token_rate_avg']!(s, _defaultSpec())!.text,
        'avg 38 t/s',
      );
      expect(
        kStatusLineSegments['token_rate_avg']!(empty, _defaultSpec()),
        isNull,
      );
    });
  });

  group('tui.statusLine.rateWindowMs knob', () {
    test('parses a positive int', () {
      final node = loadYaml('preset: default\nrateWindowMs: 3000') as YamlMap;
      expect(parseStatusLineConfig(node).rateWindowMs, 3000);
    });

    test('defaults to null (the meter applies 5000)', () {
      expect(parseStatusLineConfig(null).rateWindowMs, isNull);
    });

    test('rejects non-positive and non-integer values', () {
      for (final yaml in [
        'rateWindowMs: 0',
        'rateWindowMs: -5',
        'rateWindowMs: soon',
      ]) {
        final node = loadYaml(yaml) as YamlMap;
        expect(
          () => parseStatusLineConfig(node),
          throwsA(isA<ConfigException>()),
          reason: yaml,
        );
      }
    });

    test('unknown keys stay strict (the knob joins the known set)', () {
      final node = loadYaml('rateWindowMs: 3000\nrateWindow: 3000') as YamlMap;
      expect(
        () => parseStatusLineConfig(node),
        throwsA(isA<ConfigException>()),
      );
    });

    test('the config round-trips through toYaml', () {
      const config = StatusLineConfig(rateWindowMs: 2500);
      final node = loadYaml('tui:\n${config.toYaml()}') as YamlMap;
      final parsed = parseStatusLineConfig(
        (node['tui'] as YamlMap)['statusLine'] as YamlMap,
      );
      expect(parsed.rateWindowMs, 2500);
    });
  });

  group('presets (AC5)', () {
    test('default preset: no context_total, the rate pair present', () {
      final spec = resolveStatusLineSpec(null);
      expect(spec.right, isNot(contains('context_total')));
      expect(spec.right, containsAll(['token_rate', 'token_rate_avg']));
    });

    test('custom configs referencing context_total still render it (REG)', () {
      final spec = resolveStatusLineSpec(
        const StatusLineConfig(right: ['context_total']),
      );
      const s = StatusLineSnapshot(cwd: '/', contextWindow: 200000);
      final segment = kStatusLineSegments['context_total']!(s, spec);
      expect(segment, isNotNull);
      expect(segment!.text, isNotEmpty);
    });

    test('a default-band render with rate data shows both segments', () {
      final spec = resolveStatusLineSpec(null);
      const s = StatusLineSnapshot(
        cwd: '/w',
        tokensPerSecond: 42,
        tokensPerSecondAvg: 38,
      );
      final row = renderStatusLine(s, spec, 120).join('\n');
      expect(row, contains('42 t/s'));
      expect(row, contains('avg 38 t/s'));
    });

    test('an idle default-band render shows neither', () {
      final spec = resolveStatusLineSpec(null);
      const s = StatusLineSnapshot(cwd: '/w', tokensOut: 100);
      final row = renderStatusLine(s, spec, 120).join('\n');
      expect(row, isNot(contains(' t/s')));
      expect(row, isNot(contains('avg ')));
    });
  });
}

// The default spec helper matches tui_status_line_test's shape.
StatusLineSpec _defaultSpec() => resolveStatusLineSpec(null);
