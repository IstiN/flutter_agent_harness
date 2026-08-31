@Tags(['integration'])
@Timeout(Duration(minutes: 10))
/// Visual integration tests for the Fa CLI: the real `dart bin/fah.dart`
/// runs in a PTY and every step is screenshotted through the real Flutter
/// TerminalView (JetBrainsMono, Fa palette) — what the PNG shows is what a
/// user sees in a real terminal. Each PNG gets a `.txt` twin with the exact
/// xterm screen text for pixel-independent verification.
///
/// Excluded from the default `flutter test` gate (integration tag); run
/// manually with:
///   cd flutter_app && flutter test test/cli_visual --tags integration
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../golden/golden_test_helper.dart';
import 'cli_visual_harness.dart';

void main() {
  late String repoRoot;
  late String shotsDir;

  setUpAll(() async {
    await ensureGoldenFonts();
    repoRoot = _findRepoRoot();
    shotsDir = '$repoRoot/test/integration/screenshots';
    final dir = Directory(shotsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Remove stale screenshots from previous runs so only the current
    // run's output is left in the directory.
    for (final file in dir.listSync()) {
      if (file is File &&
          (file.path.endsWith('.png') || file.path.endsWith('.txt'))) {
        file.deleteSync();
      }
    }
  });

  /// Spawns the CLI, binds the tester, pumps the TerminalView (which sizes
  /// the PTY to the real cell geometry) and waits for the boot banner.
  Future<CliVisualHarness> boot(
    WidgetTester tester, {
    Map<String, String>? extraEnv,
  }) async {
    // runAsync returns T? — spawn never returns null.
    final harness = (await tester.runAsync(
      () => CliVisualHarness.spawn(repoRoot: repoRoot, extraEnv: extraEnv),
    ))!;
    harness.attach(tester);
    await harness.pumpTerminalView();
    await harness.waitForBoot();
    return harness;
  }

  group('boot and model selection', () {
    testWidgets('boot → model picker → filter → select', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '01_boot');

      // /model opens the model picker
      await harness.runSlashCommand('/model');
      await harness.liveWaitForText(
        'Select model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '02_model_picker');

      // Type to filter
      harness.sendText('test');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '03_model_filter');

      // Navigate and select
      harness.sendArrowDown();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '04_model_highlight');

      harness.sendEnter();
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '05_model_selected');

      await harness.close();
    });

    testWidgets('boot → /models list', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '10_boot_models');

      await harness.runSlashCommand('/models');
      await harness.settle(settleMs: 500);
      await harness.screenshot(shotsDir, '11_models_list');

      await harness.close();
    });
  });

  group('provider edit and delete', () {
    testWidgets('/settings → provider → Edit picker → wizard steps', (
      tester,
    ) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '20_boot_provider');

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Chat model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '20_settings_hub');

      // "Provider" is the first settings entry — open the provider picker.
      harness.sendEnter();
      await harness.liveWaitForText(
        'test-provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '21_provider_picker');

      // The saved provider is first — its selection opens Edit/Delete.
      harness.sendEnter();
      await harness.liveWaitForText(
        'Delete provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '21_edit_delete_picker');

      // Pick Edit (first option — already highlighted)
      harness.sendEnter();
      await harness.liveWaitForText(
        'api type',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '22_wizard_api_type');

      // Pick openai-like (first option)
      harness.sendEnter();
      await harness.liveWaitForText(
        'base URL',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '23_wizard_base_url');

      // Accept default URL (empty = keep current)
      harness.sendEnter();
      await harness.liveWaitForText(
        'provider name',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '24_wizard_name');

      // Accept default name
      harness.sendEnter();
      await harness.liveWaitForText(
        'API key',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '25_wizard_key');

      // Accept empty key (keep existing)
      harness.sendEnter();
      await harness.liveWaitForText(
        'model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '26_wizard_model');

      // Pick first model from list
      harness.sendEnter();
      await harness.settle(settleMs: 500);
      await harness.screenshot(shotsDir, '27_edit_done');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('/settings → provider → Delete picker → confirm → deleted', (
      tester,
    ) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '30_boot_delete');

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Chat model',
        timeout: const Duration(seconds: 15),
      );
      harness.sendEnter();
      await harness.liveWaitForText(
        'test-provider',
        timeout: const Duration(seconds: 15),
      );
      harness.sendEnter();
      await harness.liveWaitForText(
        'Delete provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '31_delete_picker');

      // Navigate to Delete (second option) and confirm
      harness.sendArrowDown();
      harness.sendEnter();
      await harness.liveWaitForText(
        'Yes, delete',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '32_delete_confirm');

      // Pick Yes (first option)
      harness.sendEnter();
      await harness.liveWaitForText(
        'deleted provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '33_deleted');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('add provider presets', () {
    testWidgets('/provider → + Add provider → GitHub Copilot opens sign-in', (
      tester,
    ) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      await harness.runSlashCommand('/provider');
      await harness.liveWaitForText(
        '+ Add provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '28_provider_picker_add');

      // The saved provider is the first row; the add row is second.
      harness.sendArrowDown();
      harness.sendEnter();
      await harness.liveWaitForText(
        'GitHub Copilot',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '29_add_provider_copilot');

      // OpenRouter, ChatGPT (Codex), GitHub Copilot — two downs, enter.
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendEnter();
      await harness.liveWaitForText(
        'Copilot sign-in',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '34_copilot_signin');

      harness.sendEscape();
      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('approval flow', () {
    testWidgets('always-ask mode → approval mode set → /approval shows mode', (
      tester,
    ) async {
      final tempHome = _tempHomeWithApproval();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '40_boot_approval');

      // Set approval mode to always-ask
      await harness.runSlashCommand('/approval always-ask');
      await harness.liveWaitForText(
        'approval mode set to always-ask',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '41_approval_mode_set');

      // Verify the mode persisted — bare /approval opens the interactive
      // picker with always-ask marked as current.
      await harness.runSlashCommand('/approval');
      await harness.liveWaitForText(
        '[Approval mode]',
        timeout: const Duration(seconds: 15),
      );
      expect(harness.screenText, contains('always-ask'));
      expect(harness.screenText, contains('(current)'));
      await harness.screenshot(shotsDir, '42_approval_mode_shown');

      // Close the picker.
      harness.sendEscape();

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('model edit', () {
    testWidgets('/model-edit → context window presets', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '50_boot_model_edit');

      await harness.runSlashCommand('/model-edit');
      await harness.liveWaitForText(
        'Context Window',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '51_model_edit_picker');

      // Pick Context Window (first option)
      harness.sendEnter();
      await harness.liveWaitForText('4K', timeout: const Duration(seconds: 15));
      await harness.screenshot(shotsDir, '52_context_presets');

      // Navigate down to 128K
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      harness.sendArrowDown();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '53_context_highlight');

      harness.sendEnter();
      await harness.liveWaitForText(
        'context window set to',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '54_context_set');

      await harness.close();
    });
  });

  group('key set', () {
    testWidgets('/key set → masked value entry', (tester) async {
      final harness = await boot(tester);
      await harness.screenshot(shotsDir, '60_boot_key');

      await harness.runSlashCommand('/key set TEST_KEY');
      await harness.liveWaitForText(
        'Value for',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '61_key_prompt');

      // Type a value (should be masked)
      harness.sendText('secret123');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '62_key_masked');

      harness.sendEnter();
      await harness.liveWaitForText(
        'saved',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '63_key_saved');

      await harness.close();
    });
  });

  group('agents', () {
    testWidgets('/agents shows the live agents tree', (tester) async {
      final harness = await boot(tester);
      await harness.runSlashCommand('/agents');
      await harness.liveWaitForText(
        'main (orchestrator)',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '90_agents_tree');
      await harness.close();
    });

    // NOTE: the live badge (`bg:` in the status line during an active
    // spawn) is unit-covered via formatActiveAgentsBadge. A real-model
    // visual variant was dropped: the spawn requires a working provider
    // key (the macOS `security` keychain read is HOME-dependent, so a temp
    // HOME cannot resolve stored keys; scoped env keys work but the model
    // may stream past the test's time budget, hanging the harness on
    // close). The agents tree + open session flows are covered below.

    testWidgets('/agents types lists the agent type catalog', (tester) async {
      final harness = await boot(tester);
      await harness.runSlashCommand('/agents types');
      await harness.liveWaitForText(
        'agent types:',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '91_agents_types');
      await harness.close();
    });

    testWidgets('/agents shows pending inbox markers from the messaging '
        'fabric', (tester) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      // Deliver a message into the main agent's file inbox, exactly like
      // another Fa instance (or a child agent) would through the messaging
      // fabric: <sessions>/<cwd-slug>/messages/<sessionId>_main/inbox/.
      // Sessions live under the platform default root (the macOS app-group
      // container when writable, else ~/.fah/sessions).
      final sessionsDir = [
        Directory(
          '${tempHome.path}/Library/Group Containers/'
          'group.dev.fa1.shared/fa/sessions',
        ),
        Directory('${tempHome.path}/.fah/sessions'),
      ].firstWhere((dir) => dir.existsSync(), orElse: () => Directory(''));
      final sessionFile = sessionsDir
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.jsonl'));
      final sessionId = sessionFile.uri.pathSegments.last
          .split('_')
          .last
          .replaceAll('.jsonl', '');
      final inboxDir = Directory(
        '${sessionFile.parent.path}/messages/${sessionId}_main/inbox',
      )..createSync(recursive: true);
      File('${inboxDir.path}/20260816000000_0001_x.json').writeAsStringSync(
        jsonEncode({
          'id': '20260816000000_0001_x',
          'fromId': 'explore:a1',
          'toId': '$sessionId/main',
          'text': 'survey done: 42 files',
          'sentAt': '2026-08-16T00:00:00Z',
          'hops': 0,
        }),
      );

      await harness.runSlashCommand('/agents');
      await harness.liveWaitForText(
        'mail:1',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '92_agents_inbox');

      // Select "main" — the info block opens deterministically (model /
      // children / session rows). The 'N pending' count is racy by design:
      // the wake turn drains the inbox as soon as it starts, and on a
      // loaded machine the 2s watcher beats us.
      harness.sendEnter();
      await harness.liveWaitForText(
        'children:',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '93_main_inbox_info');

      await harness.close();
      // The fabric delivery itself is asserted at the source of truth: the
      // mail text landed in the session file as a user message.
      final sessionText = sessionFile.readAsStringSync();
      expect(sessionText, contains('survey done: 42 files'));
      tempHome.deleteSync(recursive: true);
    });
  });

  group('settings', () {
    testWidgets('/settings hub → chat model: provider → model', (tester) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '80_boot_settings');

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Chat model',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '81_settings_hub');

      // Navigate to "Chat model" (second entry) and open it.
      harness.sendArrowDown();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '82_settings_model_highlight');

      // Step 1: the provider picker (saved entries first).
      harness.sendEnter();
      await harness.liveWaitForText(
        'test-provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '83_settings_chat_provider');

      // Pick the saved test-provider. Its endpoint is dead
      // (localhost:9999), so the model step falls back to manual entry.
      harness.sendEnter();
      await harness.liveWaitForText(
        'model id',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '84_settings_chat_model_manual');

      // Type a model id and submit — the connection switches.
      harness.sendText('picked-model');
      harness.sendEnter();
      await harness.liveWaitForText(
        'switched provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '85_settings_chat_switched');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('/settings hub → media models: slot → provider → model', (
      tester,
    ) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Media models',
        timeout: const Duration(seconds: 15),
      );

      // Navigate to "Media models" (fourth entry) and open it.
      for (var i = 0; i < 3; i++) {
        harness.sendArrowDown();
      }
      harness.sendEnter();

      // Step 1: the slot picker.
      await harness.liveWaitForText(
        'imageGeneration',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '86_settings_media_slot');

      // Pick imageGeneration → the provider picker (openai-compatible).
      harness.sendEnter();
      await harness.liveWaitForText(
        'test-provider',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '87_settings_media_provider');

      // Pick the saved test-provider; dead endpoint → manual model entry.
      harness.sendEnter();
      await harness.liveWaitForText(
        'model id',
        timeout: const Duration(seconds: 15),
      );
      harness.sendText('image-model-1');
      // Confirm the prompt actually received the text before submitting.
      await harness.liveWaitForText(
        'image-model-1',
        timeout: const Duration(seconds: 15),
      );
      harness.sendEnter();
      await harness.liveWaitForText(
        'slot imageGeneration → image-model-1',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '88_settings_media_done');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('mcp', () {
    testWidgets('/mcp shows guidance when no servers configured', (
      tester,
    ) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});
      await harness.screenshot(shotsDir, '70_boot_mcp');

      await harness.runSlashCommand('/mcp');
      await harness.liveWaitForText(
        'No MCP servers',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '71_mcp_no_servers');

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
  });

  group('input, queue and history UX', () {
    testWidgets('a long single-line input soft-wraps into physical rows', (
      tester,
    ) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      // Far longer than any terminal width — the whole text must stay
      // visible as a wrapped paragraph (no horizontal clipping).
      final text = 'wrap-check-${'a' * 120}-middle-${'b' * 120}-wrap-end';
      harness.sendText(text);
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '94_input_wrap');
      // The text wrapped across rows: the tail chunk is visible, and the
      // full single-line string is NOT on screen unwrapped.
      expect(harness.screenText, contains('wrap-check-'));
      expect(harness.screenText, contains('ap-end'));
      expect(harness.screenText, isNot(contains(text)));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('busy queue: enter queues, ↑ pops the message back', (
      tester,
    ) async {
      // A slow endpoint (a python process sleeping on POST) keeps the turn
      // busy; hosting it OUTSIDE the test isolate keeps cleanup trivial.
      const port = 18777;
      final serverScript =
          File('${Directory.systemTemp.path}/fa_slow_server.py')
            ..writeAsStringSync('''
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        time.sleep(120)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", $port), H).serve_forever()
''');
      // Process I/O must run in the REAL-async zone: fake-zone timers
      // (Future.delayed) never fire without a pump, so zone-naive waits
      // hang the test forever.
      final server = (await tester.runAsync(
        () => Process.start('python3', [serverScript.path]),
      ))!;
      final up = await tester.runAsync(() async {
        for (var i = 0; i < 50; i++) {
          try {
            final socket = await Socket.connect('127.0.0.1', port);
            await socket.close();
            return true;
          } on Object {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        return false;
      });
      if (up != true) throw StateError('slow server did not start');
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:$port/v1');
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      // The first message starts the (hanging) turn — the busy row shows
      // the elapsed seconds.
      harness.sendText('first');
      await harness.settle(settleMs: 300, timeout: const Duration(seconds: 2));
      harness.sendEnter();
      await harness.liveWaitForText(
        'Working',
        timeout: const Duration(seconds: 30),
      );

      // The second message queues (❯ row above the input).
      harness.sendText('second');
      await harness.settle(settleMs: 300, timeout: const Duration(seconds: 2));
      harness.sendEnter();
      await harness.liveWaitForText(
        '❯ second',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '95_queue_row');

      // ↑ pops it back into the input for editing (the ❯ row disappears).
      harness.sendArrowUp();
      await harness.settle(settleMs: 300, timeout: const Duration(seconds: 2));
      await harness.screenshot(shotsDir, '96_queue_pop');
      expect(harness.screenText, isNot(contains('❯ second')));

      await harness.close();
      await tester.runAsync(() async {
        server.kill();
        await server.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      });
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('↑/↓ browses the submitted-message history', (tester) async {
      // The dead endpoint errors every turn instantly, so both submits
      // complete and land in the input history.
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('first message');
      await harness.settle(settleMs: 300);
      harness.sendEnter();
      await harness.settle(settleMs: 1500);
      harness.sendText('second message');
      await harness.settle(settleMs: 300);
      harness.sendEnter();
      await harness.settle(settleMs: 1500);

      // ↑ recalls the newest, then the older one; ↓ walks back.
      harness.sendArrowUp();
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '97_history_recall');
      expect(harness.screenText, contains('second message'));
      harness.sendArrowUp();
      await harness.settle(settleMs: 300);
      expect(harness.screenText, contains('first message'));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('generic picker type-to-filter narrows the settings hub', (
      tester,
    ) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      await harness.runSlashCommand('/settings');
      await harness.liveWaitForText(
        'Media models',
        timeout: const Duration(seconds: 30),
      );
      // Type-to-filter on a generic picker: the title echoes the query.
      harness.sendText('med');
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '98_settings_filter');
      expect(harness.screenText, contains('Settings: med'));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('bracketed paste of Cyrillic text stays UTF-8 (no mojibake)', (
      tester,
    ) async {
      final tempHome = _tempHome();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      // dart_tui 2.0.0's paste decoder mapped bytes to Latin-1 char codes;
      // fa repairs it — pasted Cyrillic must render as itself.
      harness
        ..sendText('\x1b[200~')
        ..sendText('Привет, проверка вставки')
        ..sendText('\x1b[201~');
      await harness.settle(settleMs: 400);
      await harness.screenshot(shotsDir, '99_paste_cyrillic');
      expect(harness.screenText, contains('Привет, проверка вставки'));
      expect(harness.screenText, isNot(contains('Ð')));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('a markdown bold span keeps its style across a soft wrap', (
      tester,
    ) async {
      // The canned endpoint answers one long line whose bold span is longer
      // than any terminal row: the wrap MUST cut inside it, and the
      // continuation row must stay bold (SGR carry across the cut).
      final server = await _startAnsweringServer(
        tester,
        18778,
        'Verified: **the bold span deliberately runs past every possible '
        'terminal width so the soft wrap cuts right through the middle of '
        'it** — and this trailing plain suffix proves word wrap.',
      );
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:18778/v1');
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('go');
      await harness.settle(settleMs: 300);
      harness.sendEnter();
      await harness.liveWaitForText(
        'Verified:',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '100_markdown_wrap');
      // The whole line is on screen (wrapped); row splits put newlines into
      // the raw screen text, so assertions run on the flattened form. The
      // markdown markers themselves are consumed by the formatter.
      final flat = harness.screenText.replaceAll('\n', '');
      expect(flat, contains('bold span deliberately'));
      expect(flat, contains('trailing plain suffix'));
      expect(flat, isNot(contains('**')));

      await harness.close();
      await _stopServer(tester, server);
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('ctrl+s during a long bash moves it to a background job '
        'untouched and answers right away', (tester) async {
      // The canned endpoint answers a `sleep 300` tool call to the first
      // user message and a text answer once the user steers mid-tool.
      final server = await _startAnsweringServer(
        tester,
        18779,
        null, // steer mode: tool call first, text after the steer
      );
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:18779/v1');
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('run the long task');
      await harness.settle(settleMs: 300);
      harness.sendEnter();
      await harness.liveWaitForText(
        'sleep 300',
        timeout: const Duration(seconds: 30),
      );

      // Steer mid-tool: the bash call must yield to a background job (the
      // process is NOT killed) and the message is answered immediately.
      harness.sendText('status?');
      await harness.settle(settleMs: 200);
      harness.sendText('\x13'); // ctrl+s
      await harness.liveWaitForText(
        'Working on it',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '101_steer_yield');
      // The follow-up answer mentions the background job (flattened: row
      // splits insert newlines into the raw screen text).
      expect(
        harness.screenText.replaceAll('\n', ''),
        contains('background job'),
      );

      // The job is alive and listed; cancel it by hand.
      await harness.runSlashCommand('/tasks');
      await harness.liveWaitForText(
        'sh-1',
        timeout: const Duration(seconds: 15),
      );
      await harness.screenshot(shotsDir, '102_tasks_shell_job');
      expect(harness.screenText, contains('sleep 300'));

      // Job ids carry a unique suffix (sh-1-<uniq>) — cancel the EXACT id
      // the listing shows.
      final shellJobId = RegExp(
        'sh-[A-Za-z0-9-]+',
      ).firstMatch(harness.screenText)?.group(0);
      expect(shellJobId, isNotNull);

      await harness.runSlashCommand('/tasks cancel $shellJobId');
      await harness.settle(settleMs: 500);
      expect(harness.screenText, contains('stopped $shellJobId'));

      await harness.close();
      await _stopServer(tester, server);
      tempHome.deleteSync(recursive: true);
    });
  });

  group('editing keys — the Cmd+Left (aaaa) regression + secret sheet', () {
    testWidgets('ctrl+a/ctrl+e move the composer cursor without leaking '
        'letters; unhandled combos print nothing', (tester) async {
      final tempHome = _tempHomeWithProvider();
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('hello world');
      await harness.settle(settleMs: 300);
      // macOS Cmd+Left arrives as ^A (0x01): readline start-of-line.
      harness.sendText('\x01');
      await harness.settle(settleMs: 200);
      harness.sendText('X'); // lands at the start iff the cursor moved
      await harness.settle(settleMs: 200);
      // Cmd+Right → ^E: end-of-line.
      harness.sendText('\x05');
      await harness.settle(settleMs: 200);
      harness.sendText('Y');
      await harness.settle(settleMs: 200);
      // Unhandled combos must never leak their base letter.
      harness.sendText('\x18\x07\x1a'); // ctrl+x, ctrl+g, ctrl+z
      await harness.settle(settleMs: 200);
      harness.sendText('Z');
      await harness.settle(settleMs: 300);

      await harness.screenshot(shotsDir, '102_composer_ctrl_keys');
      final flat = harness.screenText.replaceAll('\n', '');
      expect(flat, contains('Xhello worldYZ'));
      expect(flat, isNot(contains('Xhello worldYZxgz')));

      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    testWidgets('request_secret sheet: Ctrl+U clears, dots mask, Ctrl+R '
        'reveals, the saved secret never echoes', (tester) async {
      final server = await _startAnsweringServer(
        tester,
        18780,
        null, // steer/secret mode: 'deploy the app' → request_secret
      );
      final tempHome = _tempHomeWithEndpoint('http://127.0.0.1:18780/v1');
      final harness = await boot(tester, extraEnv: {'HOME': tempHome.path});

      harness.sendText('deploy the app');
      await harness.settle(settleMs: 300);
      harness.sendEnter();
      await harness.liveWaitForText(
        'Name (UPPER_SNAKE)',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '103_secret_sheet_suggested_name');
      expect(harness.screenText, contains('SUDO_PASSWORD'));
      expect(harness.screenText, contains('Ctrl+R reveals'));

      // Ctrl+U on name focus: one keystroke erases the suggested name
      // (the 16-backspace nuisance).
      harness.sendText('\x15');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '104_secret_name_cleared');
      expect(harness.screenText, isNot(contains('SUDO_PASSWORD')));
      expect(harness.screenText, contains('Name must match'));

      // A fresh name, then Tab into the value field.
      harness.sendText('SUDO_X');
      await harness.settle(settleMs: 200);
      harness.sendText('\t');
      await harness.settle(settleMs: 200);
      harness.sendText('hunter2');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '105_secret_dots');
      final dotsScreen = harness.screenText.replaceAll('\n', '');
      expect(dotsScreen, contains('•••••••'));
      expect(dotsScreen, isNot(contains('hunter2')));

      // Ctrl+R reveals the typed value for verification.
      harness.sendText('\x12');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '106_secret_revealed');
      expect(harness.screenText, contains('hunter2'));
      expect(harness.screenText, contains('Ctrl+R hides'));

      // Ctrl+U on value focus kills the field back to the cursor.
      harness.sendText('\x15');
      await harness.settle(settleMs: 300);
      await harness.screenshot(shotsDir, '107_secret_value_cleared');
      final cleared = harness.screenText.replaceAll('\n', '');
      expect(cleared, isNot(contains('hunter2')));
      expect(cleared, isNot(contains('•••')));

      // Retype and save: the grant completes the turn; the transcript
      // must NEVER echo the secret value.
      harness.sendText('hunter2');
      await harness.settle(settleMs: 200);
      harness.sendEnter();
      await harness.liveWaitForText(
        'Secret received',
        timeout: const Duration(seconds: 30),
      );
      await harness.screenshot(shotsDir, '108_secret_saved_no_echo');
      expect(
        harness.screenText.replaceAll('\n', ''),
        isNot(contains('hunter2')),
      );

      await harness.close();
      await _stopServer(tester, server);
      tempHome.deleteSync(recursive: true);
    });
  });
}

/// Walks up from the CWD until a directory containing `bin/fah.dart` is
/// found — the flutter_agent repo root regardless of where the test runner
/// was started from.
String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/bin/fah.dart').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('flutter_agent repo root not found from $dir');
    }
    dir = parent;
  }
}

/// Creates a temp HOME with a saved custom provider.
Directory _tempHomeWithProvider() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
customProviders:
  - name: test-provider
    apiType: openai
    baseUrl: http://localhost:9999/v1
    modelId: test-model
''');
  return tempHome;
}

/// Creates a temp HOME with always-ask approval mode.
Directory _tempHomeWithApproval() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: always-ask
allowedTools: []
''');
  return tempHome;
}

/// Creates a temp HOME with default config (no custom providers, yolo mode).
Directory _tempHome() {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
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
  return tempHome;
}

/// Creates a temp HOME whose endpoint URL is given (e.g. a test HTTP server
/// on loopback).
Directory _tempHomeWithEndpoint(String baseUrl) {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: $baseUrl
mode: code
approvalMode: yolo
allowedTools: []
''');
  return tempHome;
}

/// A canned OpenAI-SSE endpoint for visual tests: with [answer] it always
/// replies with that text; without it (steer mode) the first user message
/// gets a `sleep 300` bash tool call and every later request a text answer.
const _answerServerPy = r'''
import http.server, json, sys

args = sys.argv[1:]
ANSWER = args[0] if len(args) > 1 else ''
PORT = int(args[-1])

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        if ANSWER:
            deltas = [
                {'choices': [{'delta': {'content': ANSWER}}]},
                {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
            ]
        else:
            messages = json.loads(raw).get('messages', [])
            last_user = ''
            for m in reversed(messages):
                if m.get('role') == 'user':
                    c = m.get('content')
                    last_user = c if isinstance(c, str) else json.dumps(c)
                    break
            if 'run the long task' in last_user:
                deltas = [
                    {'choices': [{'delta': {'tool_calls': [
                        {'index': 0, 'id': 'call_1', 'function': {
                            'name': 'bash',
                            'arguments': '{"command":"sleep 300"}'}}]}}]},
                    {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]},
                ]
            elif ('deploy the app' in last_user
                    and not any(m.get('role') == 'tool' for m in messages)):
                # request_secret once: the follow-up request carries the
                # tool result (role 'tool') and must get a text answer,
                # not the same tool call again.
                deltas = [
                    {'choices': [{'delta': {'tool_calls': [
                        {'index': 0, 'id': 'call_1', 'function': {
                            'name': 'request_secret',
                            'arguments': json.dumps({
                                'name': 'SUDO_PASSWORD',
                                'reason': 'deploy Fa.app to /Applications'})}}]}}]},
                    {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]},
                ]
            elif 'deploy the app' in last_user:
                deltas = [
                    {'choices': [{'delta': {'content':
                        'Secret received — deploying now.'}}]},
                    {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
                ]
            else:
                deltas = [
                    {'choices': [{'delta': {'content':
                        'Working on it — the long task keeps running as a '
                        'background job.'}}]},
                    {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
                ]
        body = ''.join('data: %s\n\n' % json.dumps(c) for c in deltas)
        body += 'data: [DONE]\n\n'
        encoded = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *a):
        pass

http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
''';

/// Starts the canned-answer server on [port] and waits until it accepts
/// connections. Process I/O runs in the real-async zone (see the harness
/// docs on fake-zone timers).
Future<Process> _startAnsweringServer(
  WidgetTester tester,
  int port,
  String? answer,
) async {
  final script = File('${Directory.systemTemp.path}/fa_answer_server_$port.py')
    ..writeAsStringSync(_answerServerPy);
  final server = (await tester.runAsync(
    () => Process.start('python3', [script.path, ?answer, '$port']),
  ))!;
  final up = await tester.runAsync(() async {
    for (var i = 0; i < 50; i++) {
      try {
        final socket = await Socket.connect('127.0.0.1', port);
        await socket.close();
        return true;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return false;
  });
  if (up != true) throw StateError('answer server did not start on $port');
  return server;
}

/// Stops the canned-answer server (best-effort).
Future<void> _stopServer(WidgetTester tester, Process server) async {
  await tester.runAsync(() async {
    server.kill();
    await server.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  });
}
