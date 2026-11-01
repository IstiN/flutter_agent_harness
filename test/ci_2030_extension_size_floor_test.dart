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
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The fa-extension baseline the build-macos.yml extension gate reads.
const baseline = 'scripts/size_budget/fa-extension.tsv';

/// Run 41276487426 fa-extension.zip TOTAL (gate output, uncompressed
/// bytes — includes the sub-64 KiB payload below the manifest floor).
const artifactTotalBytes = 155887040;

/// The gate-printed manifest of the failing run's artifact
/// (run 41276487426, job "Build Chrome extension"): every row ≥ 64 KiB,
/// `<bytes>\t<path>`, path-sorted — the exact `size_manifest.py --reseed`
/// output shape.
const artifactManifest = [
  [1574782, 'panel/app/assets/NOTICES'],
  [420428, 'panel/app/assets/assets/fonts/Inter-Bold.ttf'],
  [417300, 'panel/app/assets/assets/fonts/Inter-Medium.ttf'],
  [411640, 'panel/app/assets/assets/fonts/Inter-Regular.ttf'],
  [419744, 'panel/app/assets/assets/fonts/Inter-SemiBold.ttf'],
  [274096, 'panel/app/assets/assets/fonts/JetBrainsMono-Bold.ttf'],
  [270224, 'panel/app/assets/assets/fonts/JetBrainsMono-Regular.ttf'],
  [
    82244,
    'panel/app/assets/packages/flutter_inappwebview/assets/t_rex_runner/t-rex.html',
  ],
  [
    89344,
    'panel/app/assets/packages/flutter_inappwebview_web/assets/web/web_support.js',
  ],
  [86987, 'panel/app/canvaskit/<rev>/canvaskit.js'],
  [1356926, 'panel/app/canvaskit/<rev>/canvaskit.js.symbols'],
  [7284602, 'panel/app/canvaskit/<rev>/canvaskit.wasm'],
  [86226, 'panel/app/canvaskit/<rev>/chromium/canvaskit.js'],
  [1235870, 'panel/app/canvaskit/<rev>/chromium/canvaskit.js.symbols'],
  [5428806, 'panel/app/canvaskit/<rev>/chromium/canvaskit.wasm'],
  [1540006, 'panel/app/canvaskit/<rev>/skwasm.js.symbols'],
  [3593715, 'panel/app/canvaskit/<rev>/skwasm.wasm'],
  [1672152, 'panel/app/canvaskit/<rev>/skwasm_heavy.js.symbols'],
  [5216217, 'panel/app/canvaskit/<rev>/skwasm_heavy.wasm'],
  [76114, 'panel/app/canvaskit/<rev>/webparagraph/canvaskit.js'],
  [963641, 'panel/app/canvaskit/<rev>/webparagraph/canvaskit.js.symbols'],
  [3729129, 'panel/app/canvaskit/<rev>/webparagraph/canvaskit.wasm'],
  [1813030, 'panel/app/canvaskit/<rev>/wimp.js.symbols'],
  [3581677, 'panel/app/canvaskit/<rev>/wimp.wasm'],
  [12343041, 'panel/app/main.dart.js'],
  [2040013, 'sw/agent.js'],
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
/// carrying the sub-floor payload the real zip had.
Directory buildArtifactFixture() {
  final dir = Directory.systemTemp.createTempSync('gh2030_ext_artifact');
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
  test('extension size floor gates the run-41276487426 artifact shape green '
      '(gh-2030)', () {
    final artifact = buildArtifactFixture();
    final result = runGate(artifact: artifact, baselinePath: baseline);
    expect(
      result.exitCode,
      0,
      reason:
          'the committed extension floor must accept the shipped '
          'run-41276487426 shape — the daily-publish cli leg red with '
          '`GREW +7.9% sw/agent.js` (intentional accumulated dart2js '
          'growth, the gate\'s own reseed case). Gate output:\n'
          '${result.stdout}\n${result.stderr}',
    );
    expect(result.stdout, contains('size budget OK'));
  });

  test('committed floor is the byte-exact --reseed output for that shape '
      '(gh-2030)', () {
    final artifact = buildArtifactFixture();
    final reseeded =
        '${Directory.systemTemp.createTempSync('gh2030_reseed').path}/'
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
          'output for the shipped run-41276487426 shape (41 rows '
          '≥ 64 KiB + TOTAL, path-sorted) — any hand-edit drift desyncs '
          'the floor from what the gate would have seeded',
    );
  });
}
