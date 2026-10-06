@Tags(['omp-capture'])
@Timeout(Duration(minutes: 15))
/// omp REFERENCE capture (issue #810, S7): boots the PINNED omp build
/// (`can1357/oh-my-pi` @ `df624f56b` — see [kRegOmpCommit]) under the SAME
/// PTY + TerminalView harness the fa captures use, against the local
/// scripted mock (MockLlmServer, OpenAI-compatible canned SSE), and stores
/// the four shared-surface screens as committed reference fixtures (`.png`
/// + `.txt` twins + provenance.json) under
/// `test/integration/screenshots/omp_ref/`.
///
/// MANUAL capture, never CI (issue #810: refs are committed artifacts).
/// Requirements on the capturing host:
///   1. bun on PATH (or OMP_BUN=/path/to/bun) — omp runs on bun;
///   2. `OMP_CHECKOUT` pointing at a checkout of oh-my-pi at the pinned
///      commit — the test SKIPs with a named reason otherwise;
///   3. `OMP_CAPTURE=1` — explicit opt-in, because the capture OVERWRITES
///      the committed twins in place; without it the test SKIPs;
///   4. run: cd flutter_app && flutter test \
///        test/cli_visual/omp_ref_capture_test.dart --tags omp-capture
/// CI only diffs the committed fixtures against fa's renders (the REG
/// legs); it never boots omp. When the omp pin moves, re-capture with this
/// test and commit the refreshed twins in the same change.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../golden/golden_test_helper.dart';
import 'cli_visual_harness.dart';
import 'package:flutter_agent_harness/src/cli/omp_reg_normalizer.dart';
import 'package:flutter_agent_harness/src/cli/omp_reg_scenarios.dart';

void main() {
  // Skip decision BEFORE test declaration (flutter_test has no runtime
  // skip-from-setUpAll): the capture must never boot without its prereqs.
  final missing0 = <String>[];
  final ompCheckoutEnv = Platform.environment['OMP_CHECKOUT'];
  if (ompCheckoutEnv == null) {
    missing0.add(
      'OMP_CHECKOUT not set — point it at an oh-my-pi checkout at the '
      'pinned commit $kRegOmpCommit (capture is manual-only, issue #810)',
    );
  } else if (!File(
    '$ompCheckoutEnv/packages/coding-agent/src/cli.ts',
  ).existsSync()) {
    missing0.add(
      'OMP_CHECKOUT=$ompCheckoutEnv has no '
      'packages/coding-agent/src/cli.ts — is it an oh-my-pi checkout at '
      '$kRegOmpCommit?',
    );
  }
  final bun0 = _findBun();
  if (bun0 == null) {
    missing0.add(
      'bun not found (PATH, ~/.bun/bin/bun, /opt/homebrew/bin/bun, '
      '/usr/local/bin/bun, OMP_BUN) — omp cannot boot without it',
    );
  }
  if (Platform.environment['OMP_CAPTURE'] != '1') {
    missing0.add(
      'OMP_CAPTURE=1 not set — the capture overwrites the committed '
      'test/integration/screenshots/omp_ref/ twins in place, so it needs '
      'an explicit opt-in (issue #810 review)',
    );
  }
  // flutter_test's skip is bool-only; the reason travels in the name so
  // CI logs still say WHY (issue #810).
  final canCapture = missing0.isEmpty;
  final captureName = canCapture
      ? 'captures the four omp reference screens + provenance'
      : 'SKIP (capture prereqs missing): captures the omp reference '
            'screens + provenance — ${missing0.join('  ')}';

  late String repoRoot;
  late String ompCheckout;
  late String bunBin;
  Directory? agentDir;
  Directory? cwdSandbox;
  MockLlmServer? server;

  setUpAll(() async {
    // flutter_test runs setUpAll even for skipped tests — bail out before
    // booting anything (issue #810).
    if (!canCapture) return;
    await ensureGoldenFonts();
    repoRoot = findRepoRoot();
    ompCheckout = ompCheckoutEnv!;
    bunBin = bun0!;
    server = await MockLlmServer.start(
      // omp at this pin fires background LLM requests (session titling,
      // today-reminders) that match no scenario; an unmatched request is a
      // 500 and omp retries it in a storm that wedges the UI before the
      // first prompt dispatches (issue #918 capture debugging). A sticky
      // catch-all absorbs them: empty match matches everything, placed
      // LAST so the real prompts still match their scenarios first.
      script: MockLlmScript.parse(
        '$kRegMockScriptYaml\n'
        '  - match: ""\n'
        '    sticky: true\n'
        '    responses:\n'
        "      - text: 'ok'\n",
      ),
    );
    // Hermetic omp agent dir: HOME for the child, carrying
    // .omp/agent/models.yml — omp's custom-provider table (docs/models.md)
    // pointing at the mock server. Sessions/caches land here too.
    agentDir = Directory.systemTemp.createTempSync('omp_capture_home_');
    final modelsYml = File('${agentDir!.path}/.omp/agent/models.yml');
    modelsYml
      ..createSync(recursive: true)
      ..writeAsStringSync(_modelsYaml(server!.baseUrl));
    // Suppress omp's first-run setup wizard (issue #918): a fresh agent dir
    // otherwise drops the CLI into "Setup step 1 of 5 — Set up your
    // providers" right after boot and the tool-call prompt gets typed into
    // the wizard's provider search box. pi-tui setup/wizard.ts
    // selectSetupScenes returns no scenes when startup.setupWizard is false
    // (packages/coding-agent/src/main.ts reads it from agent config.yml).
    File('${agentDir!.path}/.omp/agent/config.yml')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'startup:\n'
        '  setupWizard: false\n'
        // omp's default symbolPreset is "unicode", which downgrades the
        // powerline-thin status-bar separators to fallback chevrons
        // (U+25B6); the REG parity detector counts U+E0B1 runs (the glyph
        // fa renders natively). Pin the nerd preset so both sides emit the
        // same separator band (issue #918 capture debugging).
        'symbolPreset: nerd\n'
        // omp auto-picks a theme whose statusLineBg (#070a10 for the
        // auto-dark default) differs from fa's #121212; the built-in
        // "dark" theme carries exactly #121212 (dark.json statusLineBg).
        'theme:\n'
        '  dark: dark\n',
      );
    // Git-clean capture cwd: the git status segment must be hidden on BOTH
    // sides of the parity diff (the fa REG renders git: null too), and a
    // worktree branch name would leak path shapes into the bar.
    cwdSandbox = Directory.systemTemp.createTempSync('omp_capture_cwd_');
    File('${cwdSandbox!.path}/note.md').writeAsStringSync(kRegNoteContent);
  });

  tearDownAll(() {
    server?.stop();
    final dirs = [agentDir, cwdSandbox].whereType<Directory>();
    for (final dir in dirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  testWidgets(captureName, (tester) async {
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(
        repoRoot: repoRoot,
        executable: bunBin,
        executableArgs: [
          '$ompCheckout/packages/coding-agent/src/cli.ts',
          '--model',
          'mockcap/$kRegModelId',
          '--api-key',
          'dummy-reg-capture',
          '--no-lsp',
          '--no-extensions',
          '--no-session',
        ],
        workingDirectory: cwdSandbox!.path,
        extraEnv: {
          'HOME': agentDir!.path,
          'PATH':
              '${bunBin.substring(0, bunBin.lastIndexOf('/'))}:'
              '${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
        },
      ),
    ))!;
    harness.attach(tester);
    addTearDown(() async {
      await harness.close();
    });

    await harness.pumpTerminalView();
    // omp's first boot compiles the TS entry through bun; give the welcome
    // frame a generous settle instead of a fa-specific banner marker.
    await harness.settle(settleMs: 1500, timeout: const Duration(seconds: 120));

    // Snapshot the omp version OFF THE BOOT FRAME (issue #810 review):
    // the "omp vN.N.N" banner renders at boot and scrolls away with the
    // first turn — reading it at the END (as the first capture did)
    // yielded provenance.omp_version = null. Asserted non-null HERE so a
    // future capture fails loudly instead of committing a null version.
    final bootVersion = _ompVersion(harness.screenText);
    expect(
      bootVersion,
      isNotNull,
      reason:
          'omp version banner not on the boot frame — capture it during '
          'boot (before the first turn scrolls it away), issue #810 review',
    );

    final outDir = '$repoRoot/test/integration/screenshots/omp_ref';
    Directory(outDir).createSync(recursive: true);

    // 1. Welcome/idle boot screen.
    await harness.screenshot(outDir, '01_welcome_idle');
    // 2. Status bar, default preset: DELIBERATELY the same boot frame —
    //    the bar is part of every screen; this twin exists so the bar
    //    diff has a dedicated fixture. The twin-ness is ASSERTED below
    //    (issue #810 review): a capture that (wrongly) drives a
    //    different screen for 02 must fail loudly, not silently commit
    //    a second unrelated fixture.
    await harness.screenshot(outDir, '02_status_bar_default');
    expect(
      File('$outDir/02_status_bar_default.txt').readAsStringSync(),
      File('$outDir/01_welcome_idle.txt').readAsStringSync(),
      reason:
          '02_status_bar_default must stay the boot-frame twin of '
          '01_welcome_idle (the dedicated bar fixture) — capture drove a '
          'different screen for 02 (issue #810 review)',
    );
    // 3 (captured second in file order but driven FIRST): fenced code
    // block — a pure-text turn. omp at the pinned commit dispatches the
    // FIRST turn of a session with an EMPTY toolset (async native tool
    // registry, issue #918): a scripted tool call in turn 1 is dropped and
    // the turn degrades to plain text. The text-only snippet turn completes
    // cleanly and the toolset is attached for every later request, so the
    // tool-call turn below sees its `read` offered and executes it.
    harness.sendText(kRegPrompts['code_block']!);
    harness.sendEnter();
    await harness.liveWaitForScreen(
      "print('hello omp parity')",
      timeout: const Duration(minutes: 3),
    );
    await harness.screenshot(outDir, '04_code_block');

    // 4. Streaming turn with one tool call: the mock returns a `read` call
    //    for note.md, then echoes the real tool result — the unique note
    //    marker lands on screen only after the read actually ran.
    harness.sendText(kRegPrompts['tool_call']!);
    harness.sendEnter();
    await harness.liveWaitForScreen(
      kRegNoteMarker,
      timeout: const Duration(minutes: 5),
    );
    await harness.screenshot(outDir, '03_tool_call');

    final bunVersion = (await tester.runAsync(() async {
      final result = await Process.run(bunBin, ['--version']);
      return result.stdout.toString().trim();
    }))!;

    // COST-SEGMENT POLICY (issue #810 review): the mock model is pinned to
    // a zero-cost flat override, and BOTH sides must hide the cost segment
    // — fa hides unpriced spend; omp's formatBillingSummary returns
    // undefined at $0.00 with a flat override (no subscription, no
    // premium requests, no tariff). Enforce it HERE, at capture time, so
    // a policy drift surfaces in this manual run and never as a red
    // merge-blocking CI leg.
    final barTwin = File('$outDir/02_status_bar_default.txt');
    final ompBar = findStatusBarRow(
      barTwin.readAsLinesSync(),
      kRegSeparatorGlyphs['powerline-thin']!,
    );
    expect(
      ompBar,
      isNotNull,
      reason:
          'captured omp boot screen has no status bar — wrong frame '
          'captured or the status line moved',
    );
    final ompBarScrubbed = scrubVolatile(ompBar!);
    expect(
      ompBarScrubbed.contains('<cost>') || ompBar.contains('\$'),
      isFalse,
      reason:
          'omp renders a cost segment for the zero-priced mock — the '
          'cost-segment policy changed (fa hides unpriced spend). Reconcile '
          'the policy in omp_reg_scenarios/models.yml + '
          'renderFaDefaultBar BEFORE committing these twins (issue #810). '
          'Bar: ${ompBarScrubbed.isEmpty ? ompBar : ompBarScrubbed}',
    );

    // Record the actual rendered PNG size: terminal `columns`/`rows` are
    // CELLS, the PNG is raster pixels — different units, no fixed
    // multiplier (issue #810 review). The REG suite asserts every twin
    // against these numbers.
    final barPng = img.decodePng(
      File('$outDir/02_status_bar_default.png').readAsBytesSync(),
    )!;

    // THEME-PIN GUARD (issue #918 round-2 CI red): the parity leg anchors
    // the omp band on the CAPTURED theme token. The first capture claimed
    // `theme: dark` but committed AUTO-DARK twins (a #070A10 bar — the
    // `theme:` map shape omp ignores) and nothing at capture time caught
    // it. Assert the pinned dark theme's #121212 band fill is actually on
    // screen in the bar region before the twins are committed: a pin that
    // doesn't take must fail HERE (manual run, omp sources at hand), not
    // as a red merge-blocking leg or a silently wrong baseline later.
    var bandHits = 0;
    for (var y = (barPng.height * 33) ~/ 36; y < barPng.height; y++) {
      for (var x = 0; x < barPng.width; x += 4) {
        final p = barPng.getPixel(x, y);
        if ((p.r - 0x12).abs() <= 2 &&
            (p.g - 0x12).abs() <= 2 &&
            (p.b - 0x12).abs() <= 2) {
          bandHits++;
        }
      }
    }
    expect(
      bandHits,
      greaterThan(50),
      reason:
          'the captured omp bar band is not the pinned dark theme '
          '(#121212 statusLineBg) — the `theme:` pin in '
          '.omp/agent/config.yml did not take (omp kept its auto-dark '
          '#070A10, exactly what the first capture committed). Verify the '
          'theme key against omp\'s config parser and re-capture BEFORE '
          'committing these twins (issue #918). #121212 hits in the bar '
          'region: $bandHits',
    );

    final ompCommit = (await tester.runAsync(() async {
      final result = await Process.run('git', [
        '-C',
        ompCheckout,
        'rev-parse',
        'HEAD',
      ]);
      return result.stdout.toString().trim();
    }))!;

    File('$outDir/provenance.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'omp_commit': ompCommit,
        'captured_at': DateTime.now().toUtc().toIso8601String(),
        'omp_version': bootVersion,
        'bun_version': bunVersion,
        'mock_model': 'mockcap/$kRegModelId',
        'scenarios': [
          'welcome/idle boot screen',
          'status bar (default preset, boot)',
          'streaming turn with one tool call (read note.md)',
          'fenced code block',
        ],
        'geometry': {
          'columns': harness.terminal.viewWidth,
          'rows': harness.terminal.viewHeight,
          'render_width': barPng.width,
          'render_height': barPng.height,
        },
      }),
    );
  }, skip: !canCapture);
}

/// models.yml (omp `docs/models.md`) registering the mock as provider
/// `mockcap` with one text model — the id both CLIs address.
///
/// COST POLICY: the explicit `cost:` block is a FLAT-PRICE override at
/// zero (models.md: "explicit model cost ... is a flat-price override and
/// disables inherited time-based pricing"). At $0.00 with no subscription
/// and no tariff, omp's formatBillingSummary yields no visible cost
/// segment — matching fa, which hides unpriced spend. The capture test
/// enforces the hidden-cost invariant on every run (issue #810 review).
String _modelsYaml(String baseUrl) =>
    '''
providers:
  mockcap:
    baseUrl: $baseUrl
    apiKey: dummy-reg-capture
    api: openai-completions
    models:
      - id: $kRegModelId
        name: Test Model
        api: openai-completions
        reasoning: false
        input: [text]
        contextWindow: 200000
        cost:
          input: 0
          output: 0
          cacheRead: 0
          cacheWrite: 0
''';

/// "omp v18.2.7" from the captured banner; null when absent.
String? _ompVersion(String screen) {
  final match = RegExp(r'omp v(\d+\.\d+\.\d+)').firstMatch(screen);
  return match?.group(1);
}

/// bun discovery: OMP_BUN, then the conventional install paths.
String? _findBun() {
  final candidates = [
    if (Platform.environment['OMP_BUN'] != null)
      Platform.environment['OMP_BUN']!,
    '${Platform.environment['HOME'] ?? '/nonexistent'}/.bun/bin/bun',
    '/opt/homebrew/bin/bun',
    '/usr/local/bin/bun',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
