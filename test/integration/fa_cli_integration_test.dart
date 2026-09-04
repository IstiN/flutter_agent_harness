@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

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
    });

    test(
      '/settings > provider shows Edit/Delete picker for saved provider',
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

        // /settings opens the settings hub; the first entry is "Provider".
        await harness.runSlashCommand('/settings');
        await harness.waitForText(
          'Provider',
          timeout: const Duration(seconds: 20),
        );
        harness.sendEnter();
        // The provider picker lists saved providers first.
        await harness.waitForText(
          'test-provider',
          timeout: const Duration(seconds: 20),
        );
        harness.sendEnter();

        // Selecting the saved provider opens its Edit/Delete picker.
        await harness.waitForText(
          'Edit provider',
          timeout: const Duration(seconds: 20),
        );
        final screen = harness.screenText;
        expect(screen, contains('Edit provider'));
        expect(screen, contains('Delete provider'));

        // Leave the picker (Esc reports the cancellation to the wizard).
        harness.sendEscape();
        await harness.waitForOutput();
      },
    );

    test(
      '/settings > provider delete removes provider with confirmation',
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
        await harness.waitForText(
          'Edit provider',
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
      },
    );

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

      // Cancel the prompt and the wizard.
      harness.sendEscape();
      await harness.waitForOutput();
    });

    test('/model switch is scoped to the launch folder', () async {
      final tempHome = _tempHome();
      final sessionsRoot = Directory.systemTemp.createTempSync('fa_sess_');
      // The CLI resolves its cwd through getcwd(), which canonicalizes the
      // /var → /private/var symlink on macOS; use the resolved paths for
      // spawns and assertions alike.
      final dirA = Directory(
        Directory.systemTemp.createTempSync('fa_folder_a_').path,
      ).resolveSymbolicLinksSync();
      final dirB = Directory(
        Directory.systemTemp.createTempSync('fa_folder_b_').path,
      ).resolveSymbolicLinksSync();
      addTearDown(() async {
        if (sessionsRoot.existsSync()) {
          sessionsRoot.deleteSync(recursive: true);
        }
        if (Directory(dirA).existsSync()) {
          Directory(dirA).deleteSync(recursive: true);
        }
        if (Directory(dirB).existsSync()) {
          Directory(dirB).deleteSync(recursive: true);
        }
      });
      Future<FaCliHarness> spawnIn(String dir) => FaCliHarness.spawn(
        workingDirectory: dir,
        args: ['--session-root', sessionsRoot.path],
        extraEnv: {'HOME': tempHome.path},
      );

      // 1) First launch in folder A: the seed model from config.yaml.
      final h1 = await spawnIn(dirA);
      await h1.waitForBoot();
      expect(h1.screenText, contains('test-model'));
      expect(h1.screenText, isNot(contains('folder-model')));

      await h1.runSlashCommand('/model folder-model');
      await h1.waitForText(
        'switched model to folder-model',
        timeout: const Duration(seconds: 20),
      );
      final stateFileA = File(
        '$sessionsRoot/${encodeSessionCwd(dirA)}/model-state.json',
      );
      // The onModelChanged persistence is fire-and-forget — poll for the
      // file before tearing the process down.
      var saved = false;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!saved && DateTime.now().isBefore(deadline)) {
        saved = stateFileA.existsSync();
        if (!saved) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      // The save rides the awaited onModelChanged chain — eventual by
      // design; the RELAUNCH below is the user-facing guarantee.
      await h1.close();
      // …while the global config keeps its seed model.
      expect(
        File('${tempHome.path}/.fah/config.yaml').readAsStringSync(),
        contains('test-model'),
      );

      final h2 = await spawnIn(dirA);
      await h2.waitForBoot();
      expect(h2.screenText, contains('folder-model'));
      await h2.close();

      //    NOT leak in (the pre-fix bug this test pins).
      final h3 = await spawnIn(dirB);
      await h3.waitForBoot();
      expect(h3.screenText, contains('test-model'));
      expect(h3.screenText, isNot(contains('folder-model')));
      await h3.close();
      tempHome.deleteSync(recursive: true);
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
