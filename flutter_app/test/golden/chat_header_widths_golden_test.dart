/// Width-sweep goldens for the stacked chat header at
/// 320/400/417/501/600/1024pt. Every width keeps the centered avatar above
/// the title pill; the action row adapts by demoting into ⋮ rather than
/// switching to a different compact bar. The 417/501pt cases cover the
/// compact Duo chat pane, including its inherited landscape inset.
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

const _modelId = 'anthropic/claude-haiku-4.5';
const _duoPaneWidth = 501.0;
const _duoSurfaceSize = Size(_duoPaneWidth, 700);
const _duoInheritedPadding = EdgeInsets.only(right: 84);
const _avatarKey = ValueKey('faChatHeaderAvatar');
const _titlePillKey = ValueKey('faChatHeaderTitlePill');

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
AgentService _fakeService({String modelId = 'test-model'}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: modelId,
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
      providerKind: 'openrouter',
      modelId: modelId,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
    ),
  );
}

/// Height per sweep width: phone for the tight families, tablet/desktop
/// proportions above.
double _heightFor(double width) =>
    width <= 400 ? 844 : (width <= 600 ? 900 : 768);

Future<void> _pumpHeaderWidth(
  WidgetTester tester,
  double width, {
  String modelId = 'test-model',
  bool duoInsets = false,
}) async {
  final service = _fakeService(modelId: modelId);
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
    MediaQuery(
      data: MediaQueryData(
        padding: duoInsets ? _duoInheritedPadding : EdgeInsets.zero,
      ),
      child: ChatScreen(
        manager: manager,
        sessionTitle: width == _duoPaneWidth ? 'Nov 8 22:14' : null,
        // The current full-chat route payload.
        projectIcon: Icons.folder_outlined,
        projectLabel: width == _duoPaneWidth ? 'fah_sandbox' : 'Personal',
        modelChip: QuickModelChip(
          modelId: service.modelId,
          providerBaseUrl: 'https://openrouter.ai/api/v1',
          tooltip: 'Switch model',
          compact: width <= _duoPaneWidth,
          maxWidth: width <= _duoPaneWidth ? 32 : 132,
          onTap: () {},
        ),
        onModelChipTap: () {},
        chipMenuLabel: service.modelId,
      ),
    ),
    size: duoInsets ? _duoSurfaceSize : Size(width, _heightFor(width)),
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
        if (width >= 600) {
          expect(
            find.byKey(const ValueKey('quickModelChipLabel')),
            findsOneWidget,
          );
        }
        expect(
          tester.getRect(titlePill).top,
          greaterThanOrEqualTo(tester.getRect(avatar).bottom),
          reason: 'never collapse into the one-row compact header',
        );
        await expectGolden(tester, 'chat_header_${width.round()}');
      });
    }
  });

  group('Duo docked chat panes', () {
    for (final width in <double>[417, _duoPaneWidth]) {
      testWidgets('compact header at $width pt', (tester) async {
        await _pumpHeaderWidth(tester, width, modelId: _modelId);
        expect(find.byKey(const ValueKey('wideModelChip')), findsNothing);
        expect(find.byIcon(Icons.memory), findsNothing);
        expect(find.byKey(const ValueKey('faChatFilesAction')), findsOneWidget);
        expect(
          tester.getCenter(find.byKey(_avatarKey)).dx,
          closeTo(width / 2, .001),
        );
        expect(
          tester.getRect(find.byKey(_titlePillKey)).top,
          greaterThanOrEqualTo(tester.getRect(find.byKey(_avatarKey)).bottom),
        );
        expect(find.byKey(const ValueKey('quickModelChipLabel')), findsNothing);
        await expectGolden(tester, 'chat_header_${width.round()}');
      });
    }

    testWidgets('inherited Duo inset does not displace compact actions', (
      tester,
    ) async {
      await _pumpHeaderWidth(
        tester,
        _duoPaneWidth,
        modelId: _modelId,
        duoInsets: true,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('faChatFilesAction'))).right,
        greaterThan(_duoPaneWidth - _duoInheritedPadding.right),
      );
      await expectGolden(tester, 'chat_header_duo_collapsed_insets');
    });
  });
}
