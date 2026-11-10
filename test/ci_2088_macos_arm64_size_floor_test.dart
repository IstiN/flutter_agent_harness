// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-2088 — the daily-publish cli leg (build-macos run 42761496337,
// v1.0.702) passed the full macOS arm64 build, then failed the size
// budget: `Fa.app/Contents/Resources/Assets.car` +101.6% (93,640 →
// 188,792) — the #2063 Fa 2 / Porcelain app-marketing redesign replaced
// every macOS AppIcon.appiconset PNG with the Squircle-V2 brand mark
// (7/7 icons ~2.2–2.4× heavier), and actool compiles the icon set into
// Assets.car. Intentional growth: the stale floor (seeded from the
// v1.0.634 shape, gh-1820) needed the gate's own documented remediation
// — a reseed from the failing run's artifact manifest (the gh-1820
// arm64 / gh-1954 fa-ios / gh-2030 extension precedent). The same run's
// shape shift is mostly CONTRACTION: GemmaModelConstraintProvider,
// LiteRtLm and LiteRtMetalAccelerator frameworks left the bundle, so
// TOTAL fell 116.4 MB → 74.7 MB while the #2063 Fa2 typography presets
// added the Geist/IBM Plex/Manrope/PlusJakartaSans/SpaceGrotesk font
// families to flutter_assets.
//
// The arm64 zip was NOT uploaded (the leg failed at the gate), so the
// authoritative artifact evidence is the manifest table the gate itself
// printed into that run log — 56 rows ≥ 64 KiB + TOTAL, the exact
// `--reseed` output shape. This test pins that shape as the committed
// floor, two ways (the gh-1820 test's structure, `check_lockfiles_gate_
// test.dart` pattern of running the enforcing script from a test — the
// gate cannot rot between static-gate runs):
//   1. the REAL gate (`scripts/size_manifest.py check`) run against the
//      REAL committed baseline and a fixture of the run's artifact shape
//      must go GREEN — before the reseed it exits 1 with the very
//      `GREW +101.6% Assets.car  93640 -> 188792` regression that
//      blocked the leg;
//   2. a `--reseed` round-trip from the same fixture rewrites the
//      baseline BYTE-IDENTICAL to the committed file — the committed
//      floor stays the exact `--reseed` output shape for the shipped
//      artifact (no hand-massaged rows, no sort/format drift).
//
// Supersedes test/ci_1820_macos_arm64_size_floor_test.dart: that test
// pinned the v1.0.634 shape byte-exactly and reds once the floor moves
// to this shape (the pin travels with the floor, per-ticket named).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The arm64 baseline the build-macos.yml mac-zip gate reads.
const baseline = 'scripts/size_budget/fa-macos-arm64.tsv';

/// v1.0.702 arm64 zip TOTAL (run 42761496337 gate output, uncompressed
/// bytes — includes the sub-64 KiB payload below the manifest floor).
const artifactTotalBytes = 74701116;

/// The gate-printed manifest of the failing run's artifact
/// (run 42761496337, job "Build macOS arm64"): every row ≥ 64 KiB,
/// `<bytes>\t<path>`, path-sorted — the exact `size_manifest.py --reseed`
/// output shape.
const artifactManifest = [
  [26546800, 'Fa.app/Contents/Frameworks/App.framework/Versions/A/App'],
  [
    119017,
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
    719720,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/liquid_glass_widgets/shaders/liquid_glass_geometry_blended.frag',
  ],
  [
    14634976,
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
    844112,
    'Fa.app/Contents/Frameworks/quickjs_bridge.framework/Versions/A/quickjs_bridge',
  ],
  [1671040, 'Fa.app/Contents/Frameworks/sqlite3.framework/Versions/A/sqlite3'],
  [18514032, 'Fa.app/Contents/MacOS/Fa'],
  [188792, 'Fa.app/Contents/Resources/Assets.car'],
];

/// Builds a directory artifact with the run's exact shape: one sparse file
/// (st_size is all `size_manifest.py` reads) per manifest row + filler
/// files (< the 64 KiB tracking floor, so they only move the TOTAL)
/// carrying the sub-floor payload the real zip had.
Directory buildArtifactFixture() {
  final dir = Directory.systemTemp.createTempSync('gh2088_arm64_artifact');
  addTearDown(() => dir.deleteSync(recursive: true));
  for (final row in artifactManifest) {
    writeSparseFile(File('${dir.path}/${row[1] as String}'), row[0] as int);
  }
  // Sub-floor payload: TOTAL − Σ(tracked rows), spread over files each
  // below the 64 KiB manifest floor (62,183 < 65,536 bytes).
  final trackedSum = artifactManifest.fold<int>(0, (s, r) => s + (r[0] as int));
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
  test(
    'arm64 size floor gates the v1.0.702 artifact shape green (gh-2088)',
    () {
      final artifact = buildArtifactFixture();
      final result = runGate(artifact: artifact, baselinePath: baseline);
      expect(
        result.exitCode,
        0,
        reason:
            'the committed arm64 floor must accept the shipped v1.0.702 '
            'shape — run 42761496337 red the leg with `GREW +101.6% '
            'Assets.car  93640 -> 188792` (intentional icon growth, the '
            'gate\'s own reseed case). Gate output:\n'
            '${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('size budget OK'));
    },
  );

  test('committed floor is the byte-exact --reseed output for that shape '
      '(gh-2088)', () {
    final artifact = buildArtifactFixture();
    final reseeded =
        '${Directory.systemTemp.createTempSync('gh2088_reseed').path}/'
        'reseed.tsv';
    addTearDown(() => File(reseeded).parent.deleteSync(recursive: true));
    // --reseed requires an EXISTING baseline file to overwrite; the old
    // content is irrelevant (it rewrites from the artifact manifest).
    File(reseeded).parent.createSync(recursive: true);
    File(reseeded).writeAsStringSync('0\tseed\n0\tTOTAL\n');
    final result = runGate(
      artifact: artifact,
      baselinePath: reseeded,
      reseed: true,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}');
    expect(
      File(reseeded).readAsBytesSync(),
      File(baseline).readAsBytesSync(),
      reason:
          'the committed $baseline must be the byte-exact `--reseed` '
          'output for the shipped v1.0.702 shape (56 rows ≥ 64 KiB + '
          'TOTAL, path-sorted) — any hand-edit drift desyncs the floor '
          'from what the gate would have seeded',
    );
  });
}
