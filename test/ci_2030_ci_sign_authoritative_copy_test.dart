// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-2030 — the daily-publish cli leg's signing lane failed on BOTH
// matrix archs (build-macos run 41276487426): the x86_64 provisioning
// hung 2h27m on `security import` and died with "SecKeychainItemImport:
// User canceled the operation", and the arm64 xcodebuild died with
// "No certificate for team 'YP9HC3USZ3' matching '43AEC254…' found".
//
// Repo-side root cause: the "the repo copy of ci-sign is authoritative —
// re-install it to the host PATH on every signing job" step (gh-1865
// model v3) was wired ONLY into the `version` job — which runs on
// ubuntu-latest and never executes ci-sign. The one job that DOES
// execute ci-sign on the signing hosts (`build-macos`,
// [self-hosted, macos-m5]) never reinstalls it, so `~/bin/ci-sign` on
// fa-m5-* is whatever the last `host-signing-provision.yml` run copied —
// provably stale today: the 2026-11-01 run log shows
//   `ci-sign: line 92: … Alarm clock: 14 … security set-keychain-settings
//    -t 0 "$KC"`
// a call that NO main-branch revision ever had at line 92 and that
// gh-2008 FINAL (1978de3, 2026-10-31) DELETED entirely — because it
// raises the SecurityAgent GUI password dialog on every invocation and
// the 5s alarm kill leaves an ORPHAN dialog on the host screen, which
// wedges the next `security import` into exactly the 2h+ GUI-prompt hang
// this run produced. The reviewed fixes (gh-2008 shadow sweep + settings
// deletion) can never take effect on the signing hosts until the job
// installs the repo copy itself.
//
// Static workflow-shape assert (the ci_1684 / ci_sign_host_keychain_guard
// pattern): the build-macos job must reinstall the authoritative repo
// copy of scripts/ci-sign — mkdir(1) pairing included (gh-1954: install(1)
// never mkdirs parents) — in a step that runs BEFORE the first ci-sign
// invocation of that job.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const macos = '.github/workflows/build-macos.yml';

YamlList stepsOf(String workflowPath, String job) {
  final body = File(workflowPath).readAsStringSync();
  final jobs = loadYaml(body)['jobs'] as YamlMap;
  return (jobs[job] as YamlMap)['steps'] as YamlList;
}

/// The executable view of a step's run block: comment lines dropped, so a
/// comment MENTIONING `~/bin/ci-sign` (every provisioning step carries the
/// gh-1865 rationale in prose) can never pass for a real invocation or
/// install in the ordering asserts below.
String executableLines(String run) => run
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('#'))
    .join('\n');

void main() {
  test('build-macos installs the authoritative repo ci-sign before any '
      'ci-sign call (gh-2030)', () {
    final steps = stepsOf(macos, 'build-macos');
    final stepRuns = steps
        .map((s) => executableLines(((s as YamlMap)['run'] as String?) ?? ''))
        .toList();

    final firstCiSignUse = stepRuns.indexWhere(
      (run) => run.contains('~/bin/ci-sign'),
    );
    expect(
      firstCiSignUse,
      greaterThanOrEqualTo(0),
      reason:
          'build-macos.yml is expected to call ci-sign — the job '
          'this guard protects disappeared',
    );

    final installStep = stepRuns.indexWhere(
      (run) => run.contains('install -m 755 scripts/ci-sign'),
    );
    expect(
      installStep,
      greaterThanOrEqualTo(0),
      reason:
          'no build-macos step installs the repo copy of scripts/ci-sign '
          'onto the self-hosted signing host — ~/bin/ci-sign drifts to '
          'whatever host-signing-provision.yml last copied (gh-2030: the '
          'host executed a pre-gh-2008 script whose set-keychain-settings '
          'still raises orphan SecurityAgent dialogs and wedged the '
          'x86_64 import for 2h27m)',
    );
    expect(
      installStep,
      lessThanOrEqualTo(firstCiSignUse),
      reason:
          'the authoritative-copy install must not run AFTER the first '
          'ci-sign invocation in build-macos — an install after the '
          'provisioning step would sign with the stale host copy anyway',
    );
    if (installStep == firstCiSignUse) {
      // Same-step shape (the build-mobile.yml iOS signing step pattern):
      // the install must precede the first ci-sign call WITHIN the step.
      final run = stepRuns[installStep];
      expect(
        run.indexOf('install -m 755 scripts/ci-sign'),
        lessThan(run.indexOf('~/bin/ci-sign')),
        reason:
            'the install must precede the first ci-sign invocation '
            'inside the step itself',
      );
    }

    // gh-1954 pairing: install(1) never mkdirs parents — the same step
    // (or the lines directly above it) must create $HOME/bin first.
    final installRun = stepRuns[installStep];
    final context = [
      if (installStep > 0) stepRuns[installStep - 1],
      installRun,
    ].join('\n');
    expect(
      context,
      contains('mkdir -p "\$HOME/bin"'),
      reason:
          'build-macos.yml installs ci-sign into \$HOME/bin — the '
          'parent directory must be created first (install(1) never '
          'mkdirs parents; run 40822964468: "install: invalid target '
          '.../bin/ci-sign: No such file")',
    );
  });
}
