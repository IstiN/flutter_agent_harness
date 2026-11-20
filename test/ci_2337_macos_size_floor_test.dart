// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-237 — the daily-publish cli leg (build-macos run 44680647719,
// v1.0.756) failed the macOS arm64 size budget: first-party TOTAL
// 74,701,116 → 78,493,725 (+5.08%, past the +5.0% budget) with no single
// line breaching — the js_widget_runtime 0.4.208 bump (PR #2333) ships
// the three.js renderer bundles (`packages/js_widget_runtime/assets/
// three/`, +2,371,493 B of NEW rows), the Fa 2.0 typography added the
// Outfit/DM Mono families (each file below the 64 KiB manifest floor),
// and the Dart AOT / Flutter 3.50.0 engine grew a few percent in place.
// Intentional growth → the gate's own documented remediation (the
// gh-2088 / gh-1820 / gh-1954 / gh-2030 reseed precedent): commit the
// reseeded floor from the failing run's artifact manifest.
//
// The arm64 zip was NOT uploaded (the artifact steps run after the
// gate), so the authoritative evidence is again the manifest table the
// gate itself printed into that run log — 59 rows ≥ 64 KiB + TOTAL, the
// exact `--reseed` output shape, byte-verified against the gate's own
// error line (`TOTAL-1P + 5.1% 7470116 -> 78493725`).
//
// The same run ALSO exposed the x64 gate as never-armed: `scripts/
// size_budget/fa-macos-x64.tsv` did not exist in-repo, so every x86_64
// leg ran `--init-if-missing`, transiently self-seeded a baseline, and
// uploaded it as an artifact nobody committed (the run log's notice:
// "COMMIT scripts/size_budget/fa-macos-x64.tsv to arm the gate"). The
// seeded x64 baseline from that run's `size-baselines-macos` artifact
// (written by size_manifest.py itself, TOTAL 81,153,036) is now the
// committed x64 floor.
//
// This test pins both floors, two ways each (the gh-2088 structure):
//   1. the REAL gate (`scripts/size_manifest.py check`) run against the
//      REAL committed baseline and a fixture of the run's artifact shape
//      must go GREEN — before the reseed it exits 1 with the very
//      `TOTAL-1P +5.1% 74701116 -> 78493725` regression that blocked the
//      leg;
//   2. a `--reseed` round-trip from the same fixture rewrites the
//      baseline BYTE-IDENTICAL to the committed file — the committed
//      floor stays the exact `--reseed` output shape for the shipped
//      artifact (no hand-massaged rows, no sort/format drift).
//
// Supersedes test/ci_2088_macos_arm64_size_floor_test.dart: that test
// pinned the v1.0.702 shape byte-exactly and reds once the floor moves
// to this shape (the pin travels with the floor, per-ticket named).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The arm64 baseline the build-macos.yml mac-zip gate reads.
const arm64Baseline = 'scripts/size_budget/fa-macos-arm64.tsv';

/// The x64 baseline the same gate reads (`baseline_arch=x64` for the
/// x86_64 matrix leg) — committed by gh-237, arming the gate.
const x64Baseline = 'scripts/size_budget/fa-macos-x64.tsv';

/// v1.0.756 arm64 zip TOTAL (run 44680647719 gate output, uncompressed
/// bytes — includes the sub-64 KiB payload below the manifest floor).
const arm64ArtifactTotalBytes = 78493725;

/// v1.0.756 x86_64 zip TOTAL (same run, "Build macOS x86_64" gate —
/// the seeded x64 artifact).
const x64ArtifactTotalBytes = 81153036;

/// The gate-printed manifest of the failing run's arm64 artifact
/// (run 44680647719, job "Build macOS arm64"): every row ≥ 64 KiB,
/// `<bytes>\t<path>`, path-sorted — the exact `size_manifest.py
/// --reseed` output shape.
const arm64ArtifactManifest = [
  [27778080, 'Fa.app/Contents/Frameworks/App.framework/Versions/A/App'],
  [
    119800,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/NOTICES.Z',
  ],
  [
    90384,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Geist-Bold.ttf',
  ],
  [
    90360,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Geist-ExtraBold.ttf',
  ],
  [
    90388,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Geist-Medium.ttf',
  ],
  [
    90344,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Geist-Regular.ttf',
  ],
  [
    90460,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Geist-SemiBold.ttf',
  ],
  [
    101980,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/GeistMono-Medium.ttf',
  ],
  [
    101868,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/GeistMono-Regular.ttf',
  ],
  [
    101888,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/GeistMono-SemiBold.ttf',
  ],
  [
    137784,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexMono-Bold.ttf',
  ],
  [
    136704,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexMono-Medium.ttf',
  ],
  [
    135580,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexMono-Regular.ttf',
  ],
  [
    140216,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexMono-SemiBold.ttf',
  ],
  [
    218136,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexSans-Bold.ttf',
  ],
  [
    218256,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexSans-Medium.ttf',
  ],
  [
    218076,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexSans-Regular.ttf',
  ],
  [
    218240,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/IBMPlexSans-SemiBold.ttf',
  ],
  [
    420428,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Inter-Bold.ttf',
  ],
  [
    344000,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Inter-ExtraBold.ttf',
  ],
  [
    417300,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Inter-Medium.ttf',
  ],
  [
    411640,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Inter-Regular.ttf',
  ],
  [
    419744,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Inter-SemiBold.ttf',
  ],
  [
    274096,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/JetBrainsMono-Bold.ttf',
  ],
  [
    115032,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/JetBrainsMono-ExtraBold.ttf',
  ],
  [
    115212,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/JetBrainsMono-Medium.ttf',
  ],
  [
    270224,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/JetBrainsMono-Regular.ttf',
  ],
  [
    115084,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/JetBrainsMono-SemiBold.ttf',
  ],
  [
    97424,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Manrope-Bold.ttf',
  ],
  [
    98056,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Manrope-ExtraBold.ttf',
  ],
  [
    97536,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Manrope-Medium.ttf',
  ],
  [
    97436,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Manrope-Regular.ttf',
  ],
  [
    97584,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Manrope-SemiBold.ttf',
  ],
  [
    96468,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/PlusJakartaSans-Bold.ttf',
  ],
  [
    96480,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/PlusJakartaSans-ExtraBold.ttf',
  ],
  [
    96600,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/PlusJakartaSans-Medium.ttf',
  ],
  [
    96572,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/PlusJakartaSans-Regular.ttf',
  ],
  [
    96596,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/PlusJakartaSans-SemiBold.ttf',
  ],
  [
    88256,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/SpaceGrotesk-Bold.ttf',
  ],
  [
    88328,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/SpaceGrotesk-Medium.ttf',
  ],
  [
    88300,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/SpaceGrotesk-Regular.ttf',
  ],
  [
    88216,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/SpaceGrotesk-SemiBold.ttf',
  ],
  [
    82244,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/flutter_inappwebview/assets/t_rex_runner/t-rex.html',
  ],
  [
    89344,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/flutter_inappwebview_web/assets/web/web_support.js',
  ],
  [
    898758,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/js_widget_runtime/assets/three/jsr_three_native.js',
  ],
  [
    859983,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/js_widget_runtime/assets/three/jsr_three_web.js',
  ],
  [
    612752,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/js_widget_runtime/assets/three/three_r1.shaderbundle',
  ],
  [
    721160,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/liquid_glass_widgets/shaders/liquid_glass_geometry_blended.frag',
  ],
  [
    14768784,
    'Fa.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS',
  ],
  [
    864880,
    'Fa.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/Resources/icudtl.dat',
  ],
  [
    127344,
    'Fa.app/Contents/Frameworks/OrderedSet.framework/Versions/A/OrderedSet',
  ],
  [
    136672,
    'Fa.app/Contents/Frameworks/cupertino_http.framework/Versions/A/cupertino_http',
  ],
  [
    2280288,
    'Fa.app/Contents/Frameworks/flutter_inappwebview_macos.framework/Versions/A/flutter_inappwebview_macos',
  ],
  [
    79552,
    'Fa.app/Contents/Frameworks/flutter_js.framework/Versions/A/flutter_js',
  ],
  [
    202160,
    'Fa.app/Contents/Frameworks/objective_c.framework/Versions/A/objective_c',
  ],
  [
    844320,
    'Fa.app/Contents/Frameworks/quickjs_bridge.framework/Versions/A/quickjs_bridge',
  ],
  [1671040, 'Fa.app/Contents/Frameworks/sqlite3.framework/Versions/A/sqlite3'],
  [18555920, 'Fa.app/Contents/MacOS/Fa'],
  [188792, 'Fa.app/Contents/Resources/Assets.car'],
];

/// Builds a directory artifact with the run's exact shape: one sparse
/// file (st_size is all `size_manifest.py` reads) per manifest row +
/// filler files (< the 64 KiB tracking floor, so they only move the
/// TOTAL) carrying the sub-floor payload the real zip had. With
/// [rows] null the rows are read from the committed baseline file —
/// that fixture pins the x64 floor, whose authoritative evidence IS the
/// committed file (the gate's own `write_baseline` output, downloaded
/// from the run's `size-baselines-macos` artifact).
Directory buildArtifactFixture(
  int artifactTotalBytes,
  String baselinePath, {
  List<List<Object>>? rows,
}) {
  final resolvedRows =
      rows ??
      File(baselinePath).readAsLinesSync().where((l) => l.isNotEmpty).map((l) {
        final split = l.split('\t');
        return [int.parse(split[0]), split[1]];
      }).toList();
  final dir = Directory.systemTemp.createTempSync('gh2337_artifact');
  addTearDown(() => dir.deleteSync(recursive: true));
  var trackedSum = 0;
  for (final row in resolvedRows) {
    if (row[1] == 'TOTAL') continue;
    writeSparseFile(File('${dir.path}/${row[1] as String}'), row[0] as int);
    trackedSum += row[0] as int;
  }
  // Sub-floor payload: TOTAL − Σ(tracked rows), spread over files each
  // below the 64 KiB manifest floor.
  final fillerBytes = artifactTotalBytes - trackedSum;
  expect(fillerBytes, greaterThanOrEqualTo(0));
  const fillerChunk = 62183;
  final fillerCount = (fillerBytes / fillerChunk).ceil();
  for (var i = 0; i < fillerCount; i++) {
    final last = i == fillerCount - 1;
    writeSparseFile(
      File(
        '${dir.path}/Fa.app/Contents/Resources/_sub_floor_payload/'
        'filler_$i.bin',
      ),
      last ? fillerBytes - fillerChunk * (fillerCount - 1) : fillerChunk,
    );
  }
  return dir;
}

/// A file of exactly [size] bytes (sparse: truncate extends with zeros —
/// `stat().st_size` is the only thing the gate reads).
void writeSparseFile(File file, int size) {
  file.parent.createSync(recursive: true);
  final raf = file.openSync(mode: FileMode.write);
  try {
    raf.truncateSync(size);
  } finally {
    raf.closeSync();
  }
}

ProcessResult runGate({
  required Directory artifact,
  required String baselinePath,
  bool reseed = false,
}) => Process.runSync(
  'python3',
  [
    'scripts/size_manifest.py',
    'check',
    artifact.path,
    '--baseline',
    baselinePath,
    if (reseed) '--reseed',
  ],
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

void main() {
  test('both mac arch baselines exist and carry a TOTAL row (gh-2337)', () {
    for (final path in [arm64Baseline, x64Baseline]) {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            '$path must be committed — the build-macos.yml gate reads it '
            'with --init-if-missing, so a missing floor silently arms '
            'nothing and the gate self-seeds transiently every run',
      );
      final total = file
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .map((l) => l.split('\t')[1])
          .contains('TOTAL');
      expect(total, isTrue, reason: '$path must carry a TOTAL row');
    }
  });

  test('x64 floor is the seeded v1.0.756 shape (TOTAL 811153036, gh-2337)', () {
    final rows = <String, int>{};
    for (final line in File(x64Baseline).readAsLinesSync()) {
      if (line.isEmpty) continue;
      final split = line.split('\t');
      rows[split[1]] = int.parse(split[0]);
    }
    expect(
      rows['TOTAL'],
      x64ArtifactTotalBytes,
      reason:
          'the committed x64 floor must be the baseline the v1.0.756 '
          'x86_64 leg seeded (run 44680647719 "Build macOS x86_64", '
          '--init-if-missing notice: "COMMIT scripts/size_budget/'
          'fa-macos-x64.tsv to arm the gate")',
    );
    expect(rows.length, 59, reason: '58 tracked rows + TOTAL');
    expect(
      rows.keys.where((k) => k.contains('js_widget_runtime/assets/three')),
      hasLength(3),
      reason: 'the jsr 0.4.208 three.js rows are the headline growth',
    );
  });

  test(
    'arm64 size floor gates the v1.0.756 artifact shape green (gh-2337)',
    () {
      final artifact = buildArtifactFixture(
        arm64ArtifactTotalBytes,
        arm64Baseline,
        rows: arm64ArtifactManifest,
      );
      final result = runGate(artifact: artifact, baselinePath: arm64Baseline);
      expect(
        result.exitCode,
        0,
        reason:
            'the committed arm64 floor must accept the shipped v1.0.756 '
            'shape — run 44680647719 red the leg with `TOTAL-1P +5.1% '
            '7470116 -> 78493725` (intentional jsr 0.4.208 + Fa 2 fonts '
            '+ engine growth, the gate\'s own reseed case). Gate '
            'output:\n${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('size budget OK'));
    },
  );

  test('committed arm64 floor is the byte-exact --reseed output for that shape '
      '(gh-2337)', () {
    final artifact = buildArtifactFixture(
      arm64ArtifactTotalBytes,
      arm64Baseline,
      rows: arm64ArtifactManifest,
    );
    final reseedDir = Directory.systemTemp.createTempSync(
      'gh2337_reseed_arm64',
    );
    addTearDown(() => reseedDir.deleteSync(recursive: true));
    final reseeded = '${reseedDir.path}/reseed.tsv';
    // --reseed requires an EXISTING baseline file to overwrite; the old
    // content is irrelevant (it rewrites from the artifact manifest).
    File(reseeded).writeAsStringSync('0\tseed\n0\tTOTAL\n');
    final result = runGate(
      artifact: artifact,
      baselinePath: reseeded,
      reseed: true,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}');
    expect(
      File(reseeded).readAsBytesSync(),
      File(arm64Baseline).readAsBytesSync(),
      reason:
          'the committed $arm64Baseline must be the byte-exact '
          '`--reseed` output for the shipped v1.0.756 shape (59 rows '
          '≥ 64 KiB + TOTAL, path-sorted) — any hand-edit drift '
          'desyncs the floor from what the gate would have seeded',
    );
  });

  test('x64 floor gates the seeded v1.0.756 shape green (gh-2337)', () {
    final artifact = buildArtifactFixture(x64ArtifactTotalBytes, x64Baseline);
    final result = runGate(artifact: artifact, baselinePath: x64Baseline);
    expect(
      result.exitCode,
      0,
      reason:
          'the newly armed x64 floor must accept the shape it was seeded '
          'from — run 44680647719 x86_64. Gate output:\n'
          '${result.stdout}\n${result.stderr}',
    );
    expect(result.stdout, contains('size budget OK'));
  });

  test('committed x64 floor is the byte-exact --reseed output for that shape '
      '(gh-2337)', () {
    final artifact = buildArtifactFixture(x64ArtifactTotalBytes, x64Baseline);
    final reseedDir = Directory.systemTemp.createTempSync('gh2337_reseed_x64');
    addTearDown(() => reseedDir.deleteSync(recursive: true));
    final reseeded = '${reseedDir.path}/reseed.tsv';
    File(reseeded).writeAsStringSync('0\tseed\n0\tTOTAL\n');
    final result = runGate(
      artifact: artifact,
      baselinePath: reseeded,
      reseed: true,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}');
    expect(
      File(reseeded).readAsBytesSync(),
      File(x64Baseline).readAsBytesSync(),
      reason:
          'the committed $x64Baseline must be the byte-exact '
          '`--reseed` output shape (58 rows ≥ 64 KiB + TOTAL, '
          'path-sorted)',
    );
  });
}
