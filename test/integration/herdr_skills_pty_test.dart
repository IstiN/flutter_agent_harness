/// herdr skill in the fa TUI (issue #818, ACH.2 TUI surface).
///
/// herdr installs `~/.fah/skills/herdr/SKILL.md`; inside a herdr pane
/// (`HERDR_ENV=1`) the skill must be `/skills`-visible and `/skill:herdr`
/// must invoke — the rendered body leaves fa as the user turn and the
/// model answers.
///
/// PTY-tagged: excluded from the PR suite (shared-checkout CPU), run with
/// `--tags pty`.
@Tags(['pty', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    '/skills lists the installed herdr skill; /skill:herdr invokes',
    () async {
      final repoRoot = Directory.current.path;
      final tempHome = Directory.systemTemp.createTempSync('fa_herdr_pty_');
      addTearDown(() => tempHome.deleteSync(recursive: true));
      File('${tempHome.path}/.fah/skills/herdr/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          File('$repoRoot/docs/integrations/herdr/SKILL.md').readAsStringSync(),
        );
      final server = await MockLlmServer.start()
        ..enqueueText('herdr skill invocation acknowledged');
      addTearDown(server.stop);
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
''');

      final workspace = Directory.systemTemp.createTempSync('fa818ws_');
      addTearDown(() => workspace.deleteSync(recursive: true));

      final harness = await FaCliHarness.spawn(
        workingDirectory: workspace.path,
        extraEnv: {'HOME': tempHome.path, 'HERDR_ENV': '1'},
        columns: 100,
        rows: 40,
      );
      addTearDown(() async {
        await harness.close();
      });

      await harness.waitForBoot();

      // Line-mode /skills lists every discovered skill — herdr must be there.
      harness.sendText('/skills');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText('herdr', timeout: const Duration(seconds: 20));

      // Invocation renders the body and submits it as the user turn.
      harness.sendText('/skill:herdr who is blocked');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText(
        'herdr skill invocation acknowledged',
        timeout: const Duration(seconds: 40),
      );
    },
  );
}
