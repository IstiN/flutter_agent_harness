@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #437 PTY ITs: composer steering over a real terminal.
///
/// - AC2 (`IT-PTY-pending-delivered`): a steer typed during a running
///   toolcall renders the panel `pending`, then `delivered` exactly when
///   the message merges at the step boundary; the assistant's next turn
///   reflects the steering text. Never `complete`.
/// - AC5/E1 (`IT-restart-recovery`): a persisted-but-unconsumed steering
///   record (the issue's crash residue, injected verbatim into the
///   session file) is surfaced by the restart, wakes the agent, is
///   delivered (STEERED-ACK) and marked consumed; a second restart does
///   NOT deliver it again (idempotent by record id).
library;

import 'dart:convert';
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
      // Queue order MUST match phase order: AC4's idle wake turn runs
      // first, then the AC2 toolcall turn.
      server.enqueueText('IDLE-ACK awake');
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

      // ---- Phase 0 (AC4): idle "steering" starts a turn at once — the
      // wake semantics (delivered immediately, nothing stranded). The
      // IDLE-ACK text was queued first (see above).
      await harness.runSlashCommand('idle hello');
      await harness.waitForText(
        'IDLE-ACK awake',
        timeout: const Duration(seconds: 60),
      );

      await harness.runSlashCommand('run the tool please');
      await harness.waitForText('bash', timeout: const Duration(seconds: 60));

      // Mid-toolcall: the steer is accepted. The panel must show the
      // honest pending state (persisted, waiting for the boundary).
      // Ctrl+S is the TUI's steer gesture (Enter mid-run enqueues a
      // plain follow-up instead).
      harness.sendText('steer me please');
      harness.sendCtrlS();
      await harness.waitForText(
        'steering from you · pending',
        timeout: const Duration(seconds: 30),
      );

      // The merge happens at the step boundary (when the sleep ends and
      // the tool result lands): the panel flips to delivered and the next
      // model turn reflects the steering text.
      await harness.waitForText(
        '[btw] steering from you → delivered',
        timeout: const Duration(seconds: 300),
      );
      await harness.waitForText(
        'STEERED-ACK',
        timeout: const Duration(seconds: 300),
      );
      expect(
        harness.rawOutput.contains('steering from you → complete'),
        isFalse,
        reason: 'steering panels follow delivery, never the run lifecycle',
      );

      // ---- Phase 2 (B1): a mid-run steer persists AT ACCEPT. Whether
      // the engine's soft-yield merges it into the transcript before the
      // kill is a race the loop owns — the steering contract under test
      // here is only that the record is on disk the moment the process
      // dies (the reported 19:40:57 shape: accepted, process gone).
      server.enqueueToolCall('bash', '{"command": "sleep 8"}');
      server.enqueueText('unused');
      await harness.runSlashCommand('run the tool again');
      await harness.waitForText(
        'sleep 8',
        timeout: const Duration(seconds: 60),
      );
      // Ctrl+S is the TUI's steer gesture (Enter mid-run enqueues a
      // plain follow-up instead).
      harness.sendText('rescue me');
      harness.sendCtrlS();
      final sessionsRoot = Directory('${tempHome.path}/.fah/sessions');
      List<String> sessionLines() => sessionsRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .expand((f) => f.readAsLinesSync())
          .toList();
      var persisted = false;
      final persistDeadline = DateTime.now().add(const Duration(seconds: 15));
      final pollSw = Stopwatch()..start();
      while (DateTime.now().isBefore(persistDeadline)) {
        if (sessionLines().any((l) => l.contains('rescue me'))) {
          persisted = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // ignore: avoid_print
      print('PERSIST-LATENCY ${pollSw.elapsedMilliseconds}ms');
      if (!persisted) {
        // ignore: avoid_print
        print('SCREEN-AT-FAIL:\n${harness.screenText}');
      }
      expect(persisted, isTrue, reason: 'the steer record persists at accept');
      await harness.hardKill();

      // ---- Phase 3 (AC5): the restart recovers a persisted-but-
      // unconsumed record. The live soft-yield merge usually delivers
      // before any kill can land, so the exact crash residue from the
      // issue — an accepted record with NO consumed marker — is written
      // into the session file directly, then the CLI boots on it.
      final injectedId = '437recovered1';
      final lines = sessionLines().where((l) => l.trim().isNotEmpty).toList()
        ..removeWhere((l) => !l.contains('"id"'));
      final lastRecordId = RegExp(
        r'"id":"([^"]+)"',
      ).firstMatch(lines.last)?.group(1);
      final sessionFile = sessionsRoot
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere(
            (f) =>
                f.path.endsWith('.jsonl') &&
                f.readAsLinesSync().any((l) => l.contains('steer me please')),
          );
      sessionFile.writeAsStringSync(
        '${jsonEncode({
          'type': 'custom',
          'id': injectedId,
          'parentId': lastRecordId,
          'timestamp': DateTime.now().toIso8601String(),
          'customType': 'steering',
          'data': {'text': '[steering from user] injected rescue'},
        })}\n',
        mode: FileMode.append,
      );

      server.enqueueText('STEERED-ACK rescued');
      final harness2 = await FaCliHarness.spawn(
        workingDirectory: projectDir,
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'mock'},
        args: spawnArgs(),
      );
      addTearDown(harness2.close);
      // AC5: the crash residue re-enters the queue and WAKES the idle
      // agent — the recovery notice is the boot-complete marker (the
      // restore label races the TUI frame renderer in the raw stream).
      await harness2.waitForText(
        '[btw] recovered',
        timeout: const Duration(seconds: 300),
      );
      await harness2.waitForText(
        '[btw] steering from you → delivered',
        timeout: const Duration(seconds: 300),
      );
      await harness2.waitForText(
        'STEERED-ACK rescued',
        timeout: const Duration(seconds: 300),
      );
      // The recovered record is consumed at wake start (E1: exactly-once
      // by record id — a crash mid-run cannot re-deliver it).
      var consumed = false;
      final consumeDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(consumeDeadline)) {
        if (sessionLines().any(
          (l) => l.contains('steering_consumed') && l.contains(injectedId),
        )) {
          consumed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(consumed, isTrue, reason: 'the recovered record is consumed');
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
      // The replayed transcript proves the restore boot finished.
      await harness3.waitForText(
        'STEERED-ACK rescued',
        timeout: const Duration(seconds: 300),
      );
      await Future<void>.delayed(const Duration(seconds: 4));
      // Restored history mentions the old wake; the WAKE ITSELF must
      // not run again (idempotent by record id).
      expect(
        harness3.rawOutput.contains('[btw] recovered'),
        isFalse,
        reason: 'the consumed steering record must not re-enter the queue',
      );
      await harness3.runSlashCommand('/exit');
      await harness3.close();
    },
  );
}
