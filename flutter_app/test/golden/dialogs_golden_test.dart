/// Golden (screenshot) tests for the modal dialog surfaces:
/// `lib/approval_ui.dart` (approval dialog + mode selector) and
/// `lib/ask_ui.dart` (ask sheet). Fakes/builders mirror
/// `test/approval_ui_test.dart` and `test/ask_ui_test.dart`.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa/ui/widgets/ask_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

const _request = ApprovalRequest(
  toolName: 'bash',
  tier: ApprovalTier.exec,
  arguments: {'command': 'rm -rf /'},
  reason: 'Critical pattern detected: recursive delete from a root path',
);

AgentService _service() {
  final agent = Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.push(
        DoneEvent(
          reason: StopReason.stop,
          message: AssistantMessage(
            content: const [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          ),
        ),
      );
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(builtinTools(MemoryExecutionEnv())),
  );
  return AgentService(
    agent: agent,
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

const _singleQuestion = AskQuestion(
  question: 'Which auth method?',
  options: [
    AskOption(label: 'JWT', description: 'Bearer tokens for stateless APIs.'),
    AskOption(label: 'OAuth2'),
    AskOption(label: 'Session cookies'),
  ],
  recommended: 0,
);

const _multiQuestion = AskQuestion(
  question: 'Which features?',
  options: [
    AskOption(label: 'Alpha'),
    AskOption(label: 'Beta'),
    AskOption(label: 'Gamma'),
  ],
  multiSelect: true,
);

/// Pumps the themed host with an `open` button, then opens the dialog/sheet
/// the button triggers and settles the entry animation.
Future<void> _pumpOpened(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  await pumpGolden(
    tester,
    Builder(
      builder: (context) => ElevatedButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('dialogs goldens', () {
    testWidgets('approval dialog: bash tool, tier line, three buttons', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showApprovalPrompt(context, _request),
      );
      await expectGolden(tester, 'dialogs_approval');
    });

    testWidgets('approval mode selector: default write mode', (tester) async {
      final service = _service();
      addTearDown(service.dispose);
      await pumpGolden(
        tester,
        Padding(
          padding: const EdgeInsets.all(24),
          child: ApprovalModeSelector(service: service),
        ),
      );
      await expectGolden(tester, 'dialogs_approval_mode');
    });

    testWidgets('ask sheet: labeled options with a recommended one', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showAskSheet(context, [_singleQuestion]),
      );
      await expectGolden(tester, 'dialogs_ask_options');
    });

    testWidgets('ask sheet: multi-select with checked options', (tester) async {
      await _pumpOpened(
        tester,
        (context) => showAskSheet(context, [_multiQuestion]),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gamma'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'dialogs_ask_multi');
    });
  });
}
