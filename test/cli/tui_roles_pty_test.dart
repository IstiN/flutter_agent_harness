@Tags(['io'])
@Timeout(Duration(minutes: 4))
library;

// PTY visual proof for the #444 color-consistency pass.
//
// The unit sweeps (tui_role_sweep_test.dart) prove the emitters are
// role-driven; this test proves the REAL TUI paints them on a live PTY:
//
// - the boot banner carries the composed `>_Fa` mark — bold accent `>_`
//   plus bold accent2 `Fa` (defect 3) — byte-exactly on the wire. The
//   user band (defect 4) and tool-row rails (defect 2) are byte-proven
//   by the tui_user_band_*.ans goldens and tui_role_sweep_test;

import 'dart:io';

import 'package:test/test.dart';

import '../integration/pty_harness.dart';

void main() {
  test(
    'boot banner paints the composed Fa mark on a live PTY (#444)',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_444_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': tempHome.path,
          'COLORTERM': 'truecolor',
          'TERM': 'xterm-256color',
        },
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();
      await harness.waitForOutput();

      // Defect 3, live: the banner mark is the composed two-role mark —
      // bold accent `>_` followed by bold accent2 `Fa` — reaching the
      // terminal byte-exactly (defect 4's band styling is byte-proven by
      // tui_user_band_*.ans and the role sweep; free-text submission on
      // this harness is exercised by the scripted settings PTY suite).
      expect(harness.screenText, contains('>_'));
      expect(harness.screenText, contains('Fa v0.1.0'));
      expect(harness.rawOutput, contains('\x1B[1m\x1B[38;2;94;234;212m>_'));
      expect(harness.rawOutput, contains('\x1B[38;2;129;140;248mFa'));
    },
  );
}
