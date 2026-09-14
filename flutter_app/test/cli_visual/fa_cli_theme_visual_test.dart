@Tags(['integration'])
@Timeout(Duration(minutes: 10))
/// Visual integration tests for the session TUI theme (issue #279): the
/// real `dart bin/fah.dart` runs in a PTY, `/theme` switches hot, and every
/// palette is screenshotted through the real Flutter TerminalView — the
/// PNG shows exactly what a user sees after the swap (E1 repaint included).
///
/// Excluded from the default `flutter test` gate (integration tag); run
/// manually with:
///   cd flutter_app && flutter test test/cli_visual/fa_cli_theme_visual_test.dart --tags integration
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../golden/golden_test_helper.dart';
import 'cli_visual_harness.dart';

void main() {
  late String repoRoot;
  late String shotsDir;
  late Directory tempHome;

  setUpAll(() async {
    await ensureGoldenFonts();
    repoRoot = _findRepoRoot();
    shotsDir = '$repoRoot/test/integration/screenshots';
    final dir = Directory(shotsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Sandboxed HOME: /theme persists tui.theme, and a test must never
    // write the developer's real ~/.fah/config.yaml.
    tempHome = _tempHome();
  });

  tearDownAll(() {
    if (tempHome.existsSync()) tempHome.deleteSync(recursive: true);
  });

  Future<CliVisualHarness> boot(WidgetTester tester) async {
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(
        repoRoot: repoRoot,
        extraEnv: {'HOME': tempHome.path},
      ),
    ))!;
    harness.attach(tester);
    await harness.pumpTerminalView();
    await harness.waitForBoot();
    return harness;
  }

  testWidgets('/theme hot-swaps every palette on the live surface', (
    tester,
  ) async {
    final harness = await boot(tester);
    await harness.screenshot(shotsDir, '140_theme_default');
    expect(harness.screenText, contains('[Model]'));

    for (final entry in const [
      ('ohmypi-dark', '141_theme_ohmypi_dark'),
      ('ohmypi-light', '142_theme_ohmypi_light'),
      ('pi', '143_theme_pi'),
    ]) {
      await harness.runSlashCommand('/theme ${entry.$1}');
      await harness.liveWaitForText(
        'theme: ${entry.$1}',
        timeout: const Duration(seconds: 15),
      );
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, entry.$2);
      expect(harness.screenText, contains('theme: ${entry.$1}'));
    }

    // Bare /theme opens the live picker with swatch previews.
    await harness.runSlashCommand('/theme');
    await harness.liveWaitForText(
      'Select theme',
      timeout: const Duration(seconds: 15),
    );
    await harness.settle(settleMs: 400);
    await harness.screenshot(shotsDir, '144_theme_picker');
    expect(harness.screenText, contains('ohmypi-dark'));
    harness.sendEscape();
    await harness.settle(settleMs: 300);

    // reset returns to the boot palette.
    await harness.runSlashCommand('/theme reset');
    await harness.liveWaitForText(
      'theme: default',
      timeout: const Duration(seconds: 15),
    );
    await harness.close();
  });
}

/// Walks up to the flutter_agent repo root (marker: bin/fah.dart).
String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/bin/fah.dart').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('flutter_agent repo root not found from $dir');
    }
    dir = parent;
  }
}

/// Temp HOME with an offline custom provider - never contacts the network.
Directory _tempHome() {
  final tempHome = Directory.systemTemp.createTempSync('fa_theme_test_');
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
  return tempHome;
}
