/// Unit tests for the headless run-lifecycle config and drain policy
/// (gh-1459): the `headless:` yaml section, the pure drain decision
/// (active jobs → drain; none → exit; ceiling exceeded → detach), and the
/// pure liveness-steer decision (ask #4: one notice per quiet-threshold
/// crossing, skipped when the model probed the job since the last one).
library;

import 'package:flutter_agent_harness/src/cli/headless_config.dart';
import 'package:test/test.dart';

void main() {
  group('HeadlessConfig', () {
    test('default drain ceiling is 30 minutes', () {
      const config = HeadlessConfig();
      expect(config.shellJobDrainMs, 30 * 60 * 1000);
      expect(defaultShellJobDrainMs, 30 * 60 * 1000);
    });

    test('fromYaml(null) keeps defaults', () {
      expect(HeadlessConfig.fromYaml(null).shellJobDrainMs, 30 * 60 * 1000);
    });

    test('fromYaml parses shellJobDrainMs', () {
      expect(
        HeadlessConfig.fromYaml({'shellJobDrainMs': 60000}).shellJobDrainMs,
        60000,
      );
    });

    test('fromYaml accepts 0 (the drain kill switch)', () {
      expect(
        HeadlessConfig.fromYaml({'shellJobDrainMs': 0}).shellJobDrainMs,
        0,
      );
    });

    test('fromYaml rejects unknown keys, negatives, and non-integers', () {
      expect(() => HeadlessConfig.fromYaml({'bogus': 1}), throwsA(anything));
      expect(
        () => HeadlessConfig.fromYaml({'shellJobDrainMs': -1}),
        throwsA(anything),
      );
      expect(
        () => HeadlessConfig.fromYaml({'shellJobDrainMs': 'soon'}),
        throwsA(anything),
      );
      expect(() => HeadlessConfig.fromYaml('nope'), throwsA(anything));
    });

    test('toYaml round-trips through fromYaml', () {
      const config = HeadlessConfig(shellJobDrainMs: 5000);
      expect(config.toYaml(), contains('shellJobDrainMs: 5000'));
    });

    test('default liveness cadence is 5 minutes', () {
      const config = HeadlessConfig();
      expect(config.shellJobQuietMs, 5 * 60 * 1000);
      expect(defaultShellJobQuietMs, 5 * 60 * 1000);
    });

    test('fromYaml parses shellJobQuietMs', () {
      final config = HeadlessConfig.fromYaml({'shellJobQuietMs': 30000});
      expect(config.shellJobQuietMs, 30000);
      // Untouched knobs keep their defaults.
      expect(config.shellJobDrainMs, 30 * 60 * 1000);
    });

    test('fromYaml accepts 0 for shellJobQuietMs (liveness off)', () {
      expect(
        HeadlessConfig.fromYaml({'shellJobQuietMs': 0}).shellJobQuietMs,
        0,
      );
    });

    test('fromYaml rejects a bad shellJobQuietMs like the drain knob', () {
      expect(
        () => HeadlessConfig.fromYaml({'shellJobQuietMs': -1}),
        throwsA(anything),
      );
      expect(
        () => HeadlessConfig.fromYaml({'shellJobQuietMs': 'soon'}),
        throwsA(anything),
      );
    });
  });

  group('headlessJobDrainAction (the pure drain decision, gh-1459)', () {
    final now = DateTime.utc(2026, 10, 9, 13, 42);
    final deadline = now.add(const Duration(minutes: 30));
    HeadlessDrainAction decide({
      bool sub = false,
      bool shell = false,
      DateTime? at,
      bool disabled = false,
    }) => headlessJobDrainAction(
      hasActiveSubAgents: sub,
      hasActiveShellJobs: shell,
      now: at ?? now,
      deadline: deadline,
      shellDrainDisabled: disabled,
    );
    test('active jobs with ceiling budget → drain', () {
      expect(decide(sub: true), HeadlessDrainAction.drain);
      expect(decide(shell: true), HeadlessDrainAction.drain);
      expect(decide(sub: true, shell: true), HeadlessDrainAction.drain);
    });
    test('no active jobs → exit (regardless of the ceiling)', () {
      expect(decide(), HeadlessDrainAction.exit);
      expect(
        decide(at: deadline.add(const Duration(hours: 1))),
        HeadlessDrainAction.exit,
      );
    });
    test('ceiling exceeded with active jobs → detach (the shared ceiling)', () {
      expect(decide(sub: true, shell: true, at: deadline), HeadlessDrainAction.detach);
      expect(
        decide(shell: true, at: deadline.add(const Duration(seconds: 1))),
        HeadlessDrainAction.detach,
      );
      // Subagents too — under a non-zero ceiling BOTH legs share it.
      expect(
        decide(sub: true, at: deadline.add(const Duration(seconds: 1))),
        HeadlessDrainAction.detach,
      );
    });
    test(
      'shellDrainDisabled (shellJobDrainMs: 0) with ONLY subagents → drain — '
      'the kill switch is shell-job-scoped; the pre-gh-1459 subagent '
      'drain stays unconditional',
      () {
        expect(decide(sub: true, disabled: true), HeadlessDrainAction.drain);
        // Even with the ceiling spent: subagent-only waits ignore it.
        expect(
          decide(sub: true, at: deadline.add(const Duration(hours: 1)), disabled: true),
          HeadlessDrainAction.drain,
        );
      },
    );
    test(
      'shellDrainDisabled with shell jobs → detach immediately (even with '
      'ceiling budget)',
      () {
        expect(decide(shell: true, disabled: true), HeadlessDrainAction.detach);
        expect(
          decide(sub: true, shell: true, disabled: true),
          HeadlessDrainAction.detach,
        );
        expect(decide(disabled: true), HeadlessDrainAction.exit);
      },
    );
  });

  group('headlessDrainDetachCause (the detach-line attribution, gh-1459)', () {
    test('the ceiling spent names the ceiling', () {
      expect(
        headlessDrainDetachCause(drainMs: 1800000, roundCapEnded: false),
        'drain ceiling (1800000 ms)',
      );
    });
    test('the 10-round cap ending the drain names the cap, not the ceiling', () {
      expect(
        headlessDrainDetachCause(drainMs: 1800000, roundCapEnded: true),
        'round cap (10 rounds)',
      );
    });
  });

  group(
    'headlessJobLivenessAction (the pure liveness decision, gh-1459 ask #4)',
    () {
      const quietMs = 5 * 60 * 1000;
      test('a crossed quiet threshold with no probe → steer', () {
        expect(
          headlessJobLivenessAction(
            elapsedMs: 5 * 60 * 1000,
            quietMs: quietMs,
            lastConsumedBucket: 0,
            probedSinceLastConsumption: false,
          ),
          HeadlessLivenessAction.steer,
        );
        expect(
          headlessJobLivenessAction(
            elapsedMs: 10 * 60 * 1000 + 1,
            quietMs: quietMs,
            lastConsumedBucket: 1,
            probedSinceLastConsumption: false,
          ),
          HeadlessLivenessAction.steer,
        );
      });
      test('below the first threshold, or a consumed one → wait', () {
        expect(
          headlessJobLivenessAction(
            elapsedMs: quietMs - 1,
            quietMs: quietMs,
            lastConsumedBucket: 0,
            probedSinceLastConsumption: false,
          ),
          HeadlessLivenessAction.wait,
        );
        expect(
          headlessJobLivenessAction(
            elapsedMs: 10 * 60 * 1000,
            quietMs: quietMs,
            lastConsumedBucket: 2,
            probedSinceLastConsumption: false,
          ),
          HeadlessLivenessAction.wait,
        );
      });
      test('a probe since the last consumption → skip (the crossing is '
          'consumed, never re-steered)', () {
        expect(
          headlessJobLivenessAction(
            elapsedMs: 10 * 60 * 1000,
            quietMs: quietMs,
            lastConsumedBucket: 1,
            probedSinceLastConsumption: true,
          ),
          HeadlessLivenessAction.skip,
        );
      });
      test('quietMs 0 disables liveness entirely', () {
        expect(
          headlessJobLivenessAction(
            elapsedMs: 60 * 60 * 1000,
            quietMs: 0,
            lastConsumedBucket: 0,
            probedSinceLastConsumption: false,
          ),
          HeadlessLivenessAction.wait,
        );
      });
    },
  );

  group('headlessLivenessElapsedText (the notice elapsed clause)', () {
    test('minutes at and past the first minute, seconds below', () {
      expect(headlessLivenessElapsedText(const Duration(minutes: 12)), '12m');
      expect(headlessLivenessElapsedText(const Duration(minutes: 5)), '5m');
      expect(headlessLivenessElapsedText(const Duration(seconds: 45)), '45s');
    });
    test('a negative elapsed (fake-clock seam) clamps to 0s, never "-3s"', () {
      // ShellJobEntry.startedAt is real DateTime.now() while the drain ITs
      // run on a fake waiting clock — the text must survive the clock
      // sitting behind startedAt.
      expect(headlessLivenessElapsedText(const Duration(milliseconds: -3)), '0s');
      expect(headlessLivenessElapsedText(const Duration(seconds: -90)), '0s');
    });
  });
}
