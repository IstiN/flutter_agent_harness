@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('Fa CLI integration', () {
    test('boot shows banner and status line', () async {
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();
      final screen = harness.screenText;
      expect(screen, contains('[Context]'));
      expect(screen, contains('[Model]'));
      expect(screen, contains('test-model'));
      // The TUI status line (the input zone has no `fa>` prefix in TUI mode).
      expect(screen, contains('ctx'));
    });

    test(
      '/settings > provider shows Edit/Delete picker for saved provider',
      () async {
        final tempHome = _tempHomeWithProvider();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        // /settings opens the settings hub; the first entry is "Provider".
        await harness.runSlashCommand('/settings');
        await harness.waitForText(
          'Provider',
          timeout: const Duration(seconds: 20),
        );
        harness.sendEnter();
        // The provider picker lists saved providers first.
        await harness.waitForText(
          'test-provider',
          timeout: const Duration(seconds: 20),
        );
        harness.sendEnter();

        // Selecting the saved provider opens its Edit/Delete picker.
        await harness.waitForText(
          'Edit provider',
          timeout: const Duration(seconds: 20),
        );
        final screen = harness.screenText;
        expect(screen, contains('Edit provider'));
        expect(screen, contains('Delete provider'));

        // Leave the picker (Esc reports the cancellation to the wizard).
        harness.sendEscape();
        await harness.waitForOutput();
      },
    );

    test(
      '/settings > provider delete removes provider with confirmation',
      () async {
        final tempHome = _tempHomeWithProvider();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        await harness.runSlashCommand('/settings');
        await harness.waitForText(
          'Provider',
          timeout: const Duration(seconds: 20),
        );
        harness.sendEnter();
        await harness.waitForText(
          'test-provider',
          timeout: const Duration(seconds: 20),
        );
        harness.sendEnter();
        await harness.waitForText(
          'Edit provider',
          timeout: const Duration(seconds: 20),
        );

        // TUI picker: arrows navigate, Enter selects. 'delete' is item 2.
        harness.sendArrowDown();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        harness.sendEnter();
        await harness.waitForText(
          'Yes, delete',
          timeout: const Duration(seconds: 20),
        );

        // The confirmation picker starts on 'Yes, delete'.
        harness.sendEnter();
        await harness.waitForText(
          'deleted provider test-provider',
          timeout: const Duration(seconds: 20),
        );

        await harness.runSlashCommand('/exit');
        await harness.waitForOutput();
      },
    );

    test('/approval always-ask switches the approval mode', () async {
      final tempHome = _tempHomeWithApproval();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      // Commands with arguments close the slash menu while typing;
      // runSlashCommand's extra Escape is a harmless no-op then.
      await harness.runSlashCommand('/approval always-ask');
      await harness.waitForText(
        'approval mode set to always-ask',
        timeout: const Duration(seconds: 20),
      );
    });

    test(
      'shift+enter inserts a newline (kitty + modifyOtherKeys wires)',
      () async {
        // Shift+Enter reached the CLI three ways depending on the terminal:
        // bare CR (macOS CG poll covers that), the kitty CSI-u encoding, and
        // xterm modifyOtherKeys. dart_tui requests the encodings at startup
        // (CSI =1;1u + modifyOtherKeys=2); this test drives the REAL binary
        // over a PTY and asserts both wire formats land as a newline.
        final tempHome = _tempHome();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        // The keyboard-enhancement requests went out at startup: this is what
        // makes a supporting terminal actually SEND the disambiguated keys.
        expect(harness.rawOutput, contains('\x1b[=1;1u'));
        expect(harness.rawOutput, contains('\x1b[>4;2m'));

        Future<void> expectNewline(String rawKey) async {
          harness.sendText('ab');
          await harness.waitForOutput(settleMs: 200);
          harness.sendText(rawKey);
          await harness.waitForOutput(settleMs: 300);
          harness.sendText('cd');
          await harness.waitForOutput(settleMs: 300);
          final abRow = harness.viewportLines.indexWhere(
            (l) => l.contains('ab'),
          );
          final cdRow = harness.viewportLines.indexWhere(
            (l) => l.contains('cd'),
          );
          expect(
            abRow,
            greaterThanOrEqualTo(0),
            reason: 'input prefix lost on screen for $rawKey',
          );
          expect(
            cdRow,
            greaterThan(abRow),
            reason:
                '"cd" must land on a row BELOW "ab" (newline inserted), '
                'got rows ab=$abRow cd=$cdRow for $rawKey',
          );
          expect(
            harness.screenText.contains('abcd'),
            isFalse,
            reason: 'shift+enter submitted instead of newline for $rawKey',
          );
          // Reset the input for the next variant: backspace over 'cd', then
          // over the newline and 'ab'.
          for (var i = 0; i < 6; i++) {
            harness.sendBackspace();
          }
          await harness.waitForOutput(settleMs: 150);
        }

        // kitty keyboard protocol: CSI 13;2 u (Enter + shift modifier).
        await expectNewline('\x1b[13;2u');
        // xterm modifyOtherKeys: CSI 27;2;13 ~ (shift+enter as a ~-key).
        await expectNewline('\x1b[27;2;13~');
        // Legacy ESC CR encoding (terminals without protocol support, e.g.
        // Warp's passthrough) — decoded as alt+enter.
        await expectNewline('\x1b\r');
      },
    );

    test('prompt zone frame is aligned (regression)', () async {
      final tempHome = _tempHome();
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });
      await harness.waitForBoot();

      // `/provider custom` opens the guided wizard: an 'api type' picker,
      // then the base-URL TextPromptSpec that renders the framed prompt zone.
      await harness.runSlashCommand('/provider custom');
      await harness.waitForText(
        'api type',
        timeout: const Duration(seconds: 20),
      );

      // Accept the first api type; the base-URL text prompt appears.
      harness.sendEnter();
      await harness.waitForText(
        'base URL',
        timeout: const Duration(seconds: 20),
      );
      await harness.waitForOutput(settleMs: 300);

      // Find border rows (┌, ├, │, └) and verify they all share one width.
      final borderWidths = <int>{};
      for (final line in harness.viewportLines) {
        final trimmedRight = line.trimRight();
        if (trimmedRight.startsWith('┌') ||
            trimmedRight.startsWith('├') ||
            trimmedRight.startsWith('└')) {
          borderWidths.add(trimmedRight.length);
        }
      }
      expect(borderWidths, isNotEmpty, reason: 'no prompt frame rows found');
      expect(
        borderWidths.length,
        1,
        reason: 'Border rows have different widths: $borderWidths',
      );

      // Cancel the prompt and the wizard.
      harness.sendEscape();
      await harness.waitForOutput();
    });

    test('/model switch is scoped to the launch folder', () async {
      final tempHome = _tempHome();
      final sessionsRoot = Directory.systemTemp.createTempSync('fa_sess_');
      // The CLI resolves its cwd through getcwd(), which canonicalizes the
      // /var → /private/var symlink on macOS; use the resolved paths for
      // spawns and assertions alike.
      final dirA = Directory(
        Directory.systemTemp.createTempSync('fa_folder_a_').path,
      ).resolveSymbolicLinksSync();
      final dirB = Directory(
        Directory.systemTemp.createTempSync('fa_folder_b_').path,
      ).resolveSymbolicLinksSync();
      addTearDown(() async {
        if (sessionsRoot.existsSync()) {
          sessionsRoot.deleteSync(recursive: true);
        }
        if (Directory(dirA).existsSync()) {
          Directory(dirA).deleteSync(recursive: true);
        }
        if (Directory(dirB).existsSync()) {
          Directory(dirB).deleteSync(recursive: true);
        }
      });
      Future<FaCliHarness> spawnIn(String dir) => FaCliHarness.spawn(
        workingDirectory: dir,
        args: ['--session-root', sessionsRoot.path],
        extraEnv: {'HOME': tempHome.path},
      );

      // 1) First launch in folder A: the seed model from config.yaml.
      final h1 = await spawnIn(dirA);
      await h1.waitForBoot();
      expect(h1.screenText, contains('test-model'));
      expect(h1.screenText, isNot(contains('folder-model')));

      await h1.runSlashCommand('/model folder-model');
      await h1.waitForText(
        'switched model to folder-model',
        timeout: const Duration(seconds: 20),
      );
      final stateFileA = File(
        '$sessionsRoot/${encodeSessionCwd(dirA)}/model-state.json',
      );
      // The onModelChanged persistence is fire-and-forget — poll for the
      // file before tearing the process down.
      var saved = false;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!saved && DateTime.now().isBefore(deadline)) {
        saved = stateFileA.existsSync();
        if (!saved) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      // The save rides the awaited onModelChanged chain — eventual by
      // design; the RELAUNCH below is the user-facing guarantee.
      await h1.close();
      // …while the global config keeps its seed model.
      expect(
        File('${tempHome.path}/.fah/config.yaml').readAsStringSync(),
        contains('test-model'),
      );

      final h2 = await spawnIn(dirA);
      await h2.waitForBoot();
      expect(h2.screenText, contains('folder-model'));
      await h2.close();

      //    NOT leak in (the pre-fix bug this test pins).
      final h3 = await spawnIn(dirB);
      await h3.waitForBoot();
      expect(h3.screenText, contains('test-model'));
      expect(h3.screenText, isNot(contains('folder-model')));
      await h3.close();
      tempHome.deleteSync(recursive: true);
    });

    group('approval prompt selector', () {
      test(
        'Cyrillic char becomes a note, 1 approves once through the PTY',
        () async {
          final mock = _MockOpenAiServer();
          await mock.start();
          addTearDown(mock.close);
          final tempHome = _tempHomeForMock(mock.port);
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
        final mock = _MockOpenAiServer();
        await mock.start();
        addTearDown(mock.close);
        final tempHome = _tempHomeForMock(mock.port);
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
        // back down to deny, then confirm with Enter.
        harness.sendArrowUp();
        await harness.waitForText(
          '2. \u25b8 Always approve',
          timeout: const Duration(seconds: 10),
        );
        harness.sendArrowDown();
        await harness.waitForText(
          '3. \u25b8 Deny',
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
  });
}

/// Creates a temp HOME with a minimal keyless config (yolo mode so tests
/// never hit an approval gate).
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

/// Creates a temp HOME with a saved custom provider in the registry.
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

/// Creates a temp HOME pointing the provider at the local mock server with
/// always-ask approval gating.
Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: always-ask
allowedTools: []
''');
  return tempHome;
}

/// A tiny OpenAI-compatible SSE server: the first request answers with a
/// scripted bash tool call, every later one with a plain text answer.
final class _MockOpenAiServer {
  HttpServer? _server;
  final List<String> bodies = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      // The boot-time model-cache refresh must not consume a scripted
      // chat turn.
      if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'object': 'list', 'data': []}));
        await request.response.close();
        return;
      }
      if (request.method != 'POST' ||
          !request.uri.path.endsWith('/chat/completions')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      bodies.add(body);
      final n = bodies.length - 1;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final chunks = n == 0 ? _toolCallChunks() : _textChunks();
      for (final chunk in chunks) {
        // A blank line terminates each SSE event — without it the decoder
        // concatenates every data line into one unreadable payload.
        request.response.write('data: $chunk\n\n');
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  static List<String> _toolCallChunks() => [
    jsonEncode({
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'bash', 'arguments': ''},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': '{"command": "echo ECHO-RAN-123"}'},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
      ],
    }),
  ];

  static List<String> _textChunks() => [
    jsonEncode({
      'id': 'chatcmpl-2',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'turn-complete'},
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
      ],
    }),
  ];
}
