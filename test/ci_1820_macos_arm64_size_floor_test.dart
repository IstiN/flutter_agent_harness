// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1820 — the arm64 DMG leg (build-macos run 4004758753, v1.0.634,
// post-#1815 SPM-lane adoption) passed the min-platform gate and the full
// build, then failed the size budget: `App.framework/App` +5.1%
// (25,020,112 → 26,284,144) — the accumulated Dart AOT of the night's
// feature merges (#1793, #1794, #1796, #1805, #1806). Intentional growth:
// the stale floor (`scripts/size_budget/fa-macos-arm64.tsv` was seeded
// from the pre-#1096-diet shape — its TOTAL row claims 210.5 MB while the
// shipped artifact weighs 116.4 MB) needed the gate's own documented
// remediation: a reseed from the failing run's artifact manifest.
//
// The arm64 zip was NOT uploaded (the leg failed at the gate), so the
// authoritative artifact evidence is the manifest table the gate itself
// printed into that run log — 26 rows ≥ 64 KiB + TOTAL, the exact
// `--reseed` output shape. This test pins that shape as the committed
// floor, two ways (the `check_lockfiles_gate_test.dart` pattern of
// running the enforcing script from a test, #1100 — the gate cannot rot
// between static-gate runs):
//   1. the REAL gate (`scripts/size_manifest.py check`) run against the
//      REAL committed baseline and a fixture of the run's artifact shape
//      must go GREEN — before the reseed it exits 1 with the very
//      `GREW +5.1% App.framework/App` regression that blocked the leg;
//   2. a `--reseed` round-trip from the same fixture rewrites the
//      baseline BYTE-IDENTICAL to the committed file — the committed
//      floor stays the exact `--reseed` output shape for the shipped
//      artifact (no hand-massaged rows, no sort/format drift).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The arm64 baseline the build-macos.yml mac-zip gate reads.
const baseline = 'scripts/size_budget/fa-macos-arm64.tsv';

/// v1.0.634 arm64 zip TOTAL (run 4004758753 gate output, uncompressed
/// bytes — includes the sub-64 KiB payload below the manifest floor).
const artifactTotalBytes = 116386369;

/// The gate-printed manifest of the failing run's artifact
/// (run 4004758753, job "Build macOS arm64"): every row ≥ 64 KiB,
/// `<bytes>\t<path>`, path-sorted — the exact `size_manifest.py --reseed`
/// output shape.
const artifactManifest = [
  [26284144, 'Fa.app/Contents/Frameworks/App.framework/Versions/A/App'],
  [
    126278,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/NOTICES.Z',
  ],
  [
    420428,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/Inter-Bold.ttf',
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
    270224,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/fonts/JetBrainsMono-Regular.ttf',
  ],
  [
    257628,
    'Fa.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
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
    14634976,
    'Fa.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS',
  ],
  [
    864880,
    'Fa.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/Resources/icudtl.dat',
  ],
  [
    9386688,
    'Fa.app/Contents/Frameworks/GemmaModelConstraintProvider.framework/Versions/A/GemmaModelConstraintProvider',
  ],
  [
    26206960,
    'Fa.app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm',
  ],
  [
    11486384,
    'Fa.app/Contents/Frameworks/LiteRtMetalAccelerator.framework/Versions/A/LiteRtMetalAccelerator',
  ],
  [
    127344,
    'Fa.app/Contents/Frameworks/OrderedSet.framework/Versions/A/OrderedSet',
  ],
  [
    85072,
    'Fa.app/Contents/Frameworks/StreamProxy.framework/Versions/A/StreamProxy',
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
  [
    1671040,
    'Fa.app/Contents/Frameworks/sqlite3.framework/Versions/A/sqlite3',
  ],
  [18611696, 'Fa.app/Contents/MacOS/Fa'],
  [93640, 'Fa.app/Contents/Resources/Assets.car'],
];

/// Builds a directory artifact with the run's exact shape: one sparse file
/// (st_size is all `size_manifest.py` reads) per manifest row + filler
/// files (< the 64 KiB tracking floor, so they only move the TOTAL)
/// carrying the sub-floor payload the real zip had.
Directory buildArtifactFixture() {
  final dir = Directory.systemTemp.createTempSync('gh1820_arm64_artifact');
  addTearDown(() => dir.deleteSync(recursive: true));
  for (final row in artifactManifest) {
    writeSparseFile(
      File('${dir.path}/${row[1] as String}'),
      row[0] as int,
    );
  }
  // Sub-floor payload: TOTAL − Σ(tracked rows), spread over files each
  // below the 64 KiB manifest floor (62,183 < 65,536 bytes).
  final trackedSum = artifactManifest
      .fold<int>(0, (s, r) => s + (r[0] as int));
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
}) =>
    Process.runSync(
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
    'arm64 size floor gates the v1.0.634 artifact shape green (gh-1820)',
    () {
      final artifact = buildArtifactFixture();
      final result = runGate(artifact: artifact, baselinePath: baseline);
      expect(
        result.exitCode,
        0,
        reason:
            'the committed arm64 floor must accept the shipped v1.0.634 '
            'shape — run 4004758753 red the leg with `GREW +5.1% '
            'App.framework/App` (intentional AOT growth, the gate\'s own '
            'reseed case). Gate output:\n'
            '${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('size budget OK'));
    },
  );

  test(
    'committed floor is the byte-exact --reseed output for that shape '
    '(gh-1820)',
    () {
      final artifact = buildArtifactFixture();
      final reseeded =
          '${Directory.systemTemp.createTempSync('gh1820_reseed').path}/'
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
            'output for the shipped v1.0.634 shape (26 rows ≥ 64 KiB + '
            'TOTAL, path-sorted) — any hand-edit drift desyncs the floor '
            'from what the gate would have seeded',
      );
    },
  );
}
