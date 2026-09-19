// TUI theme readability, end to end (gh-671): the real CLI runs on a PTY
// against a scripted OpenAI-compatible mock through several SCENARIOS —
// a successful bash call, a failing bash call, a mid-session theme switch
// and the /theme picker — and the raw stream is checked for the
// accessibility contract: every run of text painted over a theme tint
// (toolSuccessBg / toolErrorBg) carries an explicit foreground escape.
// The gh-671 screenshot bug was exactly that violation on ohmypi-light:
// failed-row detail rendered in the terminal default fg over a LIGHT tint
// band — invisible.
//
// The deterministic unit counterparts live in test/cli/tui_theme_test.dart
// (contrast floors per built-in) and test/cli/goldens/tui_theme_*.ans.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/src/bubbles/style.dart' show Style;
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('theme readability scenarios (gh-671)', () {
    for (final theme in const ['dracula', 'nord', 'ohmypi-light']) {
      test(
        '$theme: success + failure rows keep explicit fg over tints',
        () async {
          final mock = _ScriptedMockServer();
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

          // Scenario 1: mid-session theme switch (E1 — the switch repaints
          // the live session; every LATER row uses the new palette).
          await harness.runSlashCommand('/theme $theme');
          await harness.waitForText(
            'theme: $theme',
            timeout: const Duration(seconds: 15),
          );

          // Scenario 2+3: one turn, two tool calls — the first succeeds, the
          // second fails (exit 7) — then the closing text answer.
          harness.sendText('run the theme scenarios');
          harness.sendEnter();
          await harness.waitForText(
            'scenario-complete',
            timeout: const Duration(seconds: 60),
          );

          final t = kBuiltInTuiThemes[theme]!;
          String bg(Style style) {
            final c = style.backgroundRgb!;
            return '48;2;${c.r};${c.g};${c.b}';
          }

          // The tool rows really painted both tints in this palette. Poll
          // the cumulative stream instead of asserting post-hoc: the mock
          // delay above guarantees the settled frames are emitted, and the
          // poll turns a never-painted frame into a clear timeout with the
          // raw tail rather than a bare contains miss (de-flake, review).
          await harness.waitForText(
            bg(t.toolSuccessBg),
            timeout: const Duration(seconds: 30),
          );
          await harness.waitForText(
            bg(t.toolErrorBg),
            timeout: const Duration(seconds: 30),
          );

          final raw = harness.rawOutput;

          // THE accessibility contract: no run of visible text painted over
          // a theme tint may render without an explicit fg escape active.
          // The vendor emits fg BEFORE bg inside one SGR prefix run and SGR
          // state persists across cursor moves, so this is a small state
          // machine over the raw stream, not a line regex. A run whose
          // content is only █ blocks / spaces is the theme-table swatch (a
          // color sample, not text) and is allowed.
          void assertNoUnstyledRun(Style tint, String role) {
            final c = tint.backgroundRgb!;
            final bg = '\x1b[48;2;${c.r};${c.g};${c.b}m';
            final escape = RegExp(r'\x1b\[[0-9;]*m|\x1b\[[0-9;?]*[A-Za-z]');
            var hasBg = false;
            var hasFg = false;
            final plain = StringBuffer();
            void flush() {
              final text = plain.toString();
              plain.clear();
              if (!hasBg || hasFg) return;
              final readable = text
                  .replaceAll('█', '')
                  .replaceAll(RegExp(r'\s'), '');
              if (readable.isEmpty) return;
              fail(
                '$theme: $role-tinted run "$text" renders in the terminal '
                'default fg — invisible on light tints (gh-671 screenshot)',
              );
            }

            var pos = 0;
            for (final m in escape.allMatches(raw)) {
              plain.write(raw.substring(pos, m.start));
              pos = m.end;
              final seq = m[0]!;
              if (seq == bg) {
                flush();
                hasBg = true;
              } else if (seq.startsWith('\x1b[38;2;') ||
                  seq.startsWith('\x1b[38;5;')) {
                flush();
                hasFg = true;
              } else if (seq == '\x1b[0m') {
                flush();
                hasBg = false;
                hasFg = false;
              } else {
                flush();
              }
            }
            plain.write(raw.substring(pos));
            flush();
          }

          assertNoUnstyledRun(t.toolSuccessBg, 'toolSuccessBg');
          assertNoUnstyledRun(t.toolErrorBg, 'toolErrorBg');

          // The scripted turn really produced both row states: the mock's
          // third request carries the failure result text.
          expect(
            mock.bodies[2],
            contains('THEME-SCENARIO-FAIL'),
            reason: 'the failing bash call must have run before the answer',
          );
        },
      );
    }

    test(
      'bare /theme opens the picker with the current theme marked',
      () async {
        final mock = _ScriptedMockServer();
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

        await harness.runSlashCommand('/theme');
        await harness.waitForScreen(
          'Select theme',
          timeout: const Duration(seconds: 15),
        );
        final screen = harness.screenText;
        // gh-671: the current theme must be VISIBLE as text — the old picker
        // replaced the current row's swatch with a dim '(current)' string.
        expect(screen, contains('✓ current'));
        // Every row still shows its swatch preview.
        expect(screen, contains('█'));
        // The picker preselects the current theme (cursor on `default`).
        expect(
          RegExp(r'▸\s*default').hasMatch(screen),
          isTrue,
          reason: 'the picker must open with the cursor on the current theme',
        );

        // Esc dismisses without switching; nothing confirms a switch.
        harness.sendEscape();
        await harness.waitForOutput(settleMs: 300);
        expect(
          harness.rawOutput.contains('theme: '),
          isFalse,
          reason: 'Esc must close the picker without switching the theme',
        );

        await harness.runSlashCommand('/exit');
        await harness.waitForOutput();
      },
    );
  });
}

/// A temp HOME pointing the provider at the local mock server. Yolo
/// approval mode keeps the scripted tool calls unattended.
Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_theme_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
  return tempHome;
}

/// An OpenAI-compatible SSE mock with a scripted response queue:
/// request 1 → bash `echo THEME-SCENARIO-OK`, request 2 → bash
/// `echo THEME-SCENARIO-FAIL >&2; exit 7`, every later request → the
/// plain text answer.
final class _ScriptedMockServer {
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
      final List<String> chunks;
      if (n == 0) {
        chunks = _toolCallChunks('call_ok', 'echo THEME-SCENARIO-OK');
      } else if (n == 1) {
        chunks = _toolCallChunks(
          'call_fail',
          "echo THEME-SCENARIO-FAIL >&2; exit 7",
        );
      } else {
        chunks = _textChunks();
      }
      if (n >= 1) {
        // De-flake (PR review, 2 rounds): with a localhost mock and instant
        // `echo` commands, tool call N settles and tool call N+1 starts
        // within one frame interval, so the TUI can legally coalesce away
        // the frame where the settled row wears its tint. Delaying each
        // later response guarantees the settled done/failed frame is
        // emitted while the TUI idles waiting for the model.
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
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

  static List<String> _toolCallChunks(String id, String command) => [
    jsonEncode({
      'id': 'chatcmpl-t',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'tool_calls': [
              {
                'index': 0,
                'id': id,
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
                'function': {
                  'arguments': jsonEncode({'command': command}),
                },
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
      'id': 'chatcmpl-text',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'scenario-complete'},
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
