// gh-1986 — the build-macos (self-hosted, matrix) leg must run a keychain
// re-unlock WATCHDOG across its whole signing window, the same mechanism
// gh-1954 already gave the iOS gym lane.
//
// HISTORY: daily-publish cli leg, build-macos run 41008008179 (2026-10-30)
// failed on BOTH matrix archs with `errSecInternalComponent` on the FIRST
// codesign of the embed phase (GoogleAppMeasurement.framework) after a
// 2h14m keychain-silent compile. Chain:
//
//   10-29 10:24Z  host-signing-provision --force (gh-1954 roll-out, run
//                 40857357741, fa-m5-2) DELETED and re-created the
//                 persistent ci-signing.keychain-db → create-keychain
//                 defaults restored the ~5-min inactivity auto-lock.
//   10-30 05:25Z  ci-sign install fa-macos unlocked the fresh keychain;
//                 its `set-keychain-settings -t 0` was alarm-killed
//                 ("Alarm clock: 14" — the GUI SecurityAgent prompt the
//                 Fastfile documents as unfixable non-interactively).
//   10-30 07:39Z  after 2h14m with ZERO keychain access, both legs'
//                 first codesign hit the locked keychain simultaneously
//                 (0.4 s apart) and died.
//
// The keychain auto-locks after ~5 min of inactivity and
// set-keychain-settings can never fix it non-interactively on this host
// (screenshot-confirmed, gh-1954 doctrine): the only durable mechanism is
// re-unlocking via `ci-sign unlock` (unlock-keychain -p, never prompts)
// every 60 s for the whole signing window — build, DMG/PKG packaging,
// notarize, no-sandbox build — and stopping it in the always() cleanup.
//
//   AC1  the build-macos provisioning step arms a background unlock
//        watchdog with a ≤60 s cadence that survives the step (disown).
//   AC2  the watchdog is armed ONLY on signed runs — no `ci-sign unlock`
//        may execute before the `[ "$signed" = "true" ]` gate (unsigned
//        builds touch no keychain, and ci-sign unlock dies loudly when
//        the keychain does not exist).
//   AC3  the always() Cleanup step stops the watchdog by the SAME pid
//        file the provisioning step wrote, guarded by a file-existence
//        check AND an identity check (the pid's command line must still
//        be the ci-sign unlock loop — a provisioning failure before
//        watchdog arm must not make Cleanup kill an arbitrary recycled
//        pid).
//   AC4  the Fastfile's gh-1954 gym-lane watchdog still stands (both
//        lanes on the shared host share one invariant).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos';
const provisioningStepName = 'Provision signing via ci-sign (persistent host keychain)';
const cleanupStepName = 'Cleanup';
const fastfilePath = 'flutter_app/fastlane/Fastfile';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String path) => loadYaml(read(path))['jobs'] as YamlMap;

String _stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

YamlMap stepByName(YamlMap job, String name) {
  final steps = job['steps'] as YamlList? ?? YamlList();
  return steps
      .whereType<YamlMap>()
      .firstWhere((s) => (s['name']?.toString() ?? '') == name);
}

String scriptOf(YamlMap job, String stepName) =>
    _stripComments(stepByName(job, stepName)['run'].toString());

void main() {
  final jobs = jobsOf(workflowPath);
  final job = jobs[jobName] as YamlMap;

  test('AC1 — build-macos arms a background keychain unlock watchdog '
      '(≤60 s cadence, survives the step) after provisioning (gh-1986)', () {
    final script = scriptOf(job, provisioningStepName);
    final unlockIdx = script.indexOf('ci-sign unlock');
    expect(unlockIdx, greaterThanOrEqualTo(0), reason:
        'the provisioning step must re-unlock the persistent signing '
        'keychain at watchdog arm time — provisioning and the first '
        'codesign can be hours apart on a full Swift compile');
    expect(script.indexOf('sleep 60'), greaterThan(unlockIdx), reason:
        'the watchdog loop must re-unlock every 60 s — the keychain '
        'auto-locks after ~5 min of inactivity (gh-1954 doctrine, '
        'set-keychain-settings can never fix it non-interactively here)');
    expect(script.contains('disown'), isTrue, reason:
        'the watchdog must be disowned/backgrounded so it survives the '
        'provisioning step and keeps unlocking across the build, '
        'packaging, notarize and no-sandbox steps until Cleanup stops it');
    final watchdogIdx = script.indexOf('ci-sign-watchdog.pid');
    expect(watchdogIdx, greaterThan(unlockIdx), reason:
        'the watchdog pid must be recorded so the always() Cleanup step '
        'can stop the process it did not spawn');
  });

  test('AC2 — the watchdog is armed ONLY on signed runs: no ci-sign '
      'unlock before the signed gate (negative check)', () {
    final script = scriptOf(job, provisioningStepName);
    final gateIdx = script.indexOf('[ "\$signed" = "true" ]');
    expect(gateIdx, greaterThanOrEqualTo(0), reason:
        'the unlock/watchdog block must be gated on signed=true — '
        'unsigned builds use the ad-hoc identity "-" and have no '
        'keychain to keep open');
    final unlockIdx = script.indexOf('ci-sign unlock');
    expect(unlockIdx, greaterThan(gateIdx), reason:
        'no keychain unlock may run on the unsigned path — ci-sign '
        'unlock dies loudly when the signing keychain does not exist, '
        'and the unsigned path must stay keychain-free');
  });

  test('AC3 — the always() Cleanup step stops the watchdog by the same '
      'pid file, existence-guarded AND identity-checked', () {
    final cleanup = stepByName(job, cleanupStepName);
    expect(cleanup['if']?.toString(), contains('always()'), reason:
        'Cleanup must run on failure too — a dead build must not leak a '
        '60 s unlock loop onto the shared host');
    final script = _stripComments(cleanup['run'].toString());
    final guardIdx = script.indexOf('[ -f ci-sign-watchdog.pid ]');
    expect(guardIdx, greaterThanOrEqualTo(0), reason:
        'the kill must be guarded by pid-file existence — a provisioning '
        'failure before the watchdog armed would otherwise make Cleanup '
        'kill an arbitrary (possibly recycled) pid');
    final psIdx = script.indexOf('ps -p "\$WPID" -o command=');
    expect(psIdx, greaterThan(guardIdx), reason:
        'the kill must only consider a pid that exists AND whose command '
        'line is still the ci-sign unlock loop — a pid file outlives its '
        'process and a recycled pid must never be killed');
    final killIdx = script.indexOf('kill');
    expect(killIdx, greaterThan(guardIdx), reason:
        'Cleanup kills only what the provisioning step recorded');
    expect(psIdx, lessThan(killIdx), reason:
        'the identity check must gate the kill');
    expect(script.contains('ci-sign-watchdog.pid'), isTrue, reason:
        'Cleanup must target the SAME pid file the provisioning step '
        'wrote — a renamed marker would orphan the watchdog');
  });

  test('AC4 — the Fastfile gym-lane unlock watchdog (gh-1954) still '
      'stands', () {
    final fastfile = read(fastfilePath);
    final armIdx = fastfile.indexOf('unlock_watchdog = Thread.new');
    expect(armIdx, greaterThanOrEqualTo(0), reason:
        'gh-1954 gave the iOS gym lane the unlock watchdog; the shared '
        'host keeps one keychain, so the invariant is lane-pair-wide');
    expect(fastfile.indexOf('unlock_watchdog.kill'), greaterThan(armIdx),
        reason: 'the gym watchdog must be stopped in the lane ensure');
  });
}
