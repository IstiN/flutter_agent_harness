@Tags(['integration'])
@Timeout(Duration(minutes: 15))
/// fa-side omp REG parity leg (issue #810, S7): boots the real fa CLI in a
/// PTY against the SAME scripted mock the omp reference capture used, and
/// structurally diffs the live fa screens against the committed omp
/// reference twins (`test/integration/screenshots/omp_ref/`):
///
/// - boot screens: chrome row count + status-bar segment
///   presence/order/shape (volatile fields scrubbed by the normalizer);
/// - tool-call / code-block turns: chrome inventory (border-heavy card
///   rows, fence rows) + the turn anchor, both sides;
/// - status-bar band: a theme-token pixel comparison of the #121212 band
///   between the two TerminalView renders (same pipeline, so fills must
///   match).
///
/// SKIPS with a named reason when the reference fixtures have not been
/// captured yet — CI only diffs, never captures (issue #810). Manual run:
///   cd flutter_app && flutter test test/cli_visual/fa_omp_reg_visual_test.dart --tags integration
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../golden/golden_test_helper.dart';
import 'cli_visual_harness.dart';
import 'package:flutter_agent_harness/src/cli/omp_reg_normalizer.dart';
import 'package:flutter_agent_harness/src/cli/omp_reg_scenarios.dart';

/// Documented fa↔omp REG drift baseline (issue #810 review): the two CLIs
/// render genuinely DIFFERENT chrome on the shared surfaces — fa's boot
/// screen is a compact composer frame (13 chrome rows) where omp paints a
/// boxed welcome pane + tip banner (23 rows after the normalizer drops
/// the whole network update notice block); fa's status bar carries 5
/// segments where omp fuses cwd+gauge into 3; fa renders turn chrome as
/// fence rows + the fold indicator (1–2 rows per screen since the #1348
/// bottom-pinned window, see [kRegKnownTurnChrome]) where omp paints full
/// tool-card borders (11/21).
///
/// The parity leg pins these as FACTS, not prose (issue #810 re-review):
/// the finding COUNT (a new kind of drift = fail) plus the numbers and
/// segment signatures each finding must carry. Wording of the normalizer's
/// finding strings stays free — the flutter leg must not couple to it.
const kRegKnownBootDrift = <String, (int, String, String)>{
  // (finding count, chrome-count fragment, segment-count fragment)
  '01_welcome_idle': (
    2,
    'fa 13, omp 23',
    'fa 5 [<word:1>, <path>, <word:1>, <path>, <pct>], '
        'omp 3 [<word:0>, <word:2>, <word:4>]',
  ),
  '02_status_bar_default': (
    2,
    'fa 13, omp 23',
    'fa 5 [<word:1>, <path>, <word:1>, <path>, <pct>], '
        'omp 3 [<word:0>, <word:2>, <word:4>]',
  ),
};

/// Documented turn-chrome inventory drift per surface:
/// (fa rows, omp rows). Same policy as [kRegKnownBootDrift].
///
/// Re-baselined for #1348 (bottom-pinned follow window). fa's two counted
/// rows on these screens are (i) the `──── ^ N lines above fold - PgUp
/// ────` fold-indicator row and (ii) the visible ``` fence rows — the
/// settled tool card paints band chrome without box glyphs. Under the
/// #827 turn-start park the window started at the fresh echo: the banner
/// rode the fold (indicator row on EVERY turn screen — 04's second row,
/// 03's only row) and the prior turn's fences stayed hidden. Since #1348
/// the window pins to the bottom: the boot banner fits on the settled
/// glass so 04 shows no fold row (closing ``` only — the opening fence
/// shares the `>_Fa ` prefix line, `>_Fa ```` ``` ```), and 03 shows turn
/// 1's closing fence riding directly above the new prompt above the fold
/// row. The omp side is untouched (fixtures re-captured ⇒ same numbers).
const kRegKnownTurnChrome = <String, (int, int)>{
  '03_tool_call': (2, 11),
  '04_code_block': (1, 21),
};
void main() {
  // Skip decision is made BEFORE the tests are declared: flutter_test has
  // no runtime skip-from-setUpAll, and the PTY legs must never boot
  // without their fixtures (issue #810).
  final repoRoot0 = findRepoRoot();
  final refDir0 = Directory('$repoRoot0/test/integration/screenshots/omp_ref');
  final fixturesReady =
      refDir0.existsSync() &&
      File('${refDir0.path}/provenance.json').existsSync();
  // flutter_test's skip is bool-only; the reason travels in the test name
  // so CI logs still say WHY (issue #810).
  String nameFor(String whenReady) => fixturesReady
      ? whenReady
      : 'SKIP (no omp_ref fixtures): $whenReady — run '
            'omp_ref_capture_test.dart --tags omp-capture on a PTY-capable '
            'host (issue #810)';

  late String repoRoot;
  late String glyph;
  Directory? tempHome;
  Directory? cwdSandbox;
  Directory? faShots;
  MockLlmServer? server;

  setUpAll(() async {
    // flutter_test runs setUpAll even for skipped tests — bail out before
    // booting anything (issue #810).
    if (!fixturesReady) return;
    await ensureGoldenFonts();
    repoRoot = repoRoot0;
    glyph = kRegSeparatorGlyphs['powerline-thin']!;
    server = await MockLlmServer.start(
      script: MockLlmScript.parse(kRegMockScriptYaml),
    );
    // fa-side renders are runtime outputs — they go to a temp dir, never
    // the shared screenshots dir (only omp reference fixtures live there).
    faShots = Directory.systemTemp.createTempSync('fa_reg_shots_');
    // Same git-clean sandbox convention as the omp capture.
    cwdSandbox = Directory.systemTemp.createTempSync('fa_reg_cwd_');
    File('${cwdSandbox!.path}/note.md').writeAsStringSync(kRegNoteContent);
    tempHome = Directory.systemTemp.createTempSync('fa_reg_home_');
    File('${tempHome!.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
provider: openai-completions
model: $kRegModelId
baseUrl: ${server!.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
customProviders:
  - name: reg-provider
    apiType: openai
    baseUrl: ${server!.baseUrl}
    modelId: $kRegModelId
tui:
  statusLine:
    # The omp reference capture pins symbolPreset: nerd; mirror the same
    # E0B1 powerline-thin glyph table on the fa side (issue #918).
    nerdSymbols: true
''');
  });

  tearDownAll(() {
    server?.stop();
    final dirs = [faShots, cwdSandbox, tempHome].whereType<Directory>();
    for (final dir in dirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  Future<CliVisualHarness> bootFa(WidgetTester tester) async {
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(
        repoRoot: repoRoot,
        // Absolute script path: the sandbox is not the repo root.
        executableArgs: ['$repoRoot/bin/fah.dart'],
        workingDirectory: cwdSandbox!.path,
        extraEnv: {'HOME': tempHome!.path},
      ),
    ))!;
    harness.attach(tester);
    await harness.pumpTerminalView();
    await harness.waitForBoot();
    return harness;
  }

  /// Structural boot-screen diff against the committed omp twin.
  List<String> bootDiff(String name) => structuralDiff(
    File('${faShots!.path}/$name.txt').readAsLinesSync(),
    File(
      '$repoRoot/test/integration/screenshots/omp_ref/$name.txt',
    ).readAsLinesSync(),
    surfaceName: name,
    separatorGlyph: glyph,
  );

  /// Asserts the boot surface shows EXACTLY the documented drift and
  /// nothing new: finding count, then the numbers + segment signatures
  /// each finding must carry. Facts, not prose — the normalizer's
  /// wording stays free to change (issue #810 re-review).
  void expectDocumentedBootDrift(String name) {
    final findings = bootDiff(name);
    final (count, chromeFrag, segFrag) = kRegKnownBootDrift[name]!;
    expect(
      findings,
      hasLength(count),
      reason:
          '$name: NEW chrome drift vs the documented REG baseline '
          '(expected $count findings) — reconcile fa/omp rendering or '
          're-baseline the documented set (issue #810 review): $findings',
    );
    expect(
      findings.join('\n'),
      contains(chromeFrag),
      reason:
          '$name: the chrome-row count fragment drifted from the '
          'documented baseline (issue #810 review)',
    );
    expect(
      findings.join('\n'),
      contains(segFrag),
      reason:
          '$name: the bar segment signature drifted from the documented '
          'baseline (issue #810 review)',
    );
  }

  testWidgets(
    nameFor('welcome/idle + status bar: fa screen matches omp reference'),
    (tester) async {
      final harness = await bootFa(tester);
      addTearDown(() => harness.close());
      await harness.screenshot(faShots!.path, '01_welcome_idle');
      await harness.screenshot(faShots!.path, '02_status_bar_default');

      expectDocumentedBootDrift('01_welcome_idle');
      expectDocumentedBootDrift('02_status_bar_default');
      _pixelCompareBand(faShots!.path, '02_status_bar_default', repoRoot);

      // Mirror the omp capture session exactly (issue #918): the reference
      // twin drives the code-block turn first — omp's first turn of a
      // session dispatches with an empty toolset at the pinned commit, so
      // the text-only turn must go first there — and captures the tool
      // turn with the snippet residue above it. fa replays the same
      // sequence so the whole-screen chrome row inventory compares
      // like-for-like.
      harness.sendText(kRegPrompts['code_block']!);
      harness.sendEnter();
      await harness.liveWaitForScreen(
        "print('hello omp parity')",
        timeout: const Duration(minutes: 3),
      );

      harness.sendText(kRegPrompts['tool_call']!);
      harness.sendEnter();
      await harness.liveWaitForScreen(
        kRegNoteMarker,
        timeout: const Duration(minutes: 3),
      );
      await harness.screenshot(faShots!.path, '03_tool_call');

      _diffTurnChrome(
        '03_tool_call',
        kRegNoteMarker,
        repoRoot,
        faShots!.path,
        knownDrift: kRegKnownTurnChrome['03_tool_call'],
      );
    },
    skip: !fixturesReady,
  );

  testWidgets(nameFor('fenced code block: chrome matches omp'), (tester) async {
    final harness = await bootFa(tester);
    addTearDown(() => harness.close());

    harness.sendText(kRegPrompts['code_block']!);
    harness.sendEnter();
    await harness.liveWaitForScreen(
      "print('hello omp parity')",
      timeout: const Duration(minutes: 3),
    );
    await harness.screenshot(faShots!.path, '04_code_block');

    _diffTurnChrome(
      '04_code_block',
      "print('hello omp parity')",
      repoRoot,
      faShots!.path,
      knownDrift: kRegKnownTurnChrome['04_code_block'],
    );
  }, skip: !fixturesReady);
}

/// Turn-screen diff scoped to the SHARED chrome: both sides must show the
/// turn anchor and render the same number of chrome-heavy rows (tool-card
/// borders ≥3 box glyphs per row; code fences = ``` rows). The tool
/// RESULT body differs by design (each CLI formats read output its own
/// way), so raw row counts are not compared on turn screens.
void _diffTurnChrome(
  String name,
  String anchor,
  String repoRoot,
  String faShotsDir, {
  (int, int)? knownDrift,
}) {
  final ompLines = File(
    '$repoRoot/test/integration/screenshots/omp_ref/$name.txt',
  ).readAsLinesSync();
  final faLines = File('$faShotsDir/$name.txt').readAsLinesSync();
  final boxRun = RegExp(r'[══║╔╗╚╝╭╮╯╰┌┐└┘─│]');

  int chromeRows(List<String> lines) => lines
      .where(
        (l) =>
            boxRun.allMatches(l).length >= 3 || RegExp(r'^\s*```').hasMatch(l),
      )
      .length;

  // The turn anchor must be on screen on BOTH sides — a stale or
  // mis-captured twin (turn never rendered) would compare vacuously
  // otherwise (issue #810 review).
  expect(
    ompLines.join('\n'),
    contains(anchor),
    reason:
        '$name: omp reference twin is missing the turn anchor — the '
        'twin was captured before the turn rendered; re-capture',
  );
  expect(
    faLines.join('\n'),
    contains(anchor),
    reason: '$name: fa screen is missing the turn anchor',
  );
  if (knownDrift == null) {
    expect(
      chromeRows(faLines),
      chromeRows(ompLines),
      reason:
          '$name: chrome row inventory differs (tool-card borders / '
          'fences) — no documented drift for this surface; reconcile or '
          'baseline it (issue #810 review)',
    );
  } else {
    // Documented fa↔omp chrome inventory drift (issue #810 review): pin
    // each side to its baseline number so drift on EITHER side — fa
    // changing its turn chrome, or the omp reference fixtures being
    // re-captured — fails instead of silently shipping.
    expect(
      chromeRows(faLines),
      knownDrift.$1,
      reason:
          '$name: fa chrome row inventory drifted from the documented '
          'REG baseline',
    );
    expect(
      chromeRows(ompLines),
      knownDrift.$2,
      reason:
          '$name: omp reference chrome inventory drifted — fixtures '
          're-captured? re-baseline the documented set',
    );
  }
}

/// Status-bar band conformance, per side (issue #918 capture reality):
/// the committed omp reference twins were captured with omp's AUTO-DARK
/// theme — statusLineBg #070a10. The capture-time `theme:` pin wrote omp's
/// settings in a shape omp ignores (the committed PNGs show the auto-dark
/// bar), and a re-capture needs a PTY host with the omp checkout, so the
/// omp band token HERE is #070a10. fa paints its band with the active
/// theme's `userMessageBg` token ([StatusLineRoleKey.bandBg] maps there —
/// `#1E222A` on the boot default theme, not the legacy `statusLineBg`
/// #121212). Cross-side pixel equality is therefore impossible by token —
/// each band is instead checked against its OWN documented token: a
/// bottom-region row that is a majority flat fill of the token, with
/// vertical band extent above it (both renders go through the identical
/// TerminalView pipeline, so fills must not bleed) and both bands inside
/// the terminal's bottom rows (geometry parity). A fixture re-capture
/// that flips the omp theme, a fa band regression, or a band drifting
/// out of the bottom rows fails loudly.
void _pixelCompareBand(String faShotsDir, String name, String repoRoot) {
  final ompPng = img.decodePng(
    File(
      '$repoRoot/test/integration/screenshots/omp_ref/$name.png',
    ).readAsBytesSync(),
  )!;
  final faPng = img.decodePng(File('$faShotsDir/$name.png').readAsBytesSync())!;
  expect(faPng.width, ompPng.width, reason: 'render geometry drifted');
  expect(faPng.height, ompPng.height, reason: 'render geometry drifted');

  const ompToken = [0x07, 0x0a, 0x10]; // omp auto-dark, the captured theme
  const faToken = [0x1e, 0x22, 0x2a]; // fa band = theme userMessageBg
  final ompBand = _findBandRow(ompPng, ompToken);
  expect(
    ompBand,
    isNotNull,
    reason:
        'omp band fill (auto-dark #070A10, the captured theme) not found '
        'in the reference render — wrong fixture or theme drift; '
        're-baseline the token if the fixture was legitimately re-captured',
  );
  final faBand = _findBandRow(faPng, faToken);
  expect(
    faBand,
    isNotNull,
    reason:
        'fa band fill (bandBg = theme userMessageBg #1E222A) not found in '
        'the fa render — band regression or theme change',
  );

  // Geometry parity: the bar is bottom-fixed chrome on both sides (fa
  // paints composer input rows below its band, omp a prompt row below
  // its bar — allow the bottom 3 cells of the 36-row terminal).
  final bottomLimit = (ompPng.height * 33) ~/ 36;
  expect(
    ompBand! >= bottomLimit,
    isTrue,
    reason: 'omp band left the terminal bottom rows (y=$ompBand)',
  );
  expect(
    faBand! >= bottomLimit,
    isTrue,
    reason: 'fa band left the terminal bottom rows (y=$faBand)',
  );

  // Vertical extent: the band is a real band, not a stray antialiased
  // row — the rows directly above the found one must still carry the
  // token as a strong minority (glyph pixels carve into the fill, so a
  // majority is required only on the found row itself).
  for (final (label, png, bandY, token) in [
    ('omp', ompPng, ompBand, ompToken),
    ('fa', faPng, faBand, faToken),
  ]) {
    var above = 0;
    var samples = 0;
    final y = bandY - 1;
    if (y < 0) continue;
    for (var x = 0; x < png.width; x += 4) {
      samples++;
      final p = png.getPixel(x, y);
      if ((p.r - token[0]).abs() <= 2 &&
          (p.g - token[1]).abs() <= 2 &&
          (p.b - token[2]).abs() <= 2) {
        above++;
      }
    }
    expect(
      above / samples,
      greaterThanOrEqualTo(0.4),
      reason:
          '$label band has no vertical extent above y=$bandY '
          '(token fill ${(above / samples).toStringAsFixed(2)}) — '
          'paint-pipeline bleed or theme drift',
    );
  }
}

/// Bottom-up scan for the first row that is a majority flat fill of
/// [token] (±2 per channel, sampled every 4px) — the row index, or null
/// when no such row exists.
int? _findBandRow(img.Image png, List<int> token) {
  for (var y = png.height - 1; y >= 0; y--) {
    var fillHits = 0;
    var samples = 0;
    for (var x = 0; x < png.width; x += 4) {
      samples++;
      final p = png.getPixel(x, y);
      if ((p.r - token[0]).abs() <= 2 &&
          (p.g - token[1]).abs() <= 2 &&
          (p.b - token[2]).abs() <= 2) {
        fillHits++;
      }
    }
    if (fillHits >= samples / 2) return y;
  }
  return null;
}
