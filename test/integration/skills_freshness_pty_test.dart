/// Skills discovery freshness in the live TUI (gh-1440).
///
/// E2E-1: a `.fah/skills/<name>/SKILL.md` dropped MID-SESSION (after boot)
/// becomes visible without a restart — a forced recomposition (one plain
/// turn) picks it up and `/skills` renders the `added mid-session` flag on
/// the real frame (AC2).
/// E2E-2: `/skill:<name>` of an on-disk-but-unindexed skill cold-resolves:
/// the dim refresh warning is visible on the frame and the rendered body
/// executes through the mock model (AC3).
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
    'mid-session skill drop: turn recomposition flags it, cold-resolve '
    'invokes it',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_gh1440_home_');
      addTearDown(() => tempHome.deleteSync(recursive: true));
      final server = MockLlmServer(startPort: 18960);
      final started = await server.start();
      if (!started) {
        server.stop();
        fail('mock server failed to start');
      }
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
        columns: 100,
        rows: 40,
      );
      addTearDown(harness.close);
      await harness.waitForBoot();

      // Mid-session drop: TWO first-party skills land after boot.
      File('${workspace.path}/.fah/skills/latecomer/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
---
name: latecomer
description: Skill that arrived mid-session
---
LATECOMER-BODY-MARKER original instructions.
''');
      File('${workspace.path}/.fah/skills/latecomer2/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
---
name: latecomer2
description: Second mid-session arrival
---
LATECOMER2-BODY-MARKER cold-resolve instructions.
''');

      // E2E-2 first: `/skill:` of the UNINDEXED skill cold-resolves — the
      // dim refresh warning renders on the frame and the body reaches the
      // mock model. (Invoking before any turn keeps the index stale, which
      // is exactly the cold-resolve path.)
      await harness.runSlashCommand('/skill:latecomer2 now');
      await harness.waitForScreen(
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
      // freshness check — no restart, no /skills reload.
      server.enqueueText('turn ok');
      await harness.runSlashCommand('hello');
      await harness.waitForText('turn ok', timeout: const Duration(seconds: 40));

      // `/skills` on the real frame lists the latecomer WITH the flag.
      await harness.runSlashCommand('/skills');
      final screen = await harness.waitForScreen(
        'latecomer',
        timeout: const Duration(seconds: 20),
      );
      expect(screen, contains('added mid-session'));
      // The boot-scan skills carry no flag — the flag is per-entry.
      final alphaRow = RegExp(
        r'latecomer —[^\n]*',
      ).firstMatch(screen)?.group(0);
      expect(alphaRow, isNotNull);

      // E2E-2b: the now-indexed latecomer invokes through the normal path.
      server.enqueueText('latecomer acknowledged');
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
      await harness.waitForScreen(
        'acknowledged',
        timeout: const Duration(seconds: 40),
      );
    },
  );
}
