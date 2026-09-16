/// Golden (screenshot) tests for the chat composer's multiline states
/// (`lib/ui/widgets/chat_composer.dart`, issue #463): the field at 1, 3
/// and the 6-line capped height, light + dark, mobile width.
///
/// The composer is snapshotted inside the full [ChatScreen] frame (the
/// marketing-grade pattern of `chat_golden_test.dart`): text is injected
/// through the IME channel, then the field is unfocused so the cursor's
/// wall-clock-dependent blink phase never leaks into the snapshot.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

AgentService _fakeService(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream()
          ..end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    ),
    watchExternalSessions: false,
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    // Icon fonts are not registered from the test asset bundle — without
    // this every Icon renders as a placeholder square.
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<void> pumpComposerState(
    WidgetTester tester, {
    required int lines,
    required bool light,
  }) async {
    final manager = FlutterSessionManager(
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    )..addSession('fake-session', _fakeService(MemoryExecutionEnv()));
    await pumpGolden(
      tester,
      ChatScreen(manager: manager),
      size: goldenSizePhone,
      theme: light ? buildFahThemeLight() : null,
      wrap: (child) => child,
    );
    final text = List.generate(lines, (i) => 'composer line ${i + 1}').join(
      '\n',
    );
    await tester.enterText(find.byType(TextField), text);
    // The mic↔send swap runs through an AnimatedSwitcher; settle it.
    await tester.pumpAndSettle();
    // Determinism: unfocus so the snapshot never catches a random cursor
    // blink phase, then wait out the cursor's fade-out animation (the
    // chat_generated_image pattern).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  testWidgets('composer 1-line — dark', (tester) async {
    await pumpComposerState(tester, lines: 1, light: false);
    await expectGolden(tester, 'composer_multiline_1line');
  });

  testWidgets('composer 3-line — dark', (tester) async {
    await pumpComposerState(tester, lines: 3, light: false);
    await expectGolden(tester, 'composer_multiline_3line');
  });

  testWidgets('composer 6-line-capped — dark', (tester) async {
    // 8 lines: the field is visibly capped at the 6-line budget and
    // scrolls internally.
    await pumpComposerState(tester, lines: 8, light: false);
    await expectGolden(tester, 'composer_multiline_6line');
  });

  testWidgets('composer 1-line — light', (tester) async {
    await pumpComposerState(tester, lines: 1, light: true);
    await expectGolden(tester, 'composer_multiline_1line_light');
  });

  testWidgets('composer 3-line — light', (tester) async {
    await pumpComposerState(tester, lines: 3, light: true);
    await expectGolden(tester, 'composer_multiline_3line_light');
  });

  testWidgets('composer 6-line-capped — light', (tester) async {
    await pumpComposerState(tester, lines: 8, light: true);
    await expectGolden(tester, 'composer_multiline_6line_light');
  });
}
