// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-2030 — the daily-publish cli leg (build-macos run 41276487426)
// failed its `Build Chrome extension` job at the size budget:
// `sw/agent.js` +7.9% (1,890,859 → 2,040,013) against the +5% budget —
// the accumulated dart2js growth of ~12 days of main-Dart feature work
// (scoped DAP channels + review hardening #1888/#1895, display-only
// redaction #1960, cross-module dedup #2023, media capabilities v2
// #2007, control-flow quality #2021) since the 2026-10-19 floor seed
// (326eadd7). Intentional growth: the stale floor needed the gate's own
// documented remediation — a reseed from the failing run's artifact
// manifest (the gh-1820 arm64 / gh-1954 fa-ios precedent).
//
// The extension zip was NOT uploaded (the run failed at the gate, so the
// release job skipped), so the authoritative artifact evidence is the
// manifest table the gate itself printed into that run log — 41 rows
// ≥ 64 KiB + TOTAL, the exact `--reseed` output shape. This test pins
// that shape as the committed floor, two ways (the gh-1820 test's
// structure, `check_lockfiles_gate_test.dart` pattern of running the
// enforcing script from a test — the gate cannot rot between static-gate
// runs):
//   1. the REAL gate (`scripts/size_manifest.py check`) run against the
//      REAL committed baseline and a fixture of the run's artifact shape
//      must go GREEN — before the reseed it exits 1 with the very
//      `GREW +7.9% sw/agent.js  1890859 -> 2040013` regression that
//      blocked the leg;
//   2. a `--reseed` round-trip from the same fixture rewrites the
//      baseline BYTE-IDENTICAL to the committed file — the committed
//      floor stays the exact `--reseed` output shape for the shipped
//      artifact (no hand-massaged rows, no sort/format drift).
//
// gh-2215 follow-up — the intentional jsr 0.4.204 / THREE and FA typography
// payloads required the next reseed. The independent fixture below now pins
// validation run 43986372662's Linux artifact (78 tracked rows + TOTAL), not
// the historical gh-2030 shape. The green, +10% rejection, and byte-exact
// round-trip checks above are deliberately unchanged in strength.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The fa-extension baseline the build-macos.yml extension gate reads.
const baseline = 'scripts/size_budget/fa-extension.tsv';

/// Run 43986372662 fa-extension.zip TOTAL (gate output, uncompressed
/// bytes — includes the sub-64 KiB payload below the manifest floor).
const artifactTotalBytes = 164042708;

/// The gate-printed manifest of validation run 43986372662's Linux artifact
/// (job "Extension size gate (fa-extension.zip)"): every row ≥ 64 KiB,
/// `<bytes>\t<path>`, path-sorted — the exact `size_manifest.py --reseed`
/// output shape. This is an independent literal, not loaded from the baseline.
const artifactManifest = [
  [1641820, 'panel/app/assets/NOTICES'],
  [90384, 'panel/app/assets/assets/fonts/Geist-Bold.ttf'],
  [90360, 'panel/app/assets/assets/fonts/Geist-ExtraBold.ttf'],
  [90388, 'panel/app/assets/assets/fonts/Geist-Medium.ttf'],
  [90344, 'panel/app/assets/assets/fonts/Geist-Regular.ttf'],
  [90460, 'panel/app/assets/assets/fonts/Geist-SemiBold.ttf'],
  [101980, 'panel/app/assets/assets/fonts/GeistMono-Medium.ttf'],
  [101868, 'panel/app/assets/assets/fonts/GeistMono-Regular.ttf'],
  [101888, 'panel/app/assets/assets/fonts/GeistMono-SemiBold.ttf'],
  [137784, 'panel/app/assets/assets/fonts/IBMPlexMono-Bold.ttf'],
  [136704, 'panel/app/assets/assets/fonts/IBMPlexMono-Medium.ttf'],
  [135580, 'panel/app/assets/assets/fonts/IBMPlexMono-Regular.ttf'],
  [140216, 'panel/app/assets/assets/fonts/IBMPlexMono-SemiBold.ttf'],
  [218136, 'panel/app/assets/assets/fonts/IBMPlexSans-Bold.ttf'],
  [218256, 'panel/app/assets/assets/fonts/IBMPlexSans-Medium.ttf'],
  [218076, 'panel/app/assets/assets/fonts/IBMPlexSans-Regular.ttf'],
  [218240, 'panel/app/assets/assets/fonts/IBMPlexSans-SemiBold.ttf'],
  [420428, 'panel/app/assets/assets/fonts/Inter-Bold.ttf'],
  [344000, 'panel/app/assets/assets/fonts/Inter-ExtraBold.ttf'],
  [417300, 'panel/app/assets/assets/fonts/Inter-Medium.ttf'],
  [411640, 'panel/app/assets/assets/fonts/Inter-Regular.ttf'],
  [419744, 'panel/app/assets/assets/fonts/Inter-SemiBold.ttf'],
  [274096, 'panel/app/assets/assets/fonts/JetBrainsMono-Bold.ttf'],
  [115032, 'panel/app/assets/assets/fonts/JetBrainsMono-ExtraBold.ttf'],
  [115212, 'panel/app/assets/assets/fonts/JetBrainsMono-Medium.ttf'],
  [270224, 'panel/app/assets/assets/fonts/JetBrainsMono-Regular.ttf'],
  [115084, 'panel/app/assets/assets/fonts/JetBrainsMono-SemiBold.ttf'],
  [97424, 'panel/app/assets/assets/fonts/Manrope-Bold.ttf'],
  [98056, 'panel/app/assets/assets/fonts/Manrope-ExtraBold.ttf'],
  [97536, 'panel/app/assets/assets/fonts/Manrope-Medium.ttf'],
  [97436, 'panel/app/assets/assets/fonts/Manrope-Regular.ttf'],
  [97584, 'panel/app/assets/assets/fonts/Manrope-SemiBold.ttf'],
  [96468, 'panel/app/assets/assets/fonts/PlusJakartaSans-Bold.ttf'],
  [96480, 'panel/app/assets/assets/fonts/PlusJakartaSans-ExtraBold.ttf'],
  [96600, 'panel/app/assets/assets/fonts/PlusJakartaSans-Medium.ttf'],
  [96572, 'panel/app/assets/assets/fonts/PlusJakartaSans-Regular.ttf'],
  [96596, 'panel/app/assets/assets/fonts/PlusJakartaSans-SemiBold.ttf'],
  [88256, 'panel/app/assets/assets/fonts/SpaceGrotesk-Bold.ttf'],
  [88328, 'panel/app/assets/assets/fonts/SpaceGrotesk-Medium.ttf'],
  [88300, 'panel/app/assets/assets/fonts/SpaceGrotesk-Regular.ttf'],
  [88216, 'panel/app/assets/assets/fonts/SpaceGrotesk-SemiBold.ttf'],
  [
    82244,
    'panel/app/assets/packages/flutter_inappwebview/assets/t_rex_runner/t-rex.html',
  ],
  [
    89344,
    'panel/app/assets/packages/flutter_inappwebview_web/assets/web/web_support.js',
  ],
  [
    898445,
    'panel/app/assets/packages/js_widget_runtime/assets/three/jsr_three_native.js',
  ],
  [
    859738,
    'panel/app/assets/packages/js_widget_runtime/assets/three/jsr_three_web.js',
  ],
  [
    612752,
    'panel/app/assets/packages/js_widget_runtime/assets/three/three_r1.shaderbundle',
  ],
  [87031, 'panel/app/canvaskit/<rev>/canvaskit.js'],
  [1363368, 'panel/app/canvaskit/<rev>/canvaskit.js.symbols'],
  [7315452, 'panel/app/canvaskit/<rev>/canvaskit.wasm'],
  [86270, 'panel/app/canvaskit/<rev>/chromium/canvaskit.js'],
  [1242746, 'panel/app/canvaskit/<rev>/chromium/canvaskit.js.symbols'],
  [5463539, 'panel/app/canvaskit/<rev>/chromium/canvaskit.wasm'],
  [1550249, 'panel/app/canvaskit/<rev>/skwasm.js.symbols'],
  [3612036, 'panel/app/canvaskit/<rev>/skwasm.wasm'],
  [1682137, 'panel/app/canvaskit/<rev>/skwasm_heavy.js.symbols'],
  [5232173, 'panel/app/canvaskit/<rev>/skwasm_heavy.wasm'],
  [76114, 'panel/app/canvaskit/<rev>/webparagraph/canvaskit.js'],
  [967481, 'panel/app/canvaskit/<rev>/webparagraph/canvaskit.js.symbols'],
  [3753480, 'panel/app/canvaskit/<rev>/webparagraph/canvaskit.wasm'],
  [1810576, 'panel/app/canvaskit/<rev>/wimp.js.symbols'],
  [3604253, 'panel/app/canvaskit/<rev>/wimp.wasm'],
  [12965432, 'panel/app/main.dart.js'],
  [2090896, 'sw/agent.js'],
  [1070863, 'vendor/interpreters/asyncify/emscripten-module.wasm'],
  [2224743, 'vendor/interpreters/index.global.js'],
  [106335, 'vendor/interpreters/pyodide-lock.json'],
  [1229099, 'vendor/interpreters/pyodide.asm.js'],
  [10088051, 'vendor/interpreters/pyodide.asm.wasm'],
  [2341872, 'vendor/interpreters/python_stdlib.zip'],
  [659730, 'vendor/interpreters/sql-wasm.wasm'],
  [291430, 'vendor/litert/0.12.1/litertlm_wasm_compat_internal.js'],
  [18823258, 'vendor/litert/0.12.1/litertlm_wasm_compat_internal.wasm'],
  [291190, 'vendor/litert/0.12.1/litertlm_wasm_internal.js'],
  [18859259, 'vendor/litert/0.12.1/litertlm_wasm_internal.wasm'],
  [23567050, 'vendor/transformers/4.2.0/ort-wasm-simd-threaded.asyncify.wasm'],
  [12942611, 'vendor/transformers/4.2.0/ort-wasm-simd-threaded.wasm'],
  [558336, 'vendor/transformers/4.2.0/transformers.min.js'],
  [6065529, 'vendor/webllm/0.2.84/webllm.mjs'],
];

/// Builds a directory artifact with the run's exact shape: one sparse file
/// (st_size is all `size_manifest.py` reads) per manifest row + filler
/// files (< the 64 KiB tracking floor, so they only move the TOTAL)
/// carrying the sub-floor payload the real zip had. [swAgentExtraBytes]
/// inflates `sw/agent.js` past the +5% budget for the negative case (the
/// TOTAL grows by the same delta, as a real artifact would).
Directory buildArtifactFixture({int swAgentExtraBytes = 0}) {
  final dir = Directory.systemTemp.createTempSync('gh2030_ext_artifact');
  addTearDown(() => dir.deleteSync(recursive: true));
  for (final row in artifactManifest) {
    final isAgentSw = (row[1] as String) == 'sw/agent.js';
    writeSparseFile(
      File('${dir.path}/${row[1] as String}'),
      (row[0] as int) + (isAgentSw ? swAgentExtraBytes : 0),
    );
  }
  // Sub-floor payload: TOTAL − Σ(tracked rows), spread over files each
  // below the 64 KiB manifest floor (62,183 < 65,536 bytes).
  final trackedSum = artifactManifest.fold<int>(0, (s, r) => s + (r[0] as int));
  final fillerBytes = artifactTotalBytes + swAgentExtraBytes - trackedSum;
  expect(fillerBytes, greaterThanOrEqualTo(0));
  const fillerChunk = 62183;
  final fillerCount = (fillerBytes / fillerChunk).ceil();
  for (var i = 0; i < fillerCount; i++) {
    final last = i == fillerCount - 1;
    writeSparseFile(
      File('${dir.path}/_sub_floor_payload/filler_$i.bin'),
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
  test('extension size floor gates the run-43986372662 artifact shape green '
      '(gh-2030 / gh-2215)', () {
    final artifact = buildArtifactFixture();
    final result = runGate(artifact: artifact, baselinePath: baseline);
    expect(
      result.exitCode,
      0,
      reason:
          'the committed extension floor must accept the pinned Linux '
          'artifact shape after the intentional THREE/jsr reseed. '
          'Gate output:\n${result.stdout}\n${result.stderr}',
    );
    expect(result.stdout, contains('size budget OK'));
  });
  test('a +10% inflated artifact is still rejected — the ratchet stays '
      'armed (gh-2030)', () {
    // sw/agent.js grown ×1.1 (2,090,896 → 2,299,986 = +10.0%): double the
    // +5% budget, shaped like a next real regression. The committed floor
    // must refuse it — a floor that accepts anything would not have caught
    // the original gh-2030 regression or the post-reseed platform skew.
    final artifact = buildArtifactFixture(swAgentExtraBytes: 209090);
    final result = runGate(artifact: artifact, baselinePath: baseline);
    expect(
      result.exitCode,
      1,
      reason:
          'an artifact past the +5% budget must still be rejected by the '
          'committed floor — the ratchet stays armed. Gate output:\n'
          '${result.stdout}\n${result.stderr}',
    );
    expect(
      result.stdout,
      matches(RegExp(r'GREW\s+\+\s*10\.0%\s+sw/agent\.js')),
      reason:
          'the rejection must name the regressing line and its measured '
          'growth (+10.0% on sw/agent.js), not fail for some unrelated '
          'reason',
    );
  });

  test('committed floor is the byte-exact --reseed output for that shape '
      '(gh-2030)', () {
    final artifact = buildArtifactFixture();
    final reseedDir = Directory.systemTemp.createTempSync('gh2030_reseed');
    addTearDown(() => reseedDir.deleteSync(recursive: true));
    // --reseed requires an EXISTING baseline file to overwrite; the old
    // content is irrelevant (it rewrites from the artifact manifest).
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
      File(baseline).readAsBytesSync(),
      reason:
          'the committed $baseline must be the byte-exact `--reseed` '
          'output for the shipped run-43986372662 shape (78 rows '
          '≥ 64 KiB + TOTAL, path-sorted) — any hand-edit drift desyncs '
          'the floor from what the gate would have seeded',
    );
  });
}
