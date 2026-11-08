/// Width-sweep goldens for the stacked chat header at
/// 320/400/600/1024pt. Every width keeps the centered avatar above the
/// title pill; the action row adapts by demoting into ⋮ rather than
/// switching to a different compact bar.
///
/// The pump uses the current full-chat route payload (project identity +
/// quick-model chip + trajectory + files drawer), so the snapshots show
/// the real header shape and overflow.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/quick_model_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

// Copied verbatim from chat_golden_test.dart (private there): a service
// that never runs, network, or clock — only renders.
AgentService _fakeService() {
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
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    watchExternalSessions: false,
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
    ),
  );
}

/// Height per sweep width: phone for the tight families, tablet/desktop
/// proportions above.
double _heightFor(double width) =>
    width <= 400 ? 844 : (width <= 600 ? 900 : 768);

Future<void> _pumpHeaderWidth(WidgetTester tester, double width) async {
  final service = _fakeService();
  service.messages
    ..add(
      FahChatMessage(
        role: 'user',
        content:
            'the auth integration test fails after my refactor — can '
            'you take a look?',
      ),
    )
    ..add(
      FahChatMessage(
        role: 'assistant',
        content:
            'Found it — the test still calls the old two-argument '
            '`signIn`. The suite is green again.',
      ),
    );
  final manager = FlutterSessionManager(
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  )..addSession('fake-session', service);
  await pumpGolden(
    tester,
    ChatScreen(
      manager: manager,
      // The current full-chat route payload.
      projectIcon: Icons.folder_outlined,
      projectLabel: 'Personal',
      modelChip: QuickModelChip(
        modelId: service.modelId,
        tooltip: 'Switch model',
        maxWidth: 132,
        onTap: () {},
      ),
      onModelChipTap: () {},
      chipMenuLabel: service.modelId,
    ),
    size: Size(width, _heightFor(width)),
    wrap: (child) => child,
  );
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  group('Adaptive header width sweep (issue #225 AC2)', () {
    for (final width in <double>[320, 400, 600, 1024]) {
      testWidgets('header at $width pt', (tester) async {
        await _pumpHeaderWidth(tester, width);
        final avatar = find.byKey(const ValueKey('faChatHeaderAvatar'));
        final titlePill = find.byKey(const ValueKey('faChatHeaderTitlePill'));
        expect(avatar, findsOneWidget);
        expect(titlePill, findsOneWidget);
        expect(
          tester.getRect(titlePill).top,
          greaterThanOrEqualTo(tester.getRect(avatar).bottom),
          reason: 'never collapse into the one-row compact header',
        );
        await expectGolden(tester, 'chat_header_${width.round()}');
      });
    }
  });
}
