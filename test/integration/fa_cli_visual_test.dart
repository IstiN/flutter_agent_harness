@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';
import 'terminal_screenshot.dart';

void main() {
  late Directory screenshotsDir;

  setUpAll(() {
    screenshotsDir = Directory('test/integration/screenshots');
    if (!screenshotsDir.existsSync()) {
      screenshotsDir.createSync(recursive: true);
    }
  });

  /// Takes a screenshot of the current terminal screen.
  Future<void> screenshot(FaCliHarness harness, String name) async {
    await renderTerminalScreenshot(
      lines: harness.screenLines,
      outputPath: '${screenshotsDir.path}/$name.png',
    );
  }

  group('boot and model selection', () {
    test('boot → model picker → filter → select', () async {
      final harness = await FaCliHarness.spawn();
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '01_boot');

      // /model opens the model picker
      await harness.runSlashCommand('/model');
      await harness.waitForText(
        'Select model',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '02_model_picker');

      // Type to filter
      harness.sendText('test');
      await harness.waitForOutput(settleMs: 300);
      await screenshot(harness, '03_model_filter');

      // Navigate and select
      harness.sendArrowDown();
      await harness.waitForOutput(settleMs: 300);
      await screenshot(harness, '04_model_highlight');

      harness.sendEnter();
      await harness.waitForOutput(settleMs: 400);
      await screenshot(harness, '05_model_selected');

      await harness.close();
    });

    test('boot → /models list', () async {
      final harness = await FaCliHarness.spawn();
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '10_boot_models');

      await harness.runSlashCommand('/models');
      await harness.waitForOutput(settleMs: 500);
      await screenshot(harness, '11_models_list');

      await harness.close();
    });
  });

  group('provider edit and delete', () {
    test('/provider-edit → Edit picker → wizard steps', () async {
      final tempHome = _tempHomeWithProvider();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '20_boot_provider');

      await harness.runSlashCommand('/provider-edit');
      await harness.waitForText(
        'Delete provider',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '21_edit_delete_picker');

      // Pick Edit (first option — already highlighted)
      harness.sendEnter();
      await harness.waitForText(
        'api type',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '22_wizard_api_type');

      // Pick openai-like (first option)
      harness.sendEnter();
      await harness.waitForText(
        'base URL',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '23_wizard_base_url');

      // Accept default URL (empty = keep current)
      harness.sendEnter();
      await harness.waitForText(
        'provider name',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '24_wizard_name');

      // Accept default name
      harness.sendEnter();
      await harness.waitForText(
        'API key',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '25_wizard_key');

      // Accept empty key (keep existing)
      harness.sendEnter();
      await harness.waitForText('model', timeout: const Duration(seconds: 15));
      await screenshot(harness, '26_wizard_model');

      // Pick first model from list
      harness.sendEnter();
      await harness.waitForOutput(settleMs: 500);
      await screenshot(harness, '27_edit_done');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    test('/provider-edit → Delete picker → confirm → deleted', () async {
      final tempHome = _tempHomeWithProvider();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '30_boot_delete');

      await harness.runSlashCommand('/provider-edit');
      await harness.waitForText(
        'Delete provider',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '31_delete_picker');

      // Navigate to Delete (second option) and confirm
      harness.sendArrowDown();
      harness.sendEnter();
      await harness.waitForText(
        'Yes, delete',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '32_delete_confirm');

      // Pick Yes (first option)
      harness.sendEnter();
      await harness.waitForText(
        'deleted provider',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '33_deleted');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('approval flow', () {
    test(
      'always-ask mode → approval mode set → /approval shows mode',
      () async {
        final tempHome = _tempHomeWithApproval();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        harness.startListening();

        await harness.waitForBoot();
        await screenshot(harness, '40_boot_approval');

        // Set approval mode to always-ask
        await harness.runSlashCommand('/approval always-ask');
        await harness.waitForText(
          'approval mode set to always-ask',
          timeout: const Duration(seconds: 15),
        );
        await screenshot(harness, '41_approval_mode_set');

        // Verify the mode persisted — /approval shows current mode
        await harness.runSlashCommand('/approval');
        await harness.waitForText(
          'approval mode: always-ask',
          timeout: const Duration(seconds: 15),
        );
        await screenshot(harness, '42_approval_mode_shown');

        await harness.close();
        tempHome.deleteSync(recursive: true);
      },
    );
  });

  group('model edit', () {
    test('/model-edit → context window presets', () async {
      final harness = await FaCliHarness.spawn();
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '50_boot_model_edit');

      await harness.runSlashCommand('/model-edit');
      await harness.waitForText(
        'Context Window',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '51_model_edit_picker');

      // Pick Context Window (first option)
      harness.sendEnter();
      await harness.waitForText('4K', timeout: const Duration(seconds: 15));
      await screenshot(harness, '52_context_presets');

      // Pick 128K (navigate down to it)
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      await harness.waitForOutput(settleMs: 300);
      await screenshot(harness, '53_context_highlight');

      harness.sendEnter();
      await harness.waitForText(
        'context window set to',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '54_context_set');

      await harness.close();
    });
  });

  group('key set', () {
    test('/key set → masked value entry', () async {
      final harness = await FaCliHarness.spawn();
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '60_boot_key');

      await harness.runSlashCommand('/key set TEST_KEY');
      await harness.waitForText(
        'Value for',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '61_key_prompt');

      // Type a value (should be masked)
      harness.sendText('secret123');
      await harness.waitForOutput(settleMs: 300);
      await screenshot(harness, '62_key_masked');

      harness.sendEnter();
      await harness.waitForText('saved', timeout: const Duration(seconds: 15));
      await screenshot(harness, '63_key_saved');

      await harness.close();
    });
  });

  group('mcp', () {
    test('/mcp shows guidance when no servers configured', () async {
      final harness = await FaCliHarness.spawn();
      harness.startListening();

      await harness.waitForBoot();
      await screenshot(harness, '70_boot_mcp');

      await harness.runSlashCommand('/mcp');
      await harness.waitForText(
        'No MCP servers configured',
        timeout: const Duration(seconds: 15),
      );
      await screenshot(harness, '71_mcp_no_servers');

      await harness.close();
    });
  });
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
