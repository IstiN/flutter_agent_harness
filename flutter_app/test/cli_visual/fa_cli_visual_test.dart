@Tags(['integration'])
@Timeout(Duration(minutes: 10))
/// Visual integration tests for the Fa CLI: the real `dart bin/fah.dart`
/// runs in a PTY and every step is screenshotted through the real Flutter
/// TerminalView (JetBrainsMono, Fa palette) — what the PNG shows is what a
/// user sees in a real terminal. Each PNG gets a `.txt` twin with the exact
/// xterm screen text for pixel-independent verification.
///
/// Excluded from the default `flutter test` gate (integration tag); run
/// manually with:
///   cd flutter_app && flutter test test/cli_visual --tags integration
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../golden/golden_test_helper.dart';
import 'cli_visual_harness.dart';

void main() {
  late String repoRoot;
  late String shotsDir;

  setUpAll(() async {
    await ensureGoldenFonts();
    repoRoot = _findRepoRoot();
    shotsDir = '$repoRoot/test/integration/screenshots';
    final dir = Directory(shotsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Remove stale screenshots from previous runs so only the current
    // run's output is left in the directory.
    for (final file in dir.listSync()) {
      if (file is File &&
          (file.path.endsWith('.png') || file.path.endsWith('.txt'))) {
        file.deleteSync();
      }
    }
  });

  /// Spawns the CLI, binds the tester, pumps the TerminalView (which sizes
  /// the PTY to the real cell geometry) and waits for the boot banner.
  Future<CliVisualHarness> boot(
    WidgetTester tester, {
    Map<String, String>? extraEnv,
  }) async {
    // runAsync returns T? — spawn never returns null.
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(repoRoot: repoRoot, extraEnv: extraEnv),
    ))!;
    harness.attach(tester);
    await harness.pumpTerminalView();
    await harness.waitForBoot();
    return harness;
  }

  group('boot and model selection', () {
    testWidgets('boot → model picker → filter → select', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '01_boot');

      // /model opens the model picker
      await harness.runSlashCommand('/model');
      await harness.liveWaitForText(
        'Select model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '02_model_picker');

      // Type to filter
      harness.sendText('test');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '03_model_filter');

      // Navigate and select
      harness.sendArrowDown();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '04_model_highlight');

      harness.sendEnter();
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '05_model_selected');

      await harness.close();
    });

    testWidgets('boot → /models list', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '10_boot_models');

      await harness.runSlashCommand('/models');
      await harness.settle(settleMs: 500);
      await harness.screenshot(shotsDir, '11_models_list');

      await harness.close();
    });
  });

  group('provider edit and delete', () {
    testWidgets('/provider-edit → Edit picker → wizard steps', (tester) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '20_boot_provider');

      await harness.runSlashCommand('/provider-edit');
      await harness.liveWaitForText(
        'Delete provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '21_edit_delete_picker');

      // Pick Edit (first option — already highlighted)
      harness.sendEnter();
      await harness.liveWaitForText(
        'api type',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '22_wizard_api_type');

      // Pick openai-like (first option)
      harness.sendEnter();
      await harness.liveWaitForText(
        'base URL',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '23_wizard_base_url');

      // Accept default URL (empty = keep current)
      harness.sendEnter();
      await harness.liveWaitForText(
        'provider name',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '24_wizard_name');

      // Accept default name
      harness.sendEnter();
      await harness.liveWaitForText(
        'API key',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '25_wizard_key');

      // Accept empty key (keep existing)
      harness.sendEnter();
      await harness.liveWaitForText(
        'model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '26_wizard_model');

      // Pick first model from list
      harness.sendEnter();
      await harness.settle(settleMs: 500);
      await harness.screenshot(shotsDir, '27_edit_done');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('/provider-edit → Delete picker → confirm → deleted', (
      tester,
    ) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '30_boot_delete');

      await harness.runSlashCommand('/provider-edit');
      await harness.liveWaitForText(
        'Delete provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '31_delete_picker');

      // Navigate to Delete (second option) and confirm
      harness.sendArrowDown();
      harness.sendEnter();
      await harness.liveWaitForText(
        'Yes, delete',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '32_delete_confirm');

      // Pick Yes (first option)
      harness.sendEnter();
      await harness.liveWaitForText(
        'deleted provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '33_deleted');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('approval flow', () {
    testWidgets('always-ask mode → approval mode set → /approval shows mode', (
      tester,
    ) async {
      final tempHome = _tempHomeWithApproval();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '40_boot_approval');

      // Set approval mode to always-ask
      await harness.runSlashCommand('/approval always-ask');
      await harness.liveWaitForText(
        'approval mode set to always-ask',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '41_approval_mode_set');

      // Verify the mode persisted — bare /approval opens the interactive
      // picker with always-ask marked as current.
      await harness.runSlashCommand('/approval');
      await harness.liveWaitForText(
        '[Approval mode]',
        timeout: const Duration(seconds: 15),
      );
      expect(harness.screenText, contains('always-ask'));
      expect(harness.screenText, contains('(current)'));
      await harness.screenshot(shotsDir, '42_approval_mode_shown');

      // Close the picker.
      harness.sendEscape();

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('model edit', () {
    testWidgets('/model-edit → context window presets', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '50_boot_model_edit');

      await harness.runSlashCommand('/model-edit');
      await harness.liveWaitForText(
        'Context Window',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '51_model_edit_picker');

      // Pick Context Window (first option)
      harness.sendEnter();
      await harness.liveWaitForText('4K', timeout: const Duration(seconds: 15));
      await harness.screenshot(shotsDir, '52_context_presets');

      // Navigate down to 128K
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '53_context_highlight');

      harness.sendEnter();
      await harness.liveWaitForText(
        'context window set to',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '54_context_set');

      await harness.close();
    });
  });

  group('key set', () {
    testWidgets('/key set → masked value entry', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '60_boot_key');

      await harness.runSlashCommand('/key set TEST_KEY');
      await harness.liveWaitForText(
        'Value for',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '61_key_prompt');

      // Type a value (should be masked)
      harness.sendText('secret123');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '62_key_masked');

      harness.sendEnter();
      await harness.liveWaitForText(
        'saved',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '63_key_saved');

      await harness.close();
    });
  });

  group('settings', () {
    testWidgets('/settings hub → chat model: provider → model', (tester) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '80_boot_settings');

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Chat model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '81_settings_hub');

      // Navigate to "Chat model" (third entry) and open it.
      harness.sendArrowDown();
      harness.sendArrowDown();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '82_settings_model_highlight');

      // Step 1: the provider picker (saved entries first).
      harness.sendEnter();
      await harness.liveWaitForText(
        'test-provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '83_settings_chat_provider');

      // Pick the saved test-provider. Its endpoint is dead
      // (localhost:9999), so the model step falls back to manual entry.
      harness.sendEnter();
      await harness.liveWaitForText(
        'model id',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '84_settings_chat_model_manual');

      // Type a model id and submit — the connection switches.
      harness.sendText('picked-model');
      harness.sendEnter();
      await harness.liveWaitForText(
        'switched provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '85_settings_chat_switched');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('/settings hub → media models: slot → provider → model', (
      tester,
    ) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Media models',
        timeout: const Duration(seconds: 15),
      );

      // Navigate to "Media models" (fifth entry) and open it.
      for (var i = 0; i < 4; i++) {
        harness.sendArrowDown();
      }
      harness.sendEnter();

      // Step 1: the slot picker.
      await harness.liveWaitForText(
        'imageGeneration',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '86_settings_media_slot');

      // Pick imageGeneration → the provider picker (openai-compatible).
      harness.sendEnter();
      await harness.liveWaitForText(
        'test-provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '87_settings_media_provider');

      // Pick the saved test-provider; dead endpoint → manual model entry.
      harness.sendEnter();
      await harness.liveWaitForText(
        'model id',
        timeout: const Duration(seconds: 15),
      );
      harness.sendText('image-model-1');
      // Confirm the prompt actually received the text before submitting.
      await harness.liveWaitForText(
        'image-model-1',
        timeout: const Duration(seconds: 15),
      );
      harness.sendEnter();
      await harness.liveWaitForText(
        'slot imageGeneration → image-model-1',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '88_settings_media_done');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('mcp', () {
    testWidgets('/mcp shows guidance when no servers configured', (
      tester,
    ) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '70_boot_mcp');

      await harness.runSlashCommand('/mcp');
      await harness.liveWaitForText(
        'No MCP servers',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '71_mcp_no_servers');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });
}

/// Walks up from the CWD until a directory containing `bin/fah.dart` is
/// found — the flutter_agent repo root regardless of where the test runner
/// was started from.
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

/// Creates a temp HOME with a saved custom provider.
Directory _tempHomeWithProvider() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
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

/// Creates a temp HOME with always-ask approval mode.
Directory _tempHomeWithApproval() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: always-ask
allowedTools: []
''');
  return tempHome;
}

/// Creates a temp HOME with default config (no custom providers, yolo mode).
Directory _tempHome() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
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
  return tempHome;
}
