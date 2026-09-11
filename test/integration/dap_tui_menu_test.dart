/// PTY integration tests for the interactive `/dap` TUI menu: the slash
/// menu hint, the guided menu itself (options + descriptions), the
/// friendly disabled status, the masked master-secret flow, and the
/// interactive connect flow — the last two against a real in-process
/// FakeHub the spawned CLI dials over loopback.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';
import '../hub/fake_hub.dart';
import 'pty_harness.dart';

void main() {
  group('/dap TUI menu', () {
    test('slash menu shows the /dap hint', () async {
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
        args: ['--plugin', 'hub'],
        columns: 120,
        rows: 30,
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      // Typing a prefix opens the slash-completion menu; the plugin
      // command carries its description now (no bare duplicate rows).
      harness.sendText('/da');
      await harness.waitForText(
        'end-to-end-encrypted messaging',
        timeout: const Duration(seconds: 15),
      );
      final dapRows = harness.screenLines
          .where((line) => line.contains('/dap'))
          .toList();
      expect(dapRows, hasLength(1), reason: harness.screenText);
      harness.sendEscape();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      harness.sendCtrlC();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await harness.runSlashCommand('/exit');
      await harness.waitForOutput();
    });

    test('bare /dap opens the menu; about prints the explainer', () async {
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
        args: ['--plugin', 'hub'],
        columns: 120,
        rows: 30,
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      await harness.runSlashCommand('/dap');
      await harness.waitForText(
        'Connection status',
        timeout: const Duration(seconds: 20),
      );
      // Every menu label is visible, derived from the structural menu
      // definition.
      for (final option in dapMenuOptions) {
        expect(harness.screenText, contains(option.$2));
      }

      // Walk to "What is DAP?" structurally (no magic arrow counts).
      await _selectMenuOption(harness, 'about');
      await harness.waitForText(
        'zero-knowledge',
        timeout: const Duration(seconds: 20),
      );
      expect(harness.screenText, contains('DAP_MASTER_SECRET'));

      // Regression: plugin output must land in the TRANSCRIPT, above the
      // input frame — a raw-io bypass left it in the composer zone (and a
      // typed character would splice into it mid-text).
      final lines = harness.viewportLines;
      final statusRow = lines.lastIndexWhere((l) => l.contains('turn 0'));
      expect(statusRow, greaterThan(0));
      final inputFrameRow = lines
          .sublist(0, statusRow)
          .lastIndexWhere((l) => l.trim().startsWith('─'));
      expect(inputFrameRow, greaterThan(0));
      final aboutRow = lines.indexWhere((l) => l.contains('zero-knowledge'));
      expect(aboutRow, greaterThan(0));
      expect(aboutRow, lessThan(inputFrameRow));

      await harness.runSlashCommand('/exit');
      await harness.waitForOutput();
    });

    test(
      'status without a master secret is a friendly hint, not Bad state',
      () async {
        final tempHome = _tempHome();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
          args: ['--plugin', 'hub'],
          columns: 120,
          rows: 30,
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        await harness.runSlashCommand('/dap');
        await harness.waitForText(
          'Connection status',
          timeout: const Duration(seconds: 20),
        );
        // Walk to 'status' structurally (no magic arrow counts).
        await _selectMenuOption(harness, 'status');
        await harness.waitForText(
          'DAP disabled — no master secret',
          timeout: const Duration(seconds: 20),
        );
        expect(harness.screenText, isNot(contains('Bad state')));

        await harness.runSlashCommand('/exit');
        await harness.waitForOutput();
      },
    );

    test('set master secret: masked input, then connects to the hub', () async {
      final fakeHub = FakeHub();
      await fakeHub.start();
      addTearDown(fakeHub.stop);
      final tempHome = _tempHome(dapUrl: fakeHub.url.toString());
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
        args: ['--plugin', 'hub'],
        columns: 120,
        rows: 30,
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      await harness.runSlashCommand('/dap');
      await harness.waitForText(
        'Set master secret',
        timeout: const Duration(seconds: 20),
      );
      // Walk to 'secret' structurally (no magic arrow counts).
      await _selectMenuOption(harness, 'secret');
      await harness.waitForText(
        'DAP master secret',
        timeout: const Duration(seconds: 20),
      );

      harness.sendText('pty-test-secret');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Masked: the secret never echoes to the terminal.
      expect(harness.screenText, isNot(contains('pty-test-secret')));
      harness.sendEnter();

      await harness.waitForText(
        'master secret set for this session',
        timeout: const Duration(seconds: 20),
      );
      await fakeHub.waitForHellos(1);
      await harness.waitForText(
        'connected',
        timeout: const Duration(seconds: 30),
      );
      // The typed secret never appeared in the raw output either.
      expect(harness.rawOutput, isNot(contains('pty-test-secret')));

      await harness.runSlashCommand('/exit');
      await harness.waitForOutput();
    });

    test('connect… prompts for the host and dials it', () async {
      final fakeHub = FakeHub();
      await fakeHub.start();
      addTearDown(fakeHub.stop);
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': tempHome.path,
          'DAP_MASTER_SECRET': 'pty-boot-secret',
        },
        args: ['--plugin', 'hub'],
        columns: 120,
        rows: 30,
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      await harness.runSlashCommand('/dap');
      await harness.waitForText(
        'Connect to a hub',
        timeout: const Duration(seconds: 20),
      );
      // Walk to 'connect' structurally (no magic arrow counts).
      await _selectMenuOption(harness, 'connect');
      await harness.waitForText(
        'hub host',
        timeout: const Duration(seconds: 20),
      );

      harness.sendText(fakeHub.url.toString());
      harness.sendEnter();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // name + channel prompts: accept the defaults (empty).
      harness.sendEnter();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      harness.sendEnter();

      await fakeHub.waitForHellos(1);
      await harness.waitForText(
        'connected to ${fakeHub.url}',
        timeout: const Duration(seconds: 30),
      );

      await harness.runSlashCommand('/exit');
      await harness.waitForOutput();
    });
  });
}

/// Arrow-down count that reaches [key] in the `/dap` menu, derived from
/// the structural definition [dapMenuOptions] — a menu insertion fails
/// the untagged assert in `test/cli/dap_menu_options_test.dart` at PR
/// time instead of silently corrupting these offsets.
int _arrowsTo(String key) {
  final index = dapMenuOptions.indexWhere((option) => option.$1 == key);
  if (index < 0) {
    fail(
      'no "/dap" menu option "$key" — the menu defines '
      '${[for (final option in dapMenuOptions) option.$1]}',
    );
  }
  return index;
}

/// Walks the open `/dap` menu down to [key] and activates it.
Future<void> _selectMenuOption(FaCliHarness harness, String key) async {
  for (var i = 0; i < _arrowsTo(key); i++) {
    harness.sendArrowDown();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  harness.sendEnter();
}

/// A temp HOME with a minimal config (no real API key needed) and an
/// optional pre-seeded `~/.dap/config.json` pointing at [dapUrl].
Directory _tempHome({String? dapUrl}) {
  final tempHome = Directory.systemTemp.createTempSync('fa_dap_tui_');
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
  if (dapUrl != null) {
    File('${tempHome.path}/.dap/config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"url": "$dapUrl", "name": "pty"}');
  }
  return tempHome;
}
