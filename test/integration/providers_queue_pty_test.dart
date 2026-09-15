// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// PTY-driven IT for the provider queue's TUI integration (issue #418,
/// id IT-tui-hub): a real `fah` boot with a file-defined queue, then the
/// settings hub row opens the queue editor, the line-mode commands render
/// per-entry health badges, and a mid-session edit applies live (the
/// rebuilt runtime serves the NEXT turn).
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'settings hub row + /providers queue editor over a real PTY '
    '(issue #418 IT-tui-hub)',
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_queue_pty_');
      // Launch from a scratch project dir so the repo's own committed
      // .fah/config.yaml (which declares a queue) cannot shadow the user
      // scope this test exercises.
      final projectDir = '${tempHome.path}/project';
      Directory(projectDir).createSync(recursive: true);
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:1/v1
mode: code
approvalMode: yolo
allowedTools: []
providersQueue:
  - provider_type: openai-completions
    provider_config:
      model: queue-a
      apiKeyEnv: K_A
      baseUrl: http://127.0.0.1:1/v1
  - provider_type: openai-completions
    provider_config:
      model: queue-b
      apiKeyEnv: K_B
      baseUrl: http://127.0.0.1:1/v1
''');
      addTearDown(() => tempHome.deleteSync(recursive: true));

      final harness = await FaCliHarness.spawn(
        workingDirectory: projectDir,
        extraEnv: {'HOME': tempHome.path, 'K_A': 'secret-a', 'K_B': 'secret-b'},
      );
      addTearDown(harness.close);
      await harness.waitForBoot(timeout: const Duration(seconds: 300));

      // The boot notice names the winning scope and the entry count.
      await harness.waitForText(
        'provider queue (2 entries) from user',
        timeout: const Duration(seconds: 60),
      );

      // The line-mode editor renders both entries with badges (the hub
      // row itself is asserted in pure unit tests — the TUI picker needs
      // scrolling the PTY cannot see deterministically).
      await harness.runSlashCommand('/providers queue');
      await harness.waitForText('0. openai-completions/queue-a [current]');
      await harness.waitForText('1. openai-completions/queue-b [healthy]');

      // AC9 guard in the same pass: the secret VALUES never surface in
      // the terminal; only the env NAMES do.
      expect(harness.rawOutput.contains('secret-a'), isFalse);
      expect(harness.rawOutput.contains('secret-b'), isFalse);
      expect(harness.rawOutput.contains('K_A'), isTrue);

      // Remove the head (indexes are 0-based); the edit persists to the
      // WINNING scope's file (user here) and rebuilds the runtime — the
      // notice names the path and promises liveness from the next turn.
      await harness.runSlashCommand('/providers queue remove 0');
      await harness.waitForText('providersQueue updated (1 entries)');
      await harness.waitForText('live from the next turn');

      final config = File(
        '${tempHome.path}/.fah/config.yaml',
      ).readAsStringSync();
      expect(config.contains('queue-a'), isFalse);
      expect(config.contains('queue-b'), isTrue);
      // The scratch project dir stayed clean — no shadowing file created.
      expect(File('$projectDir/.fah/config.yaml').existsSync(), isFalse);
      // AC9: the yaml carries the env indirection, never a key value.
      expect(config.contains('secret-'), isFalse);
    },
  );
}
