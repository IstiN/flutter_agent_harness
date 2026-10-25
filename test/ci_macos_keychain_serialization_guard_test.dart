// gh-1852 — the macOS release producer failed 6 of 7 runs over ~48h with
// `Runner.xcodeproj: error: No certificate for team 'YP9HC3USZ3' matching
// '***' found` on the fa-m5 pool, while the SAME certificate imported
// fine in every run (run 40117288269, 2026-10-24, is the reference
// autopsy):
//
//   17:45:32Z  arm64 leg (fa-m5-2)  imports P12 into build-arm64.keychain,
//              then runs `security default-keychain -s` and
//              `security list-keychains -d user -s build-arm64.keychain
//              login.keychain-db`
//   17:46:39Z  x86_64 leg (fa-m5-1) imports P12 into build-x86_64.keychain
//              and REPLACES the user-global search list with
//              [build-x86_64, login] — evicting build-arm64
//   18:03-12Z  x86_64 codesigns fine (its keychain is in the list)
//   18:39:43Z  arm64's final codesign: "No certificate for team ... found"
//              — build-arm64.keychain is still on disk, still unlocked
//              (4h window, machine never slept — MAGICWAKE assertion
//              spans the whole window), but NOT IN the search list, so
//              identity resolution finds nothing
//
// The per-arch keychain-file split (gh-1798-era fix for the shared
// build.keychain delete/create race) did NOT fix the search-list race:
// `security default-keychain -s` and `security list-keychains -d user -s`
// mutate PER-USER GLOBAL state. fa-m5-1/fa-m5-2/fa-m5-3 are three runner
// registrations on ONE host under ONE user account, so the two matrix
// legs stomp each other's search list no matter which registrations they
// land on. Last writer wins; the leg that imports SECOND wins; the other
// leg's codesign finds no identity.
//
// Static workflow-shape assert (the "workflow-shape test never-again"
// pattern of workflow_selfhosted_legs_test.dart /
// workflow_fetch_shape_guard_test.dart):
//
//   AC1  the build-macos matrix (arch: [arm64, x86_64]) must declare
//        `max-parallel: 1` — the legs are serialized so only one of them
//        mutates the user-global keychain search list at a time.
//   AC2  audit: ANY job whose steps run `security default-keychain -s` or
//        `security list-keychains -d user -s` (user-global keychain
//        mutations) while its matrix can fan out to more than one leg
//        must declare `max-parallel: 1`.
//   AC3  audit (gh-1865): any SELF-HOSTED job that mutates the user-
//        global keychain state must pin exactly ONE runner by name
//        (a `fa-m5-<n>` runner-name label). The fa-m5 pool is ONE host
//        under ONE user account: `security list-keychains -d user -s` /
//        `default-keychain -s` from a job on ANY pool runner stomps an
//        in-flight signing job on EVERY other pool runner. Serializing
//        all signing legs through one runner's one-job-at-a-time queue
//        is the only race-free arrangement; a pool-wide pin plus
//        per-leg keychains cannot work on a shared user account.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// True when the job's rendered step scripts mutate the PER-USER GLOBAL
/// keychain state (`default-keychain -s` or `list-keychains -d user -s`)
/// rather than a keychain-local setting.
bool mutatesUserGlobalKeychainState(YamlMap job) {
  final steps = job['steps'] as YamlList? ?? YamlList();
  for (final step in steps.whereType<YamlMap>()) {
    final script = step['run']?.toString() ?? '';
    if (script.contains('default-keychain -s')) return true;
    if (RegExp(r'list-keychains\s+-d\s+user\s+-s').hasMatch(script)) {
      return true;
    }
  }
  return false;
}

/// The maximum number of matrix legs a job can fan out to (null when the
/// job has no matrix).
int? matrixFanout(YamlMap job) {
  final strategy = job['strategy'] as YamlMap?;
  if (strategy == null) return null;
  final maxParallel = strategy['max-parallel'];
  if (maxParallel is int) return maxParallel;
  final matrix = strategy['matrix'] as YamlMap?;
  if (matrix == null) return 1;
  // Fanout = the largest list value in the matrix (cartesian product is
  // at least that large; exactness is unnecessary for the guard — any
  // multi-leg fanout must be serialized).
  var legs = 1;
  for (final value in matrix.values) {
    if (value is YamlList && value.length > legs) legs = value.length;
  }
  return legs;
}

void main() {
  test('AC1 — build-macos matrix is serialized (max-parallel: 1) so its '
      'legs never stomp the user-global keychain search list '
      '(gh-1852)', () {
    final job = jobsOf('.github/workflows/build-macos.yml')['build-macos']
        as YamlMap;
    final maxParallel = (job['strategy'] as YamlMap?)?['max-parallel'];
    expect(
      maxParallel,
      1,
      reason:
          'build-macos signs with a per-arch keychain plus user-global '
          '`security default-keychain -s` / `list-keychains -d user -s` '
          'mutations. The fa-m5 pool is ONE host under ONE user account, '
          'so two concurrent matrix legs replace each other\'s search '
          'list (gh-1852 autopsy, run 40117288269: x86_64 leg evicted '
          'arm64\'s keychain 67s after its import → arm64 codesign died '
          'with "No certificate for team YP9HC3USZ3 matching ... found" '
          'despite a valid, unlocked, imported cert). Serialize the '
          'matrix with `strategy.max-parallel: 1`.',
    );
  });

  test('AC2 — audit: no multi-leg matrix that mutates the user-global '
      'keychain state runs its legs concurrently (gh-1852)', () {
    final workflows = Directory('.github/workflows')
        .listSync()
        .where((f) => f.path.endsWith('.yml'))
        .toList();
    expect(workflows, isNotEmpty);
    for (final f in workflows) {
      final jobs = jobsOf(f.path);
      for (final e in jobs.entries) {
        final job = e.value as YamlMap;
        if (!mutatesUserGlobalKeychainState(job)) continue;
        final fanout = matrixFanout(job);
        if (fanout == null || fanout <= 1) continue;
        expect(
          (job['strategy'] as YamlMap)['max-parallel'],
          1,
          reason:
              '${f.path} job "${e.key}" mutates the PER-USER GLOBAL '
              'keychain search list (`security default-keychain -s` / '
              '`list-keychains -d user -s`) and its matrix can fan out '
              'to $fanout legs. On a host where several runner '
              'registrations share one user account (the fa-m5 pool), '
              'concurrent legs replace each other\'s search list and the '
              'loser\'s codesign finds no signing identity '
              '(gh-1852: "No certificate for team ... found", 6/7 red '
              'runs). Declare `strategy.max-parallel: 1`.',
        );
      }
    }
  });

  test('AC3 — audit: every self-hosted job that mutates the user-global '
      'keychain state pins exactly ONE runner by name (gh-1865)', () {
    final workflows = Directory('.github/workflows')
        .listSync()
        .where((f) => f.path.endsWith('.yml'))
        .toList();
    expect(workflows, isNotEmpty);
    for (final f in workflows) {
      final jobs = jobsOf(f.path);
      for (final e in jobs.entries) {
        final job = e.value as YamlMap;
        if (!mutatesUserGlobalKeychainState(job)) continue;
        final runsOn = job['runs-on']?.toString() ?? '';
        if (!runsOn.contains('self-hosted')) continue;
        expect(
          RegExp(r'\bfa-m5-\d+\b').hasMatch(runsOn),
          isTrue,
          reason:
              '${f.path} job "${e.key}" mutates the PER-USER GLOBAL '
              'keychain search list (`security default-keychain -s` / '
              '`list-keychains -d user -s`) but pins "${runsOn}" — a '
              'label set any pool runner satisfies. The fa-m5 pool is '
              'ONE host under ONE user account, so a signing job on any '
              'pool runner stomps an in-flight signing job on every '
              'other pool runner (gh-1865 autopsy, run 40165498619: a '
              'build-mobile iOS job on fa-m5-3 replaced the search list '
              '84s after the macOS arm64 leg\'s import → arm64 codesign '
              'died with "No certificate for team ... found"). Pin '
              'exactly one runner by name (`fa-m5-1`) so ALL signing '
              'legs serialize through that runner\'s queue. Note '
              '(gh-1865): manually adding the `fa-m5-1` NAME LABEL to '
              'other registrations silently defeats this pin — keep the '
              'label exclusive to the fa-m5-1 registration.',
        );
      }
    }
  });
}
