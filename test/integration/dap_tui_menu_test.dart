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
        extraEnv: {
          'HOME': tempHome.path,
          'DAP_LOCAL_HUB_URL': await deadLocalHubUrl(),
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
        extraEnv: {
          'HOME': tempHome.path,
          'DAP_LOCAL_HUB_URL': await deadLocalHubUrl(),
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
      // Wait for the menu to be fully painted before asserting labels
      // (raw echo races the paint — see [_waitForMenuPainted]).
      await _waitForMenuPainted(harness, hubRunning: false);
      // Every menu label is visible, derived from the structural menu
      // definition (stopped state — no local hub in this temp HOME).
      for (final option in dapMenuOptions()) {
        expect(harness.screenText, contains(option.$2));
      }

      // Walk to "What is DAP?" structurally (no magic arrow counts).
      await _selectMenuOption(harness, 'about');
      // Wait for the FINAL artifact, not the intermediate 'zero-knowledge'
      // blurb: a late boot-frame repaint can overwrite the screen between
      // two observations (#550 family — raw echo races frame paint on
      // loaded runners); anchoring on the asserted marker itself makes the
      // wait and the expect agree by construction.
      // wait and the expect agree by construction (gh-1049: assert on the
      // CAPTURED screen — a fresh screenText read re-samples mid-render).
      final aboutScreen = await harness.waitForScreen(
        'DAP_MASTER_SECRET',
        timeout: const Duration(seconds: 20),
      );
      expect(aboutScreen, contains('DAP_MASTER_SECRET'));

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
          extraEnv: {
            'HOME': tempHome.path,
            'DAP_LOCAL_HUB_URL': await deadLocalHubUrl(),
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

    // QUARANTINED under gh-1007: LocalHub.waitForHellos 30s timeout under
    // runner load — fix the timing flake and re-enable (mirrors gh-982).
    test('set master secret: masked input, then connects to the hub', () async {
      final fakeHub = FakeHub();
      await fakeHub.start();
      addTearDown(fakeHub.stop);
      final tempHome = _tempHome(dapUrl: fakeHub.url.toString());
      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': tempHome.path,
          'DAP_LOCAL_HUB_URL': await deadLocalHubUrl(),
          // gh-1007 root cause: the PTY harness pins DAP_HUB_URL to a
          // dead loopback port (issue #943 hub hygiene, env beats the
          // tempHome config file), so the in-session secret-set dial
          // must name the fake hub explicitly.
          'DAP_HUB_URL': fakeHub.url.toString(),
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
      // gh-1007: loaded runners deliver the post-secret dial's hello in
      // bursts past 30s — poll with a 90s global ceiling instead of one
      // fixed window (the issue's 'longer/poller timeout' hardening).
      await fakeHub.waitForHellos(1, timeout: const Duration(seconds: 30));
      await harness.waitForText(
        'connected',
        timeout: const Duration(seconds: 30),
      );
      // The typed secret never appeared in the raw output either.
      expect(harness.rawOutput, isNot(contains('pty-test-secret')));

      await harness.runSlashCommand('/exit');
      await harness.waitForOutput();
    });

    test(
      'running hub: the leading row is Stop DAP (AC7, issue #304)',
      () async {
        final hub = FakeHub();
        await hub.start();
        addTearDown(hub.stop);
        final tempHome = _tempHome();
        final harness = await FaCliHarness.spawn(
          extraEnv: {
            'HOME': tempHome.path,
            'DAP_LOCAL_HUB_URL': hub.url.toString(),
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

        // gh-1026: open the menu until it paints the RUNNING shape — the
        // menu's hubRunning rides a 1s-timeout /healthz probe
        // (bin/fah_hub_plugin.dart _defaultHubHealthProbe), and on a
        // loaded host the probe can miss its window, so the menu
        // legitimately paints the STOPPED shape once. Re-opening is the
        // same recovery a human does; the assert below pins the AC7
        // contract only once the running shape is actually on screen.
        await _openRunningHubMenu(harness);
        // The stopped-state row is gone; the rest of the menu is intact.
        expect(
          harness.screenText,
          isNot(contains('Start DAP locally')),
          reason: harness.screenText,
        );
        for (final label in dapMenuOptions(hubRunning: true).map((o) => o.$2)) {
          // gh-1049: assert on the CAPTURED screen, not a fresh read.
          final screen = await harness.waitForScreen(
            label,
            timeout: const Duration(seconds: 20),
          );
          expect(screen, contains(label));
        }

        await harness.runSlashCommand('/exit');
        await harness.waitForOutput();
      },
    );

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
      // name + channel prompts: accept the defaults (empty). Wait for
      // each prompt to RENDER before its Enter — on a loaded runner the
      // prompt can appear later than a fixed 300ms delay, and the blind
      // keystroke is swallowed by the composer (the flow then stalls and
      // the hub never sees the hello — CI-only flake, Linux runners).
      await harness.waitForText(
        'display name (leave empty for the default)',
        timeout: const Duration(seconds: 20),
      );
      harness.sendEnter();
      await harness.waitForText(
        'channel (leave empty for the default room)',
        timeout: const Duration(seconds: 20),
      );
      harness.sendEnter();

      await fakeHub.waitForHellos(1, timeout: const Duration(seconds: 30));
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
  // The stopped shape: the spawned CLI probes no local hub in its temp
  // HOME, so the leading row is the one-step start (AC7).
  final options = dapMenuOptions(hubRunning: false);
  final index = options.indexWhere((option) => option.$1 == key);
  if (index < 0) {
    fail(
      'no "/dap" menu option "$key" — the menu defines '
      '${[for (final option in options) option.$1]}',
    );
  }
  return index;
}

/// Waits until the /dap menu is fully PAINTED: the /dap echo reaches the
/// raw stream one frame before the menu paints, and asserting labels
/// against the pre-paint frame flakes on loaded runners (#550 family —
/// v0.1.405 tag CI; reddened the integ-mock leg on d331157b). Anchors on
/// the LAST menu label of the painted screen before any label assert.
Future<void> _waitForMenuPainted(
  FaCliHarness harness, {
  required bool hubRunning,
}) async {
  final lastLabel = dapMenuOptions(hubRunning: hubRunning).last.$2;
  await harness.waitForScreen(lastLabel, timeout: const Duration(seconds: 20));
}

/// gh-1026: opens the /dap menu until it paints the RUNNING shape
/// (leading row "Stop DAP", no "Start DAP locally"), bounded retries.
///
/// The menu's hubRunning comes from a 1s-timeout /healthz probe of the
/// hub (bin/fah_hub_plugin.dart `_defaultHubHealthProbe`); under host
/// load that window can be missed and the menu legitimately paints the
/// STOPPED shape for that open. The running/stopped menus share every
/// label except the leading row, so a plain wait-for-last-label cannot
/// distinguish them — the retry re-opens (the same recovery a human
/// does) until the state-dependent row is on screen. Fails with the
/// screen dump when the shape never lands.
Future<void> _openRunningHubMenu(FaCliHarness harness) async {
  for (var attempt = 1; attempt <= 5; attempt++) {
    await harness.runSlashCommand('/dap');
    await _waitForMenuPainted(harness, hubRunning: true);
    final screen = harness.screenText;
    if (screen.contains('Stop DAP') && !screen.contains('Start DAP locally')) {
      return;
    }
    // Stopped shape painted — the probe missed its 1s window. Close the
    // menu, let the host catch its breath, retry.
    harness.sendEscape();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  fail(
    'the /dap menu never painted the running-hub shape (leading row '
    '"Stop DAP") — is the FakeHub still serving /healthz?\n'
    '${harness.screenText}',
  );
}

/// Walks the open `/dap` menu down to [key] and activates it.
Future<void> _selectMenuOption(FaCliHarness harness, String key) async {
  for (var i = 0; i < _arrowsTo(key); i++) {
    harness.sendArrowDown();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  harness.sendEnter();
}

/// A dead local-hub url for the one-step start/stop surface: the menu's
/// state probe must never see the machine's real zero-config 8787 hub
/// (or a CI neighbor) — the tests pin the STOPPED state deterministically.
Future<String> deadLocalHubUrl() async {
  final probe = FakeHub();
  await probe.start();
  final port = probe.url.port;
  await probe.stop();
  return 'ws://127.0.0.1:$port/ws';
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
tui:
  classic: true  # pins the classic chrome the status row asserts need (band redesign #805-#807 has its own surface)
''');
  if (dapUrl != null) {
    File('${tempHome.path}/.dap/config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"url": "$dapUrl", "name": "pty"}');
  }
  return tempHome;
}
