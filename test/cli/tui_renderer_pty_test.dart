@Tags(['io'])
@Timeout(Duration(minutes: 4))
library;

// PTY byte-contract regression for the differential cell renderer (#342).
//
// The CellRenderer diffs frames at cell level and skips unchanged cells.
// For rows containing glyphs whose 2-cell width is a heuristic (▸ U+25B8,
// ✓ U+2713 — East-Asian AMBIGUOUS: dart_tui's emoji table says 2 cells,
// wcwidth-based terminals like this harness's xterm say 1), surgical
// cursor addressing computed from OUR table lands one column off, and
// skipped "unchanged" cells keep the PREVIOUS frame's bytes on screen.
// On the /settings → provider → Edit/Delete picker transition that left
// the emulator screen reading '▸ tEdi- rovider h…' while the byte stream
// never carried 'Edit provider' — the settings PTY suite timed out (#342).
//
// Unlike the settings PTY suite (integration-tagged, gardener-only — the
// regression surfaced a day late), this test is io-tagged so the CI core
// shards (`dart test --exclude-tags integration`) run it on every PR: a
// break in the renderer's byte contract gates the PR that breaks it.

import 'dart:io';

import 'package:test/test.dart';

import '../integration/pty_harness.dart';

void main() {
  test(
    'differential picker transition stays byte-faithful on a PTY (#342)',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_pty_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
customProviders:
  - name: test-provider
    apiType: openai
    baseUrl: http://localhost:9999/v1
    modelId: test-model
''');
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();
      await harness.runSlashCommand('/settings');
      await harness.waitForText(
        'Provider',
        timeout: const Duration(seconds: 20),
      );
      harness.sendEnter();
      await harness.waitForText(
        'test-provider',
        timeout: const Duration(seconds: 20),
      );
      harness.sendEnter();

      // The overlay transition whose rows share cells with the previous
      // picker (the ▸ marker, the 'provider' word) must still deliver the
      // new picker BOTH to the emulator screen AND as contiguous bytes in
      // the PTY output stream (screen-scraping consumers read the bytes).
      final raw = await harness.waitForText(
        'Edit provider',
        timeout: const Duration(seconds: 20),
      );
      expect(harness.screenText, contains('Edit provider'));
      expect(harness.screenText, contains('Delete provider'));
      expect(raw, contains('Edit provider'));

      // Leave the picker (Esc reports the cancellation to the wizard).
      harness.sendEscape();
      await harness.waitForOutput();
    },
  );
}
