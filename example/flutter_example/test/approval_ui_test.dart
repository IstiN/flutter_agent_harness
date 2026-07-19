import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/approval_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Pumps a button that opens the approval dialog and completes [result].
Future<void> _pumpOpener(
  WidgetTester tester, {
  required void Function(ApprovalDecision) onDecision,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              onDecision(await showApprovalPrompt(context, _request));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ApprovalDialog', () {
    testWidgets('renders the reason, tier, and arguments', (tester) async {
      await _pumpOpener(tester, onDecision: (_) {});
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Allow bash?'), findsOneWidget);
      expect(
        find.text(
          'Critical pattern detected: recursive delete from a root '
          'path',
        ),
        findsOneWidget,
      );
      expect(find.text('Tier: exec'), findsOneWidget);
      expect(find.textContaining('rm -rf /'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
      expect(find.text('Allow once'), findsOneWidget);
      expect(find.text('Always allow'), findsOneWidget);
    });

    testWidgets('"Allow once" resolves approveOnce', (tester) async {
      ApprovalDecision? result;
      await _pumpOpener(tester, onDecision: (d) => result = d);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(result, ApprovalDecision.approveOnce);
    });

    testWidgets('"Always allow" resolves approveAlways', (tester) async {
      ApprovalDecision? result;
      await _pumpOpener(tester, onDecision: (d) => result = d);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Always allow'));
      await tester.pumpAndSettle();
      expect(result, ApprovalDecision.approveAlways);
    });

    testWidgets('"Deny" resolves deny', (tester) async {
      ApprovalDecision? result;
      await _pumpOpener(tester, onDecision: (d) => result = d);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(result, ApprovalDecision.deny);
    });

    testWidgets('dismissing the dialog resolves deny (safe default)', (
      tester,
    ) async {
      ApprovalDecision? result;
      await _pumpOpener(tester, onDecision: (d) => result = d);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Tap the barrier (outside the dialog).
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(result, ApprovalDecision.deny);
    });
  });

  group('AgentService approval gate', () {
    test(
      'defaults to write mode and denies prompts without a handler',
      () async {
        final service = _service();
        expect(service.approval.mode, ApprovalMode.write);

        final readOutcome = await service.approval.authorize(
          toolName: 'read',
          tier: ApprovalTier.read,
          arguments: const {},
        );
        expect(readOutcome.allowed, isTrue);

        // No approvalPromptHandler installed: prompt-policy calls deny.
        final bashOutcome = await service.approval.authorize(
          toolName: 'bash',
          tier: ApprovalTier.exec,
          arguments: const {'command': 'ls'},
        );
        expect(bashOutcome.allowed, isFalse);
        expect(bashOutcome.reason, contains('user denied'));
      },
    );

    test('an installed handler receives the request', () async {
      final service = _service();
      final seen = <ApprovalRequest>[];
      service.approvalPromptHandler = (request) {
        seen.add(request);
        return ApprovalDecision.approveOnce;
      };
      final outcome = await service.approval.authorize(
        toolName: 'write',
        tier: ApprovalTier.write,
        arguments: const {'path': 'a'},
      );
      expect(outcome.allowed, isTrue);
      expect(seen.single.toolName, 'write');
    });
  });

  group('ApprovalModeSelector', () {
    testWidgets('shows the active mode and switches it', (tester) async {
      final service = _service();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ApprovalModeSelector(service: service)),
        ),
      );

      // Default: write mode selected.
      expect(find.text('Tool approvals'), findsOneWidget);
      expect(service.approval.mode, ApprovalMode.write);

      await tester.tap(find.text('YOLO'));
      await tester.pumpAndSettle();
      expect(service.approval.mode, ApprovalMode.yolo);

      await tester.tap(find.text('Always ask'));
      await tester.pumpAndSettle();
      expect(service.approval.mode, ApprovalMode.alwaysAsk);
    });
  });
}
