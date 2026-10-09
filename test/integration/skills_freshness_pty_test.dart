/// Skills discovery freshness in the live TUI (gh-1440).
///
/// E2E-1: a `.fah/skills/<name>/SKILL.md` dropped MID-SESSION (after boot)
/// becomes visible without a restart — `/skill:` of the unindexed skill
/// cold-resolves (dim refresh warning on the frame, body reaches the model,
/// AC3) and a plain turn recomposes with it (`/skills` shows the
/// `added mid-session` flag, AC2).
///
/// Neither pre-existing skills PTY suite drops a skill file mid-run — this
/// is genuinely new coverage. PTY-tagged: excluded from the PR suite
/// (shared-checkout CPU), run with `--tags pty`.
@Tags(['pty', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'mid-session skill drop: /skill: cold-resolves, turn recomposition '
    'flags it',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_gh1440_home_');
      addTearDown(() => tempHome.deleteSync(recursive: true));
      final server = await MockLlmServer.start()
        // Turn 1: the cold-resolved /skill:latecomer2 invocation.
        ..enqueueText('cold-resolve acknowledged')
        // Turn 2: the plain recomposition prompt.
        ..enqueueText('turn ok')
        // Turn 3: the now-indexed /skill:latecomer invocation.
        ..enqueueText('latecomer acknowledged');
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

      final workspace = Directory.systemTemp.createTempSync('fa_gh1440_ws_');
      addTearDown(() => workspace.deleteSync(recursive: true));

      final harness = await FaCliHarness.spawn(
        workingDirectory: workspace.path,
        extraEnv: {'HOME': tempHome.path},
        // 120 columns: the /skills rows below must NOT wrap (a wrapped dim
        // tail can split `added mid-session` from its row) — 100 is not
        // enough once path + scope/source flags are appended.
        columns: 120,
        rows: 40,
      );
      addTearDown(() async {
        await harness.close();
      });

      await harness.waitForBoot();

      // Mid-session drop: TWO first-party skills land after boot. No
      // restart, no /reload — only turns and /skill: from here on.
      File('${workspace.path}/.fah/skills/latecomer/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
---
name: latecomer
description: Mid-session arrival
---
LATECOMER-BODY-MARKER original instructions.
''');
      File('${workspace.path}/.fah/skills/latecomer2/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
---
name: latecomer2
description: Mid-session arrival 2
---
LATECOMER2-BODY-MARKER cold-resolve instructions.
''');

      // E2E-2: /skill: of the UNINDEXED skill cold-resolves — the dim
      // refresh warning renders on the frame and the body reaches the
      // mock model. Invoking before any turn keeps the index stale, which
      // is exactly the cold-resolve path. (runSlashCommand, not bare
      // sendText/sendEnter — same ghost-accept race as herdr_skills_test.)
      await harness.runSlashCommand('/skill:latecomer2 now');
      await harness.waitForText(
        'skill latecomer2 discovered since startup — index refreshed',
        timeout: const Duration(seconds: 30),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (true) {
        final bodies = server.chatBodies;
        if (bodies.isNotEmpty &&
            bodies.last.contains('LATECOMER2-BODY-MARKER')) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'the cold-resolved skill body never reached the model; '
            'chatBodies=${bodies.length}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      // E2E-1: a plain turn forces recomposition through the per-turn
      // freshness check.
      await harness.runSlashCommand('hello');
      await harness.waitForText(
        'turn ok',
        timeout: const Duration(seconds: 40),
      );

      // /skills on the real frame lists the latecomer WITH the flag.
      await harness.runSlashCommand('/skills');
      await harness.waitForText(
        'latecomer',
        timeout: const Duration(seconds: 20),
      );
      final skillsScreen = await harness.waitForScreen(
        'added mid-session',
        timeout: const Duration(seconds: 20),
      );
      expect(skillsScreen, contains('latecomer'));
      // Only mid-session arrivals carry the flag; the boot-scan built-ins
      // must not.
      final flaggedRows = RegExp(
        r'^.*added mid-session.*$',
        multiLine: true,
      ).allMatches(skillsScreen).map((m) => m.group(0)!).toList();
      expect(flaggedRows, hasLength(2), reason: skillsScreen);
      for (final row in flaggedRows) {
        expect(row, contains('latecomer'), reason: skillsScreen);
      }

      // E2E-2b: the now-indexed latecomer invokes through the normal path.
      await harness.runSlashCommand('/skill:latecomer go');
      final invokeDeadline = DateTime.now().add(const Duration(seconds: 40));
      while (true) {
        final bodies = server.chatBodies;
        if (bodies.isNotEmpty &&
            bodies.last.contains('LATECOMER-BODY-MARKER')) {
          break;
        }
        if (DateTime.now().isAfter(invokeDeadline)) {
          fail(
            'the indexed latecomer body never reached the model; '
            'chatBodies=${bodies.length}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await harness.waitForText(
        'acknowledged',
        timeout: const Duration(seconds: 40),
      );
    },
  );
}
