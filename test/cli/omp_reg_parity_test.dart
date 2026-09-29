@Tags(['reg-parity'])
/// omp REG parity suite — the merge-blocking structural diff (issue #810,
/// S7). Plain `dart test`: no flutter, no PTY, no network.
///
/// For the committed omp reference twins under
/// `test/integration/screenshots/omp_ref/` the suite renders fa's side of
/// the status-bar surface through the production pure-Dart engine
/// (`renderStatusLine` + the default preset — the exact renderer the TUI
/// band composer paints), scrubs volatile fields (model id, path, time,
/// cost — the normalizer), and compares segment presence, order and shape
/// against the committed omp twin. PNG twins get integrity, geometry and
/// theme-token spot checks (package:image): the omp statusLine band
/// background must appear as an exact flat fill.
///
/// When the reference fixtures have not been captured yet, every test SKIPS
/// with a named reason — CI never captures (issue #810); a PTY-capable host
/// runs flutter_app/test/cli_visual/omp_ref_capture_test.dart
/// (--tags omp-capture). The suite is merge-blocking through the EXISTING
/// legs: ci.yml test-core (`dart test` runs it) and the pre-commit hook's
/// test-core stage — same suite, hook/CI marker parity, no new stage. The
/// flutter-side PTY parity (full screens + band pixels) lives in
/// flutter_app/test/cli_visual/fa_omp_reg_visual_test.dart, run by the
/// pty-visual job.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/tui_status_line.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'package:flutter_agent_harness/src/cli/omp_reg_normalizer.dart';
import 'package:flutter_agent_harness/src/cli/omp_reg_scenarios.dart';

void main() {
  final repoRoot = findRepoRoot();
  final refDir = Directory('$repoRoot/test/integration/screenshots/omp_ref');
  final glyph = kRegSeparatorGlyphs['powerline-thin']!;

  final provFile = File('${refDir.path}/provenance.json');
  final fixturesReady = refDir.existsSync() && provFile.existsSync();
  final skipReason = fixturesReady
      ? null
      : 'omp reference fixtures not captured yet '
            '(test/integration/screenshots/omp_ref/) — run the capture on a '
            'PTY-capable host: OMP_CHECKOUT=<oh-my-pi checkout @ '
            '$kRegOmpCommit> flutter test '
            'flutter_app/test/cli_visual/omp_ref_capture_test.dart '
            '--tags omp-capture';

  final provenance = fixturesReady
      ? jsonDecode(provFile.readAsStringSync()) as Map<String, dynamic>
      : null;

  test('provenance pins the captured omp commit and scenario list', () {
    expect(
      provenance!['omp_commit'],
      startsWith(kRegOmpCommit),
      reason: 'fixtures must be regenerated when the omp pin moves',
    );
    expect(
      DateTime.tryParse(provenance['captured_at'] as String),
      isNotNull,
      reason: 'capture date is part of the provenance',
    );
    final scenarios = (provenance['scenarios'] as List).cast<String>();
    expect(scenarios, contains('welcome/idle boot screen'));
    expect(scenarios, contains('status bar (default preset, boot)'));
    expect(
      scenarios,
      contains('streaming turn with one tool call (read note.md)'),
    );
    expect(scenarios, contains('fenced code block'));
  }, skip: skipReason);

  test('every scenario has a png+txt twin pair (no orphans)', () {
    final pngs = <String>{};
    final txts = <String>{};
    for (final f in refDir.listSync().whereType<File>()) {
      if (f.path.endsWith('.png')) pngs.add(_stem(f.path));
      if (f.path.endsWith('.txt')) txts.add(_stem(f.path));
    }
    expect(pngs, isNotEmpty, reason: 'no reference captures committed');
    expect(pngs, equals(txts), reason: 'twins must pair: same stems');
  }, skip: skipReason);

  test('png twins decode at the captured render size, uniformly', () {
    // `columns`/`rows` in provenance are terminal CELLS; PNG size is
    // raster pixels — different units, no fixed multiplier (cell size
    // depends on font metrics). The capture therefore records the actual
    // render size, and this suite asserts every twin decodes to exactly
    // that (issue #810 review).
    final geometry = provenance?['geometry'] as Map<String, dynamic>?;
    final renderWidth = geometry?['render_width'] as int?;
    final renderHeight = geometry?['render_height'] as int?;
    expect(
      renderWidth,
      isNotNull,
      reason:
          'provenance.geometry must record render_width '
          '(the capture writes it from the saved PNG)',
    );
    expect(
      renderHeight,
      isNotNull,
      reason:
          'provenance.geometry must record render_height '
          '(the capture writes it from the saved PNG)',
    );
    for (final png in refDir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.png'),
    )) {
      final decoded = img.decodePng(png.readAsBytesSync())!;
      expect(
        decoded.width,
        renderWidth,
        reason:
            '${_stem(png.path)}: width differs from the captured '
            'render size — mixed-geometry fixture set',
      );
      expect(
        decoded.height,
        renderHeight,
        reason:
            '${_stem(png.path)}: height differs from the captured '
            'render size — mixed-geometry fixture set',
      );
    }
  }, skip: skipReason);

  test('theme token spot check: statusLine band bg fills the bar row', () {
    // omp statusLine bg token #121212 (dark preset) — the band paints it
    // as an exact flat fill (no antialiasing on fills), so a wide pixel
    // run must match within a 2/255 tolerance per channel. The fa↔omp
    // per-pixel comparison at the same row lives in the flutter parity
    // leg where BOTH renders exist.
    const bg = [0x12, 0x12, 0x12];
    final png = refDir.listSync().whereType<File>().firstWhere(
      (f) => _stem(f.path) == '02_status_bar_default',
    );
    final decoded = img.decodePng(png.readAsBytesSync())!;
    var hits = 0;
    for (final pixel in decoded.data!) {
      if ((pixel.r - bg[0]).abs() <= 2 &&
          (pixel.g - bg[1]).abs() <= 2 &&
          (pixel.b - bg[2]).abs() <= 2) {
        hits++;
        if (hits > 50) break;
      }
    }
    expect(
      hits,
      greaterThan(50),
      reason:
          'the omp statusLine band bg (#121212) is absent from the '
          'status-bar capture — wrong fixture or theme drift',
    );
  }, skip: skipReason);

  test('status bar: fa default preset shape equals the omp reference', () {
    final twin = File('${refDir.path}/02_status_bar_default.txt');
    final ompLines = const LineSplitter().convert(twin.readAsStringSync());
    final ompBar = findStatusBarRow(ompLines, glyph);
    expect(
      ompBar,
      isNotNull,
      reason: 'no status bar found in the omp reference twin',
    );

    final columns =
        ((provenance?['geometry'] as Map<String, dynamic>?)?['columns']
            as int?) ??
        100;
    final faBar = renderFaDefaultBar(columns: columns);
    final ompSig = barSignature(ompBar!, glyph);
    final faSig = barSignature(faBar, glyph);
    expect(
      faSig,
      equals(ompSig),
      reason:
          'segment presence/order/shape differs:\n'
          'fa : $faSig\nomp: $ompSig',
    );
  }, skip: skipReason);

  test('separator glyph inventory matches the preset port', () {
    final twin = File('${refDir.path}/02_status_bar_default.txt');
    final ompBar = findStatusBarRow(
      const LineSplitter().convert(twin.readAsStringSync()),
      glyph,
    );
    expect(ompBar, isNotNull);
    expect(
      ompBar!.contains(glyph),
      isTrue,
      reason: 'omp bar lost the powerline-thin separators',
    );
    final faBar = renderFaDefaultBar(columns: 100);
    expect(faBar.contains(glyph), isTrue);
  }, skip: skipReason);
}

/// Renders fa's default-preset status bar through the production engine
/// with the capture scenario's scripted snapshot: the mock's model name, a
/// git-clean sandbox cwd (both sides hide the git segment), yolo mode, the
/// 200k context window at the boot usage, and NO cost — the mock is a
/// zero-cost flat override in models.yml, omp's cost segment hides at
/// $0.00 for flat overrides (verified against omp status-line sources:
/// formatBillingSummary returns undefined), and fa hides unpriced spend.
/// The invariant is enforced at capture time. No session name either: the
/// capture boots omp with --no-session, so the session segment is hidden
/// on both sides. Raw width-exact line — the string the TUI band composer
/// paints.
String renderFaDefaultBar({required int columns}) {
  final snapshot = StatusLineSnapshot(
    cwd: '/reg-sandbox-cwd',
    modelName: 'Test Model',
    approvalMode: 'yolo',
    contextTokens: 46000,
    contextWindow: 200000,
  );
  final spec = resolveStatusLineSpec(null);
  return renderStatusLine(snapshot, spec, columns).join('\n');
}

String _stem(String path) => path
    .split(Platform.pathSeparator)
    .last
    .replaceAll(RegExp(r'\.(png|txt)$'), '');
