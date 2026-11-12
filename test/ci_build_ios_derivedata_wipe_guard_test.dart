// gh-2134 — the build-ios stale-pcm wipe must never reach another
// checkout's DerivedData on the shared fa-m5 box.
//
// CI run 43203130726 (v1.0.712, 2026-11-12) red'd the release train: the
// `Build iOS (debug, unsigned)` leg died 281 s into its xcodebuild with
// `accessing build database ".../DerivedData/Runner-bdeltrtwvfjmnocetzuxfpyqvkmk/
// .../build.db": disk I/O error` + `Runner-OutputFileMap.json couldn't be
// opened because there is no such file`. The killer was the step's own
// stale-pcm wipe `rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*` —
// a HOME-global glob. The self-hosted `macos-m5` pool is ONE physical box
// (`/Users/uladzimir_klyshevich`) hosting MULTIPLE concurrent runner
// processes (fa-m5-1/2/3; the ci.yml header's "ONE runner" note is stale),
// so sibling runs' build-ios legs share `$HOME` and its DerivedData. The
// exact timeline (both jobs' API logs):
//   10:46:52  our build-ios starts on fa-m5-1 (workspace
//             .../runners/fa-m5/_work/..., DerivedData Runner-bdeltr…)
//   10:51:56  our xcodebuild starts
//   10:54:11  sibling run 43202707134's build-ios starts on fa-m5-2
//             (workspace .../runners/fa-m5-2/_work/..., its OWN hash dir)
//   10:55:32  fa-m5-2 runs the same glob wipe — deletes OUR live dir
//   10:56:38  our build collapses with the mid-build-deletion signature;
//             the fa-m5-2 leg finishes green (11:04:57)
// The DerivedData dir hash is keyed to the checkout path, so each runner
// process owns a private dir — the global glob is the only mechanism that
// reaches across checkouts, and with a 3-runner pool the overlap is
// routine, not a flake.
//
// Cure: scope the wipe to THIS checkout via the `WorkspacePath` entry in
// each `Runner-*/info.plist` (the absolute workspace path that created the
// dir) — concurrent legs can never match each other. Deliberately
// YAML-level asserts (the ci_cube_kernel_ceiling_guard_test.dart static
// pattern):
//  AC1  the build step carries NO destructive HOME-global wipe over
//       `DerivedData/Runner-*` — any `rm -rf` targeting the shared
//       DerivedData root/glob must be gone (a re-introduction red here),
//  AC2  the wipe resolves each candidate's `info.plist` `WorkspacePath`
//       with PlistBuddy and removes only the dir whose WorkspacePath
//       equals this checkout's `flutter_app/ios/Runner.xcworkspace` — the
//       removal's argument must be the matched per-dir variable, never a
//       bare glob,
//  AC3  the stale-`.pcm` protection survives: the scoped wipe still runs
//       unconditionally on every build BEFORE `flutter build ios`
//       (gh-1296-era "FlutterPlugin.h has been modified since the module
//       file was built" class stays covered),
//  AC4  the leg stays routed to the shared `macos-m5` pool — the fix must
//       never arrive packaged with a reroute off the one genuinely
//       macOS-only gate box (same re-assert discipline as
//       ci_cube_kernel_ceiling_guard_test.dart AC2),
//  AC5  the wipe is OBSERVABLE: the matched removal logs a `gh-2134:`
//       line and a pass with no candidate logs its own line — a silent
//       runtime no-op (WorkspacePath spelling divergence, symlinked
//       workspace) must be diagnosable from CI logs alone (gh-2136
//       review thread 1; the YAML-level shape asserts cannot see a
//       no-op, so AC7 runs the block for real),
//  AC6  orphan `Runner-*` dirs whose recorded `WorkspacePath` no longer
//       exists on disk are swept in the same loop (dead checkouts from
//       re-registered runners / renumbered `_work` / deleted branches
//       otherwise accumulate multiple GB toward disk exhaustion — the
//       same "disk I/O error" class). Race-free by construction: a live
//       leg's checkout always exists, and a dir with NO readable
//       info.plist may be a live early build and stays untouched
//       (gh-2136 review thread 2),
//  AC7  the extracted block is EXECUTED against a fixture DerivedData
//       tree with a PlistBuddy stub: owned dir removed + logged, live
//       sibling and plist-less dirs survive, orphan removed + logged,
//       exit 0 under the step's shell shape; the no-candidate pass
//       emits the distinct no-match line.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const buildIosJobId = 'build-ios';
const buildStepName = 'flutter build ios (debug, unsigned)';

YamlMap ciRoot() => loadYaml(read(ci)) as YamlMap;

YamlMap buildIosJob() {
  final jobs = ciRoot()['jobs'] as YamlMap;
  final job = jobs[buildIosJobId];
  if (job is! YamlMap) throw StateError('job $buildIosJobId missing from $ci');
  return job;
}

YamlMap buildStep() {
  final steps = (buildIosJob()['steps'] as YamlList).whereType<YamlMap>();
  for (final s in steps) {
    if (s['name'] == buildStepName) return s;
  }
  throw StateError('step "$buildStepName" missing from $buildIosJobId');
}

/// The step's `run:` block as plain text.
String buildStepRun() => buildStep()['run'].toString();

/// Every `rm -rf` invocation line inside the step's run block.
List<String> rmLines() =>
    buildStepRun().split('\n').where((l) => l.contains('rm -rf')).toList();

/// The wipe block verbatim — from the `ws_path=` line through the closing
/// `shopt -u nullglob` — extracted from the step's run block so AC7 can
/// execute it against fixtures.
String wipeBlock() {
  final lines = buildStepRun().split('\n');
  final start = lines.indexWhere(
    (l) => l.trimLeft().startsWith('ws_path='),
  );
  final end = lines.indexWhere(
    (l) => l.trimLeft().startsWith('shopt -u nullglob'),
  );
  expect(start, greaterThan(-1), reason: 'wipe block start marker missing');
  expect(end, greaterThan(start), reason: 'wipe block end marker missing');
  return lines.sublist(start, end + 1).join('\n');
}

/// One fixture DerivedData candidate: `dir` carries `plistContent` (the
/// recorded WorkspacePath) in its `info.plist`, or no plist at all.
void fixtureCandidate(Directory dd, String name, String? plistContent) {
  final dir = Directory('${dd.path}/$name')..createSync(recursive: true);
  if (plistContent != null) {
    File('${dir.path}/info.plist').writeAsStringSync(plistContent);
  }
}

/// Runs the extracted wipe block for real: `/usr/libexec/PlistBuddy` is
/// substituted with a stub that cats the fixture plist (the sim harness
/// substitution — the block text itself is unmodified), and `$HOME` is
/// pointed at the fixture home so the `~/Library/...` glob lands there.
Future<ProcessResult> runWipeSimulation(Directory tmp) {
  final stubDir = Directory('${tmp.path}/pb-stub')..createSync(recursive: true);
  final stub = File('${stubDir.path}/PlistBuddy');
  stub.writeAsStringSync('#!/usr/bin/env bash\nexec cat "$3"\n');
  stub.setSync(executable: true);
  final block = wipeBlock().replaceAll('/usr/libexec/PlistBuddy', stub.path);
  expect(
    block.contains(stub.path),
    isTrue,
    reason: 'PlistBuddy substitution must hit the extracted block',
  );
  final home = Directory('${tmp.path}/home');
  final wsRoot = Directory('${tmp.path}/ws/flutter_app');
  return Process.run(
    'bash',
    ['-c', block],
    workingDirectory: wsRoot.path,
    environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
  );
}

/// Builds the AC7 fixture tree: a fixture home with a DerivedData holding
/// the owned dir, a LIVE sibling leg's dir, an orphan whose checkout is
/// gone, and a plist-less dir; plus the two workspace trees (owned cwd +
/// sibling). Returns the DerivedData root for assertions.
Directory buildSimFixtures(Directory tmp) {
  final dd = Directory(
    '${tmp.path}/home/Library/Developer/Xcode/DerivedData',
  );
  dd.createSync(recursive: true);
  final ownedWs =
      '${tmp.path}/ws/flutter_app/ios/Runner.xcworkspace'; // cwd workspace
  Directory(ownedWs).createSync(recursive: true);
  final siblingWs =
      '${tmp.path}/sibling-leg/flutter_app/ios/Runner.xcworkspace';
  Directory(siblingWs).createSync(recursive: true);
  final goneWs = '${tmp.path}/gone/flutter_app/ios/Runner.xcworkspace';
  fixtureCandidate(dd, 'Runner-owned', ownedWs);
  fixtureCandidate(dd, 'Runner-live-sibling', siblingWs);
  fixtureCandidate(dd, 'Runner-orphan', goneWs);
  fixtureCandidate(dd, 'Runner-plistless', null);
  return dd;
}

void main() {
  group('gh-2134 — build-ios DerivedData wipe is checkout-scoped', () {
    test('AC1: no HOME-global destructive wipe over DerivedData/Runner-*', () {
      // Comment lines cannot execute — the destructive shape only matters
      // in live shell lines (the gh-2134 comment documents the old shape).
      final liveLines = buildStepRun()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .toList();
      final liveRun = liveLines.join('\n');
      // The exact shape that killed run 43203130726.
      expect(
        liveRun.contains(
          'rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*',
        ),
        isFalse,
        reason:
            'the HOME-global glob wipe reaches every concurrent build-ios '
            'leg on the shared fa-m5 box and deletes its LIVE DerivedData '
            'mid-build (build.db disk I/O error + vanished '
            'Runner-OutputFileMap.json). Scope it via info.plist '
            'WorkspacePath instead.',
      );
      // The general shape, in any spelling: an rm -rf whose target is a
      // glob (or the bare root) of the shared DerivedData tree.
      final globShape = RegExp(r'rm -rf\s+\S*DerivedData\S*\*');
      for (final line in liveLines.where((l) => l.contains('rm -rf'))) {
        expect(
          globShape.hasMatch(line),
          isFalse,
          reason: 'destructive DerivedData glob survived in: $line',
        );
      }
    });

    test('AC2: wipe matches candidates by info.plist WorkspacePath and '
        'removes only the matched dir', () {
      final run = buildStepRun();
      // Per-dir metadata read — the WorkspacePath entry records the
      // absolute workspace path that created the DerivedData dir.
      expect(
        run,
        contains('/usr/libexec/PlistBuddy'),
        reason: 'resolve the candidate dir owner via PlistBuddy',
      );
      expect(
        run,
        contains('Print :WorkspacePath'),
        reason: 'read the WorkspacePath entry',
      );
      expect(
        run,
        contains('Runner.xcworkspace'),
        reason:
            'compare against THIS checkout workspace '
            '(flutter_app/ios/Runner.xcworkspace)',
      );
      // The removal must target the per-dir matched variable — never a
      // glob, never the DerivedData root.
      final removals = rmLines()
          .where((l) => !l.trimLeft().startsWith('#'))
          .toList();
      expect(removals, isNotEmpty, reason: 'the wipe must still exist');
      for (final line in removals) {
        expect(
          line,
          contains(r'"$dd"'),
          reason:
              'every removal must target the matched per-dir variable '
              '"\$dd", got: $line',
        );
      }
      // The comparison must be an equality test against the resolved
      // workspace path (not a prefix/regex that could over-match).
      expect(
        RegExp(r'\[ "\$ws" = "\$ws_path" \]').hasMatch(run),
        isTrue,
        reason:
            'the wipe decision must be an exact WorkspacePath equality '
            'check so a concurrent leg (different _work path) can never '
            'match',
      );
    });

    test('AC3: the scoped wipe still runs before flutter build ios', () {
      final run = buildStepRun();
      final wipeIdx = run.indexOf('WorkspacePath');
      final buildIdx = run.indexOf('flutter build ios');
      expect(wipeIdx, greaterThan(-1), reason: 'wipe present');
      expect(buildIdx, greaterThan(-1), reason: 'build command present');
      expect(
        buildIdx,
        greaterThan(wipeIdx),
        reason:
            'the stale-pcm protection (gh-1296-era "FlutterPlugin.h has '
            'been modified since the module file was built") must run on '
            'every build BEFORE the xcodebuild invocation',
      );
    });

    test('AC4: build-ios stays on the shared macos-m5 pool', () {
      expect(
        buildIosJob()['runs-on'].toString(),
        contains('macos-m5'),
        reason:
            'the checkout-scoped wipe is the fix; rerouting off the one '
            'genuinely macOS-only gate box must be a separate decision',
      );
    });
  });
}
