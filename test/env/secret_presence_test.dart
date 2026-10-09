// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1444 AC4 + IT-secret-presence — secret presence is verifiable without
// leaking: the env listing renders `NAME: PRESENT/ABSENT`, values never
// render, and the roster rides the exec env under FA_SECRET_VARS.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Captures the exec options a delegate receives.
class _CapturingEnv implements ExecutionEnv {
  final List<ShellExecOptions?> calls = [];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    calls.add(options);
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('renderEnvListingWithSecretPresence', () {
    test('a granted secret renders PRESENT, never its value', () {
      final line = renderEnvListingWithSecretPresence({
        'PATH': '/bin',
        'FA_GITHUB_TOKEN': 'ghp_supersecretvalue99',
        secretPresenceEnvVar: 'FA_GITHUB_TOKEN',
      });
      expect(line, contains('FA_GITHUB_TOKEN: PRESENT'));
      expect(line, contains('PATH=/bin'));
      expect(line.contains('ghp_supersecretvalue99'), isFalse);
    });

    test('a rostered name without a value renders ABSENT', () {
      final line = renderEnvListingWithSecretPresence({
        'PATH': '/bin',
        secretPresenceEnvVar: 'FA_GITHUB_TOKEN ANTHROPIC_API_KEY',
      });
      expect(line, contains('FA_GITHUB_TOKEN: ABSENT'));
      expect(line, contains('ANTHROPIC_API_KEY: ABSENT'));
      expect(line, contains('PATH=/bin'));
      expect(line.contains('$secretPresenceEnvVar='), isFalse);
    });

    test('an empty-value secret counts as ABSENT', () {
      final line = renderEnvListingWithSecretPresence({
        'FA_TOKEN': '',
        secretPresenceEnvVar: 'FA_TOKEN',
      });
      expect(line, contains('FA_TOKEN: ABSENT'));
    });

    test('output stays name-sorted with POSIX ? filtered', () {
      final line = renderEnvListingWithSecretPresence({
        '?': '0',
        'ZZZ': '1',
        'AAA': '2',
        secretPresenceEnvVar: '',
      });
      expect(line.split('\n'), ['AAA=2', 'ZZZ=1\n']);
    });
  });

  group('SecretsExecutionEnv roster', () {
    late _CapturingEnv delegate;
    late SecretsExecutionEnv env;

    setUp(() {
      delegate = _CapturingEnv();
      env = SecretsExecutionEnv(delegate, {
        'FA_GITHUB_TOKEN': 'ghp_supersecretvalue99',
      });
    });

    test('every exec carries the roster (names only) and the values', () async {
      await env.exec('env');
      final roster = delegate.calls.single?.env?[secretPresenceEnvVar];
      expect(roster, 'FA_GITHUB_TOKEN');
      expect(delegate.calls.single?.env?['FA_GITHUB_TOKEN'],
          'ghp_supersecretvalue99');
    });

    test('registered known-names ride the roster without values', () async {
      env.registerSecretNames(['ANTHROPIC_API_KEY']);
      await env.exec('env');
      final roster =
          (delegate.calls.single?.env?[secretPresenceEnvVar] ?? '')
              .split(' ')
            ..sort();
      expect(roster, ['ANTHROPIC_API_KEY', 'FA_GITHUB_TOKEN']);
      expect(
        delegate.calls.single?.env?.containsKey('ANTHROPIC_API_KEY'),
        isFalse,
      );
    });

    test('a revoked secret keeps its roster entry (E3)', () async {
      env.revokeSecret('FA_GITHUB_TOKEN');
      await env.exec('env');
      final merged = delegate.calls.single?.env ?? const {};
      expect(merged.containsKey('FA_GITHUB_TOKEN'), isFalse);
      expect(merged[secretPresenceEnvVar], 'FA_GITHUB_TOKEN');
      expect(
        renderEnvListingWithSecretPresence(merged),
        contains('FA_GITHUB_TOKEN: ABSENT'),
      );
    });

    test('byte-scan: no secret value reaches the rendered listing', () async {
      env.registerSecretNames(['OTHER_KEY']);
      await env.exec('env');
      final merged = delegate.calls.single?.env ?? const {};
      final listing = renderEnvListingWithSecretPresence(merged);
      expect(listing.contains('ghp_supersecretvalue99'), isFalse);
    });

    test('per-call env still wins over injected values; roster is fixed',
        () async {
      await env.exec('env', options: const ShellExecOptions(env: {
        'FA_GITHUB_TOKEN': 'percall',
        secretPresenceEnvVar: 'FAKE',
      }));
      final merged = delegate.calls.single?.env ?? const {};
      expect(merged['FA_GITHUB_TOKEN'], 'percall');
      expect(merged[secretPresenceEnvVar], 'FA_GITHUB_TOKEN');
    });
  });
}
