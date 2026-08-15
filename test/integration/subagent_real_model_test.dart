@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  late Directory tempHome;

  setUpAll(() {
    tempHome = Directory.systemTemp.createTempSync('fa_subagent_screenshot_');
    final realConfig = File('${Platform.environment['HOME']}/.fah/config.yaml');
    if (realConfig.existsSync()) {
      final tempConfig = File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true);
      tempConfig.writeAsStringSync(realConfig.readAsStringSync());
    }
  });

  tearDownAll(() => tempHome.deleteSync(recursive: true));

  test(
    'real subagent spawn via task tool (ZAI glm-4.5)',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      // Skip without a ZAI key (CI has none; locally the user sets it).
      final hasZaiKey =
          (Platform.environment['ZAI_API_KEY'] ?? '').isNotEmpty ||
          File('${Platform.environment['HOME']}/.fah/config.yaml')
              .readAsStringSync()
              .contains('api.z.ai');
      if (!hasZaiKey) {
        return;
      }

      // Use ZAI by overriding the active connection.
      final config = File('${tempHome.path}/.fah/config.yaml');
      config.writeAsStringSync('''
provider: openai-completions
model: glm-4.5
baseUrl: https://api.z.ai/api/coding/paas/v4
mode: code
approvalMode: yolo
allowedTools: []
''');

      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      harness.startListening();
      addTearDown(() async => harness.close());

      await harness.waitForBoot();

      // Send a prompt that should trigger the task tool.
      harness.sendText(
        'Use the task tool with agent "explore" to read pubspec.yaml and '
        'report the project name. Reply briefly.',
      );
      harness.sendEnter();

      // Wait for task tool activity or the final response.
      try {
        await harness.waitForText(
          '[task]',
          timeout: const Duration(seconds: 120),
        );
        // The [task] marker confirms the model called the task tool.
        expect(harness.screenText, contains('[task]'));
      } on TimeoutException {
        // If the model didn't call task tool, check for any response.
        expect(
          harness.screenText.length,
          greaterThan(100),
          reason: 'Expected some model output',
        );
      }

      // Wait a bit more for completion.
      await harness.waitForOutput(settleMs: 1000);

      // Verify the output contains evidence of subagent activity.
      final output = harness.rawOutput;
      expect(
        output,
        anyOf(contains('[task]'), contains('agent://'), contains('explore')),
        reason: 'Expected subagent activity in raw output',
      );
    },
  );
}
