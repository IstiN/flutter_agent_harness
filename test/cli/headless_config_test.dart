/// Unit tests for the headless run-lifecycle config and drain policy
/// (gh-1459): the `headless:` yaml section and the pure drain decision
/// (active jobs → drain; none → exit; ceiling exceeded → detach).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
        HeadlessConfig.fromYaml({
          'shellJobDrainMs': 60000,
        }).shellJobDrainMs,
        60000,
      );
    });

    test('fromYaml accepts 0 (the drain kill switch)', () {
      expect(HeadlessConfig.fromYaml({'shellJobDrainMs': 0}).shellJobDrainMs, 0);
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
  });

  group('headlessJobDrainAction (the pure drain decision, gh-1459)', () {
    final now = DateTime.utc(2026, 10, 9, 13, 42);
    final deadline = now.add(const Duration(minutes: 30));
    test('active jobs with ceiling budget → drain', () {
      expect(
        headlessJobDrainAction(
          hasActiveJobs: true,
          now: now,
          deadline: deadline,
        ),
        HeadlessDrainAction.drain,
      );
    });
    test('no active jobs → exit (regardless of the ceiling)', () {
      expect(
        headlessJobDrainAction(
          hasActiveJobs: false,
          now: now,
          deadline: deadline,
        ),
        HeadlessDrainAction.exit,
      );
      expect(
        headlessJobDrainAction(
          hasActiveJobs: false,
          now: deadline.add(const Duration(hours: 1)),
          deadline: deadline,
        ),
        HeadlessDrainAction.exit,
      );
    });
    test('ceiling exceeded with active jobs → detach', () {
      expect(
        headlessJobDrainAction(
          hasActiveJobs: true,
          now: deadline,
          deadline: deadline,
        ),
        HeadlessDrainAction.detach,
      );
      expect(
        headlessJobDrainAction(
          hasActiveJobs: true,
          now: deadline.add(const Duration(seconds: 1)),
          deadline: deadline,
        ),
        HeadlessDrainAction.detach,
      );
    });
  });
}
