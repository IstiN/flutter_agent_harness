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
    File('${faShots!}/$name.txt').readAsLinesSync(),
    File(
      '$repoRoot/test/integration/screenshots/omp_ref/$name.txt',
    ).readAsLinesSync(),
    surfaceName: name,
    separatorGlyph: glyph,
  );

  testWidgets(
    nameFor('welcome/idle + status bar: fa screen matches omp reference'),
    (tester) async {
      final harness = await bootFa(tester);
      addTearDown(() => harness.close());
      await harness.screenshot(faShots!.path, '01_welcome_idle');
      await harness.screenshot(faShots!.path, '02_status_bar_default');

      expect(
        bootDiff('01_welcome_idle'),
        isEmpty,
        reason: 'welcome/idle chrome drift vs omp',
      );
      expect(
        bootDiff('02_status_bar_default'),
        isEmpty,
        reason: 'status bar drift vs omp reference',
      );
      _pixelCompareBand(faShots!.path, '02_status_bar_default', repoRoot);
    },
    skip: !fixturesReady,
  );

  testWidgets(
    nameFor('streaming turn with one tool call: chrome matches omp'),
    (tester) async {
      final harness = await bootFa(tester);
      addTearDown(() => harness.close());

      harness.sendText(kRegPrompts['tool_call']!);
      harness.sendEnter();
      await harness.liveWaitForScreen(
        kRegNoteMarker,
        timeout: const Duration(minutes: 3),
      );
      await harness.screenshot(faShots!.path, '03_tool_call');

      _diffTurnChrome('03_tool_call', kRegNoteMarker, repoRoot, faShots!.path);
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
  String faShotsDir,
) {
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
  expect(
    chromeRows(faLines),
    chromeRows(ompLines),
    reason: '$name: chrome row inventory differs (tool-card borders / fences)',
  );
}

/// Theme-token pixel comparison of the status-bar band: finds the bar band
/// row in the omp reference PNG (the #121212 flat fill), then requires the
/// fa render's same row to match across the width — both renders go through
/// the identical TerminalView pipeline, so fills must be identical;
/// antialiased glyph edges are the tolerated minority.
void _pixelCompareBand(String faShotsDir, String name, String repoRoot) {
  final ompPng = img.decodePng(
    File(
      '$repoRoot/test/integration/screenshots/omp_ref/$name.png',
    ).readAsBytesSync(),
  )!;
  final faPng = img.decodePng(File('$faShotsDir/$name.png').readAsBytesSync())!;
  expect(faPng.width, ompPng.width, reason: 'render geometry drifted');
  expect(faPng.height, ompPng.height, reason: 'render geometry drifted');

  var bandY = -1;
  for (var y = ompPng.height - 1; y >= 0 && bandY < 0; y--) {
    var fillHits = 0;
    var samples = 0;
    for (var x = 0; x < ompPng.width; x += 4) {
      samples++;
      final p = ompPng.getPixel(x, y);
      if ((p.r - 0x12).abs() <= 2 &&
          (p.g - 0x12).abs() <= 2 &&
          (p.b - 0x12).abs() <= 2) {
        fillHits++;
      }
    }
    if (fillHits >= samples / 2) bandY = y;
  }
  expect(
    bandY,
    greaterThanOrEqualTo(0),
    reason: 'omp band fill (#121212) not found in the reference render',
  );

  var equal = 0;
  var total = 0;
  for (final dy in [-1, 0, 1]) {
    final y = bandY + dy;
    if (y < 0 || y >= ompPng.height) continue;
    for (var x = 0; x < ompPng.width; x += 4) {
      total++;
      final a = ompPng.getPixel(x, y);
      final b = faPng.getPixel(x, y);
      if ((a.r - b.r).abs() <= 3 &&
          (a.g - b.g).abs() <= 3 &&
          (a.b - b.b).abs() <= 3) {
        equal++;
      }
    }
  }
  expect(
    equal / total,
    greaterThanOrEqualTo(0.8),
    reason: 'fa band pixels diverge from the omp reference at y=$bandY',
  );
}
