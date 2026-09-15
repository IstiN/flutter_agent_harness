@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #437 PTY ITs: composer steering over a real terminal.
///
/// - AC2 (`IT-PTY-pending-delivered`): a steer typed during a running
///   toolcall renders the panel `pending`, then `delivered` exactly when
///   the message merges at the step boundary; the assistant's next turn
///   reflects the steering text. Never `complete`.
/// - AC5/E1 (`IT-restart-recovery`): the process is killed with the steer
///   still undelivered — the record is on disk; the restart surfaces it,
///   wakes the agent, delivers it (STEERED-ACK), and a second restart
///   does NOT deliver it again (idempotent by record id).
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'steering lifecycle + restart recovery over a real PTY '
    '(issue #437 AC2, AC5, E1)',
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_steer_pty_');
      final projectDir = '${tempHome.path}/project';
      Directory(projectDir).createSync(recursive: true);
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: mock-model
mode: code
approvalMode: yolo
allowedTools: []
''');
      addTearDown(() => tempHome.deleteSync(recursive: true));

      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      // The toolcall turn: a long-enough bash sleep holds the step open so
      // the steering lands mid-toolcall. The steering turn: a marker text
      // proving the model actually received the steered message.
      server.enqueueToolCall('bash', '{"command": "sleep 5"}');
      server.enqueueText('STEERED-ACK done');

      List<String> spawnArgs() => [
        '--provider',
        'openai-completions',
        '--base-url',
        server.baseUrl,
        '--model',
        'mock-model',
        '--session',
        'steer-pty',
      ];

      // ---- Phase 1 (AC2): mid-toolcall steering, pending → delivered.
      final harness = await FaCliHarness.spawn(
        workingDirectory: projectDir,
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'mock'},
        args: spawnArgs(),
      );
      addTearDown(harness.close);
      await harness.waitForBoot(timeout: const Duration(seconds: 300));

      await harness.runSlashCommand('run the tool please');
      await harness.waitForText('bash', timeout: const Duration(seconds: 60));

      // Mid-toolcall: the steer is accepted. The panel must show the
      // honest pending state (persisted, waiting for the boundary).
      harness.sendText('steer me please');
      harness.sendEnter();
      await harness.waitForText(
        'steering from you · pending',
        timeout: const Duration(seconds: 30),
      );

      // The merge happens at the step boundary (when the sleep ends and
      // the tool result lands): the panel flips to delivered and the next
      // model turn reflects the steering text.
      await harness.waitForText(
        '[btw] steering from you → delivered',
        timeout: const Duration(seconds: 90),
      );
      await harness.waitForText(
        'STEERED-ACK',
        timeout: const Duration(seconds: 90),
      );
      expect(
        harness.rawOutput.contains('steering from you → complete'),
        isFalse,
        reason: 'steering panels follow delivery, never the run lifecycle',
      );

      // ---- Phase 2: an UNDELIVERED steer, then a hard kill — exactly the
      // reported 19:40:57 shape (message accepted, process gone).
      server.enqueueToolCall('bash', '{"command": "sleep 8"}');
      server.enqueueText('unused');
      await harness.runSlashCommand('run the tool again');
      await harness.waitForText(
        'sleep 8',
        timeout: const Duration(seconds: 60),
      );
      harness.sendText('rescue me');
      harness.sendEnter();
      await harness.waitForText(
        'steering from you · pending',
        timeout: const Duration(seconds: 30),
      );
      // Give the at-accept persistence a beat, then kill before the
      // boundary can deliver (the sleep holds the run for 8s).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await harness.close();

      // ---- Phase 3 (AC5): the restart recovers the record, queues it,
      // wakes the agent, and delivers it.
      server.enqueueText('STEERED-ACK rescued');
      final harness2 = await FaCliHarness.spawn(
        workingDirectory: projectDir,
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'mock'},
        args: spawnArgs(),
      );
      addTearDown(harness2.close);
      await harness2.waitForBoot(timeout: const Duration(seconds: 300));
      await harness2.waitForText(
        'recovered',
        timeout: const Duration(seconds: 30),
      );
      await harness2.waitForText(
        '[btw] steering from you → delivered',
        timeout: const Duration(seconds: 90),
      );
      await harness2.waitForText(
        'STEERED-ACK rescued',
        timeout: const Duration(seconds: 90),
      );
      await harness2.runSlashCommand('/exit');
      await harness2.close();

      // ---- Phase 4 (E1): the NEXT restart must not re-deliver the same
      // record (consumed once, idempotent by record id).
      final harness3 = await FaCliHarness.spawn(
        workingDirectory: projectDir,
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'mock'},
        args: spawnArgs(),
      );
      addTearDown(harness3.close);
      await harness3.waitForBoot(timeout: const Duration(seconds: 300));
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(
        harness3.rawOutput.contains('recovered'),
        isFalse,
        reason: 'the consumed steering record must not re-enter the queue',
      );
      await harness3.runSlashCommand('/exit');
      await harness3.close();
    },
  );
}
