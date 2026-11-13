// gh-2152 — the daily testflight leg died with ZERO diagnosable output:
// the GitHub Actions WORKER on the self-hosted macos-m5 box crashed with
// `System.IO.IOException: No space left on device` writing its own
// `_diag/Worker_*.log` during `Setup Flutter (self-hosted)` (run
// 43371287393, 2026-11-13), because the 3.47.7→3.50.0 pin bump (PR #2141)
// forced a one-time ~2.3 GB archive download + ~6 GB extraction into the
// persistent SDK slot while the superseded 3.47.7 tree (~6 GB) still sat
// under the slot GC's 2-day drain — on a box whose single disk is already
// shared by up to three concurrent runner registrations (gh-2026). The
// sibling `build-macos` arm64 job died the same way ("runner lost
// communication" at the identical setup step).
//
// Cure: a disk preflight + bounded flip-aware reclaim step
// (`scripts/runner_disk_preflight.sh`) early in the self-hosted macOS
// jobs, BEFORE the multi-GB SDK setup:
//
//  AC1  green box (free ≥ floor): exits 0, prints the df diagnosis line,
//       reclaims NOTHING (fresh stage dirs and gym logs survive),
//  AC2  squeezed box with reclaimable content: abandoned SDK `.stage.*`
//       dirs (older than the stage drain) and stale gym logs are removed,
//       fresh ones survive; exit 0 when a re-check reads ≥ floor,
//  AC3  superseded SDK version trees are reclaimed ONLY when the last
//       `current` flip is older than the in-flight drain (4h default >
//       any job's 90–150m ceiling) AND the tree itself is not freshly
//       installed — a tree whose flip is recent (bump day: siblings may
//       still resolve the old tree through `current`) or whose own
//       install is fresh (a concurrent leg's just-landed slot) is NEVER
//       touched — the gh-2134 cross-registration deletion class stays
//       dead,
//  AC4  floor still violated after the reclaim → `::error::` naming the
//       free/floor MB and the owner action, exit 1 — the gh-1478
//       signal-first excerpt quotes a real diagnosis instead of "(no
//       failed-step log available)",
//  AC5  the step is wired into BOTH self-hosted macOS build jobs AFTER
//       checkout and BEFORE the Flutter SDK setup (build-mobile.yml
//       `build-ios`, build-macos.yml `build-macos`) — static workflow
//       shape asserts (the ci_cube_kernel_ceiling_guard_test.dart
//       pattern).
import 'dart:io';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const preflightScript = 'scripts/runner_disk_preflight.sh';

final _fix = Directory.systemTemp.createTempSync('fah_disk_preflight');

/// df stub state: serves [freeMbFirst] while the sentinel path exists
/// and [freeMbSecond] once it is gone. The sentinel is the reclaimable
/// fixture itself (.stage.dead) — the flip simulates the reclaimed
/// bytes WITHOUT counting df invocations (measure_floor probes df
/// several times per path: the ancestor walk + the read).
late final Directory stubBin;
late final Directory stubState;

void writeDfStub({
  required int freeMbFirst,
  required int freeMbSecond,
  required String sentinel,
}) {
  stubState
    ..deleteSync(recursive: true)
    ..createSync();
  File('${stubState.path}/free-first').writeAsStringSync('$freeMbFirst');
  File('${stubState.path}/free-second').writeAsStringSync('$freeMbSecond');
  File('${stubState.path}/sentinel').writeAsStringSync(sentinel);
  File('${stubBin.path}/df').writeAsStringSync(r'''
#!/usr/bin/env bash
# gh-2152 fixture seam: deterministic df -Pm output; a path carrying a
# `-missing` segment fails (nonexistent — exercises the preflight's
# ancestor walk for a fresh runner whose SDK slot root does not exist).
for a in "$@"; do
  case "$a" in *-missing*) exit 1 ;; esac
done
sentinel="$(cat "$FAH_DF_STUB_STATE/sentinel")"
if [ -n "$sentinel" ] && [ ! -e "$sentinel" ]; then
  free="$(cat "$FAH_DF_STUB_STATE/free-second")"
else
  free="$(cat "$FAH_DF_STUB_STATE/free-first")"
fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted-on"
echo "/dev/disk3s1 1000000 900000 $free 90% /System/Volumes/Data"
''');
  Process.runSync('chmod', ['+x', '${stubBin.path}/df']);
}

/// Backdate a path (or symlink itself, never its target) by [days].
void backdate(String path, {double days = 3}) {
  final r = Process.runSync('python3', [
    '-c',
    'import os, sys, time; t = time.time() - $days * 86400; '
        'os.utime(sys.argv[1], (t, t), follow_symlinks=False)',
    path,
  ]);
  expect(r.exitCode, 0, reason: r.stderr);
}

({int code, String out}) runPreflight(List<String> args) {
  final r = Process.runSync(
    'bash',
    [preflightScript, ...args],
    environment: {
      ...Platform.environment,
      'PATH': '${stubBin.path}:${Platform.environment['PATH'] ?? ''}',
      'FAH_DF_STUB_STATE': stubState.path,
      'FAH_SDK_ROOT': '${_fix.path}/flutter-sdk',
      'FAH_GYM_LOG_DIR': '${_fix.path}/gym-logs',
      'FAH_DISK_FLOOR_MB': '100',
      'FAH_FLIP_DRAIN_SEC': '14400',
      'FAH_STAGE_DRAIN_SEC': '360',
      'FAH_GYM_MAX_AGE_SEC': '604800',
    },
    workingDirectory: Directory.current.path,
  );
  return (code: r.exitCode, out: '${r.stdout}${r.stderr}');
}

/// A version tree + a fresh-or-backdated `current` symlink in the fixture
/// SDK root.
void plantSdk({
  required List<String> trees,
  String? currentTarget,
  bool backdateCurrent = false,
  bool backdateTrees = false,
}) {
  final sdk = Directory('${_fix.path}/flutter-sdk')
    ..createSync(recursive: true);
  for (final v in trees) {
    Directory('${sdk.path}/$v/bin').createSync(recursive: true);
    File('${sdk.path}/$v/bin/flutter').writeAsStringSync(v);
    if (backdateTrees) backdate('${sdk.path}/$v');
  }
  if (currentTarget != null) {
    final link = Link('${sdk.path}/current');
    if (link.existsSync()) link.deleteSync();
    link.createSync('${sdk.path}/$currentTarget');
    if (backdateCurrent) backdate(link.path);
  }
}

void plantStages({required bool backdateOld}) {
  final sdk = Directory('${_fix.path}/flutter-sdk');
  for (final name in ['.stage.dead', '.stage.fresh']) {
    Directory('${sdk.path}/$name').createSync(recursive: true);
    File('${sdk.path}/$name/partial.zip').writeAsStringSync('x');
    if (name == '.stage.dead' && backdateOld) {
      backdate('${sdk.path}/$name', days: 0.05); // ~1.2h > the 360s drain
    }
  }
}

void plantGym() {
  final gym = Directory('${_fix.path}/gym-logs')
    ..createSync(recursive: true);
  File('${gym.path}/old.log').writeAsStringSync('x');
  File('${gym.path}/new.log').writeAsStringSync('x');
  backdate('${gym.path}/old.log', days: 8); // > the 7d gym max age
}

void main() {
  setUpAll(() {
    stubBin = Directory('${_fix.path}/bin')..createSync(recursive: true);
    stubState = Directory('${_fix.path}/state')..createSync();
  });
  tearDown(() {
    for (final d in [
      Directory('${_fix.path}/flutter-sdk'),
      Directory('${_fix.path}/gym-logs'),
    ]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('AC1 — green box: exit 0, df diagnosis, nothing reclaimed', () {
    plantSdk(trees: ['3.47.7'], currentTarget: '3.47.7');
    plantStages(backdateOld: true);
    plantGym();
    writeDfStub(freeMbFirst: 500000, freeMbSecond: 500000, sentinel: '');
    // The second path does not exist (fresh-runner shape: the SDK slot
    // root is absent until the first install) — df fails on it and the
    // preflight must measure the nearest existing ancestor's volume.
    final r = runPreflight([_fix.path, '${_fix.path}/slot-root-missing/x']);
    expect(r.code, 0, reason: r.out);
    expect(r.out, contains('gh-2152 disk preflight'));
    expect(
      Directory('${_fix.path}/flutter-sdk/.stage.dead').existsSync(),
      isTrue,
      reason: 'a green box reclaims nothing — not even stale stages',
    );
    expect(File('${_fix.path}/gym-logs/old.log').existsSync(), isTrue);
  });

  test('AC2 — squeezed box: stale stages + gym logs reclaimed, exit 0 on '
      're-check', () {
    plantSdk(trees: ['3.47.7'], currentTarget: '3.47.7');
    plantStages(backdateOld: true);
    plantGym();
    writeDfStub(
      freeMbFirst: 50,
      freeMbSecond: 50000,
      sentinel: '${_fix.path}/flutter-sdk/.stage.dead',
    );
    final r = runPreflight([_fix.path]);
    expect(r.code, 0, reason: r.out);
    expect(
      Directory('${_fix.path}/flutter-sdk/.stage.dead').existsSync(),
      isFalse,
      reason: 'abandoned stage (older than the stage drain) is reclaimed\n'
          '${r.out}',
    );
    expect(
      Directory('${_fix.path}/flutter-sdk/.stage.fresh').existsSync(),
      isTrue,
      reason: 'a live download keeps its mtime fresh and is never touched',
    );
    expect(File('${_fix.path}/gym-logs/old.log').existsSync(), isFalse);
    expect(File('${_fix.path}/gym-logs/new.log').existsSync(), isTrue);
    expect(r.out, contains('reclaim'));
  });

  test('AC3a — bump day: recent flip protects the superseded tree '
      '(in-flight siblings resolve it through current)', () {
    // The 3.47.7 tree was installed 30d ago; the flip to 3.50.0 happened
    // minutes ago (bump day) — 3.47.7 must survive despite its ancient
    // tree mtime.
    plantSdk(
      trees: ['3.47.7', '3.50.0'],
      currentTarget: '3.50.0',
      backdateTrees: true,
    );
    plantStages(backdateOld: true);
    writeDfStub(
      freeMbFirst: 50,
      freeMbSecond: 60,
      sentinel: '${_fix.path}/flutter-sdk/.stage.dead',
    );
    final r = runPreflight([_fix.path]);
    expect(r.code, 1, reason: 'floor still violated → fail fast (AC4 shape)');
    expect(
      Directory('${_fix.path}/flutter-sdk/3.47.7/bin').existsSync(),
      isTrue,
      reason: 'flip younger than the in-flight drain — the old tree may '
          'still be a live sibling\'s resolved SDK (gh-2134 class)',
    );
    expect(r.out, contains('in-flight'));
  });

  test('AC3b — fresh install of a non-current tree survives too', () {
    // 3.46.0: ancient tree, no current protection imaginable — but the
    // last flip is 2 days old (> drain) so it IS reclaim-eligible;
    // 3.48.0: freshly installed seconds ago (a concurrent leg's slot) —
    // protected by its own freshness even though it is not current.
    plantSdk(
      trees: ['3.46.0', '3.48.0'],
      currentTarget: '3.47.4',
      backdateCurrent: true,
      backdateTrees: true,
    );
    backdate('${_fix.path}/flutter-sdk/3.48.0', days: 0.0); // fresh install
    writeDfStub(
      freeMbFirst: 50,
      freeMbSecond: 60,
      sentinel: '${_fix.path}/flutter-sdk/.stage.dead',
    );
    final r = runPreflight([_fix.path]);
    expect(
      Directory('${_fix.path}/flutter-sdk/3.46.0').existsSync(),
      isFalse,
      reason: 'old flip + old tree → reclaimable',
    );
    expect(
      Directory('${_fix.path}/flutter-sdk/3.48.0/bin').existsSync(),
      isTrue,
      reason: 'a seconds-old install may be a concurrent leg staging a '
          'flip — never deleted under it',
    );
    expect(r.code, 1, reason: r.out);
  });

  test('AC4 — floor still violated after reclaim: ::error:: names the '
      'numbers and exits 1', () {
    plantSdk(trees: ['3.47.7'], currentTarget: '3.47.7');
    // Nothing reclaimable exists (no stages, no superseded trees) — the
    // free value never changes and the floor violation is permanent.
    writeDfStub(freeMbFirst: 50, freeMbSecond: 50, sentinel: '');
    final r = runPreflight([_fix.path]);
    expect(r.code, 1);
    expect(r.out, contains('::error::'));
    expect(r.out, contains('gh-2152'));
    expect(r.out, contains('50 MB'));
    expect(r.out, contains('100 MB'));
  });

  test('AC5 — wired into both self-hosted macOS build jobs: AFTER checkout, '
      'BEFORE the Flutter SDK setup', () {
    final wired = <String, List<String>>{
      '.github/workflows/build-mobile.yml': [
        'build-ios',
        'Checkout repository from local mirror',
        'Setup Flutter (self-hosted)',
      ],
      '.github/workflows/build-macos.yml': [
        'build-macos',
        'Checkout repository from local mirrors',
        'Setup Flutter environment',
      ],
    };
    wired.forEach((wf, spec) {
      final job = ((loadYaml(File(wf).readAsStringSync()) as YamlMap)['jobs']
          as YamlMap)[spec[0]] as YamlMap;
      final steps = job['steps'] as YamlList;
      final names = steps
          .whereType<YamlMap>()
          .map((s) => s['name']?.toString() ?? '')
          .toList();
      final checkoutIdx = names.indexOf(spec[1]);
      final setupIdx = names.indexOf(spec[2]);
      expect(checkoutIdx, greaterThan(-1), reason: wf);
      expect(setupIdx, greaterThan(checkoutIdx), reason: wf);
      final preflightIdx = names.indexWhere(
        (n) => n.contains('disk preflight') || n.contains('Disk preflight'),
      );
      expect(
        preflightIdx,
        greaterThan(checkoutIdx),
        reason: '$wf: preflight must run after checkout (the script comes '
            'from the freshly checked-out tree)',
      );
      expect(
        preflightIdx,
        lessThan(setupIdx),
        reason: '$wf: preflight must run BEFORE the multi-GB SDK setup — '
            'the reclaim has to free space before the install transient, '
            'and the floor error has to fire before minutes are spent',
      );
      final run = (steps
          .whereType<YamlMap>()
          .firstWhere((s) => (s['name']?.toString() ?? '')
              .toLowerCase()
              .contains('disk preflight'))['run'] as String);
      expect(run, contains('scripts/runner_disk_preflight.sh'), reason: wf);
    });
  });
}
