@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'fa_cli_fixtures.dart';
import 'pty_harness.dart';

/// The approval prompt selector (always-ask gate) driven through the REAL
/// binary over a PTY against local OpenAI-compatible mocks (issue #931
/// part 3.4: split out of fa_cli_integration_test.dart so the file-level
/// scheduler can run these heavyweight mock-server suites concurrently).
void main() {
  group('approval prompt selector', () {
    test(
      'Cyrillic char becomes a note, 1 approves once through the PTY',
      () async {
        final mock = MockOpenAiServer();
        await mock.start();
        addTearDown(mock.close);
        final tempHome = makeTempHomeForMock(mock.port);
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        // The mock's first answer is a bash tool call — always-ask gates
        // it with the approval prompt.
        harness.sendText('make the file');
        harness.sendEnter();
        await harness.waitForText(
          'Approve once',
          timeout: const Duration(seconds: 30),
        );

        // The live-bug scenario: with a Cyrillic layout the physical y
        // key produces a different character, and typed characters used
        // to be swallowed into the note buffer while the decision never
        // resolved. They must still arrive as a note, AND a
        // layout-proof key must decide.
        harness.sendText('е');
        await harness.waitForText(
          'note: е',
          timeout: const Duration(seconds: 10),
        );
        harness.sendText('1');
        await harness.waitForText(
          'turn-complete',
          timeout: const Duration(seconds: 30),
        );
        // The approval really executed the command: the second model
        // request carries the tool result with the echo's output.
        expect(
          mock.bodies[1].contains('ECHO-RAN-123'),
          isTrue,
          reason: 'approved bash call must have run',
        );
      },
    );

    test('arrow keys move the selection, Enter confirms the deny', () async {
      final mock = MockOpenAiServer();
      await mock.start();
      addTearDown(mock.close);
      final tempHome = makeTempHomeForMock(mock.port);
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      harness.sendText('make the file');
      harness.sendEnter();
      await harness.waitForText(
        'Approve once',
        timeout: const Duration(seconds: 30),
      );
      // Deny is the default highlight: move up to "Approve once" and
      // back down to deny, then confirm with Enter. The selector marker
      // is ASCII '>' — the old ▸ glyph shifted padded rows (issue #109).
      harness.sendArrowUp();
      await harness.waitForText(
        '2. > Always approve',
        timeout: const Duration(seconds: 10),
      );
      harness.sendArrowDown();
      await harness.waitForText(
        '3. > Deny',
        timeout: const Duration(seconds: 10),
      );
      harness.sendEnter();
      // The deny lands: the turn completes WITHOUT the command ever
      // running — the second model request carries the denial, not
      // the echo's output.
      await harness.waitForText(
        'turn-complete',
        timeout: const Duration(seconds: 30),
      );
      // The tool result message carries the denial, not the echo's
      // stdout.
      final secondRequest =
          jsonDecode(mock.bodies[1]) as Map<String, dynamic>;
      final toolResults = (secondRequest['messages'] as List)
          .whereType<Map<String, dynamic>>()
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(toolResults, hasLength(1));
      final resultText = (toolResults.single['content'] as String)
          .toLowerCase();
      expect(resultText, contains('denied'));
      expect(resultText, isNot(contains('echo-ran-123')));
    });
  });
}
