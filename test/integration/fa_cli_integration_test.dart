@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';
import 'terminal_screenshot.dart';

void main() {
  group('Fa CLI integration', () {
    test('boot shows banner and status line', () async {
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();
      final screen = harness.screenText;
      expect(screen, contains('[Context]'));
      expect(screen, contains('[Model]'));
      expect(screen, contains('test-model'));
      // The TUI status line (the input zone has no `fa>` prefix in TUI mode).
      expect(screen, contains('ctx'));

      // Screenshot for vision verification.
      final screenshot = await renderTerminalScreenshot(
        terminal: harness.terminal,
        outputPath: '/tmp/fa_boot.png',
      );
      expect(screenshot.existsSync(), isTrue);
    });

    test(
      '/provider-edit shows Edit/Delete picker for saved provider',
      () async {
        final tempHome = _tempHomeWithProvider();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        await harness.runSlashCommand('/provider-edit');
        await harness.waitForText(
          'Delete provider',
          timeout: const Duration(seconds: 20),
        );

        // The wizard's Edit/Delete picker is on screen.
        final screen = harness.screenText;
        expect(screen, contains('[action]'));
        expect(screen, contains('Edit provider'));
        expect(screen, contains('Delete provider'));

        // Leave the picker (Esc reports the cancellation to the wizard).
        harness.sendEscape();
        await harness.waitForOutput();
      },
    );

    test('/provider-edit delete removes provider with confirmation', () async {
      final tempHome = _tempHomeWithProvider();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      await harness.runSlashCommand('/provider-edit');
      await harness.waitForText(
        'Delete provider',
        timeout: const Duration(seconds: 20),
      );

      // TUI picker: arrows navigate, Enter selects. 'delete' is item 2.
      harness.sendArrowDown();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      harness.sendEnter();
      await harness.waitForText(
        'Yes, delete',
        timeout: const Duration(seconds: 20),
      );

      // The confirmation picker starts on 'Yes, delete'.
      harness.sendEnter();
      await harness.waitForText(
        'deleted provider test-provider',
        timeout: const Duration(seconds: 20),
      );

      await harness.runSlashCommand('/exit');
      await harness.waitForOutput();
    });

    test('/approval always-ask switches the approval mode', () async {
      final tempHome = _tempHomeWithApproval();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      // Commands with arguments close the slash menu while typing;
      // runSlashCommand's extra Escape is a harmless no-op then.
      await harness.runSlashCommand('/approval always-ask');
      await harness.waitForText(
        'approval mode set to always-ask',
        timeout: const Duration(seconds: 20),
      );
    });

    test('prompt zone frame is aligned (regression)', () async {
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      // `/provider custom` opens the guided wizard: an 'api type' picker,
      // then the base-URL TextPromptSpec that renders the framed prompt zone.
      await harness.runSlashCommand('/provider custom');
      await harness.waitForText(
        'api type',
        timeout: const Duration(seconds: 20),
      );

      // Accept the first api type; the base-URL text prompt appears.
      harness.sendEnter();
      await harness.waitForText(
        'base URL',
        timeout: const Duration(seconds: 20),
      );
      await harness.waitForOutput(settleMs: 300);

      // Find border rows (┌, ├, │, └) and verify they all share one width.
      final borderWidths = <int>{};
      for (final line in harness.viewportLines) {
        final trimmedRight = line.trimRight();
        if (trimmedRight.startsWith('┌') ||
            trimmedRight.startsWith('├') ||
            trimmedRight.startsWith('└')) {
          borderWidths.add(trimmedRight.length);
        }
      }
      expect(borderWidths, isNotEmpty, reason: 'no prompt frame rows found');
      expect(
        borderWidths.length,
        1,
        reason: 'Border rows have different widths: $borderWidths',
      );

      final screenshot = await renderTerminalScreenshot(
        terminal: harness.terminal,
        outputPath: '/tmp/fa_prompt_frame.png',
      );
      expect(screenshot.existsSync(), isTrue);

      // Cancel the prompt and the wizard.
      harness.sendEscape();
      await harness.waitForOutput();
    });
  });
}

/// Creates a temp HOME with a minimal keyless config (yolo mode so tests
/// never hit an approval gate).
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

/// Creates a temp HOME with a saved custom provider in the registry.
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
