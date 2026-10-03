@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A scriptable monotonic clock: the window must be measured on elapsed
/// time, so tests advance it explicitly instead of faking wall clock.
/// Every stopwatch the policy creates registers itself so a test step can
/// advance all of them at once.
final class FakeStopwatch implements Stopwatch {
  FakeStopwatch(this._registry) {
    _registry.add(this);
  }

  final List<FakeStopwatch> _registry;
  Duration _elapsed = Duration.zero;
  bool _running = false;

  /// Advances every stopwatch created for the current test.
  void advanceAll(Duration d) {
    for (final sw in _registry) {
      if (sw._running) sw._elapsed += d;
    }
  }

  @override
  Duration get elapsed => _elapsed;
  @override
  int get elapsedTicks => _elapsed.inMicroseconds;
  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;
  @override
  int frequency = 1000000;
  @override
  bool get isRunning => _running;
  @override
  void start() => _running = true;
  @override
  void stop() => _running = false;
  @override
  void reset() => _elapsed = Duration.zero;
}

void main() {
  group('SigintPolicy (issue #830 double-press contract)', () {
    late List<FakeStopwatch> clocks;
    late FakeStopwatch clock;

    setUp(() {
      clocks = [];
      clock = FakeStopwatch(clocks); // registered first, for advanceAll
    });

    FakeStopwatch Function() makeStopwatch() =>
        () => FakeStopwatch(clocks);
    void advance(Duration d) => clock.advanceAll(d);

    test('headless exits immediately on every press — no window', () {
      final policy = SigintPolicy(stopwatch: makeStopwatch());
      expect(policy.press(headless: true), SigintAction.exitHeadless);
      expect(policy.press(headless: true), SigintAction.exitHeadless);
      expect(policy.armed, isFalse, reason: 'headless bypasses the window');
    });

    test('press 1 stays; press 2 within the window exits', () {
      final policy = SigintPolicy(stopwatch: makeStopwatch());
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      expect(policy.armed, isTrue);
      advance(const Duration(milliseconds: 2999)); // inside the 3 s window
      expect(policy.press(headless: false), SigintAction.exitInteractive);
      expect(policy.armed, isFalse, reason: 'press 2 consumed the window');
    });

    test('a press past the window is a fresh press 1 (ACX.3)', () {
      final policy = SigintPolicy(
        window: const Duration(seconds: 3),
        stopwatch: makeStopwatch(),
      );
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      advance(const Duration(milliseconds: 3001)); // window expired
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      advance(const Duration(milliseconds: 1499)); // inside the NEW window
      expect(policy.press(headless: false), SigintAction.exitInteractive);
    });

    test('a clock stepped backwards cannot fake a press 2 (monotonic)', () {
      // Wall-clock DateTimes can jump backwards (NTP, VM pause); elapsed
      // time on a Stopwatch cannot. A minutes-late press must stay a
      // fresh press 1 regardless of what the wall clock did.
      final policy = SigintPolicy(stopwatch: makeStopwatch());
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      advance(const Duration(minutes: 7));
      expect(
        policy.press(headless: false),
        SigintAction.interruptAndStay,
        reason: 'the window measures elapsed time, not wall-clock gaps',
      );
    });

    test('any other input resets the window (ACX.5 reset-on-input)', () {
      final policy = SigintPolicy(stopwatch: makeStopwatch());
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      advance(const Duration(seconds: 2));
      policy.noteOtherInput(); // the user typed something in between
      expect(policy.armed, isFalse);
      expect(
        policy.press(headless: false),
        SigintAction.interruptAndStay,
        reason: 'fresh press 1, not an exit',
      );
      advance(const Duration(seconds: 2));
      expect(policy.press(headless: false), SigintAction.exitInteractive);
    });

    test('the hint wording is shared by every surface', () {
      expect(kCtrlCExitHint, 'press ctrl+c again to exit');
    });

    test('the window is a contract constant (tests track it both ways)', () {
      expect(kSigintPressWindow, const Duration(seconds: 3));
    });

    test('line-mode stderr hint dims only when ANSI is available', () {
      expect(
        dimCtrlCExitHint(supportsAnsiEscapes: true),
        '\x1b[2mpress ctrl+c again to exit\x1b[22m',
      );
      expect(
        dimCtrlCExitHint(supportsAnsiEscapes: false),
        'press ctrl+c again to exit',
        reason: 'piped runs must not see escape bytes',
      );
    });
  });

  group('press-window env override (gh-1014 PTY seam)', () {
    test('a positive millisecond value widens the window', () {
      expect(
        resolveSigintWindowOverride(
          env: const {'FA_SIGINT_WINDOW_MS': '12000'},
        ),
        const Duration(seconds: 12),
      );
    });

    test('absent, blank, non-numeric, zero and negative keep the contract '
        'window (null)', () {
      Duration? resolve(Map<String, String> env) =>
          resolveSigintWindowOverride(env: env);
      expect(resolve(const {}), isNull);
      expect(resolve(const {'FA_SIGINT_WINDOW_MS': ''}), isNull);
      expect(resolve(const {'FA_SIGINT_WINDOW_MS': 'soon'}), isNull);
      expect(resolve(const {'FA_SIGINT_WINDOW_MS': '0'}), isNull);
      expect(resolve(const {'FA_SIGINT_WINDOW_MS': '-250'}), isNull);
    });

    test('the parsed override drives the policy window end to end', () {
      final window = resolveSigintWindowOverride(
        env: const {'FA_SIGINT_WINDOW_MS': '750'},
      )!;
      final clocks = <FakeStopwatch>[];
      final policy = SigintPolicy(
        window: window,
        stopwatch: () => FakeStopwatch(clocks),
      );
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      for (final sw in clocks) {
        sw.advanceAll(const Duration(milliseconds: 751)); // 750 ms expired
      }
      expect(
        policy.press(headless: false),
        SigintAction.interruptAndStay,
        reason: 'a press past the overridden window is a fresh press 1',
      );
      for (final sw in clocks) {
        sw.advanceAll(const Duration(milliseconds: 300)); // inside NEW window
      }
      expect(policy.press(headless: false), SigintAction.exitInteractive);
    });
  });

  group('AgentCli sigintPolicy injection (ACX.5 one-instance wiring)', () {
    AgentCli cliFor({SigintPolicy? sigintPolicy}) => AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: FakeCliIO(),
      streamFunction: FakeStreamFunction([textTurn('idle')]).call,
      sigintPolicy: sigintPolicy,
    );

    test(
      'an injected policy IS the cli policy — both input paths share it',
      () {
        final injected = SigintPolicy(window: const Duration(seconds: 9));
        expect(
          identical(cliFor(sigintPolicy: injected).sigintPolicy, injected),
          isTrue,
        );
      },
    );

    test('omitted → the contract default window', () {
      expect(cliFor().sigintPolicy.window, kSigintPressWindow);
    });
  });
}
