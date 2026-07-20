import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_example/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('agent invokes bash tool and renders result', (tester) async {
    final env = await createPlatformEnv();

    AssistantMessageEventStream fakeLlm(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      final stream = AssistantMessageEventStream();
      final last = context.messages.lastOrNull;
      if (last is ToolResultMessage) {
        // Second turn: tool result has been delivered, emit final summary.
        final message = AssistantMessage(
          content: const [TextContent(text: 'Done.')],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        );
        stream.push(DoneEvent(reason: StopReason.stop, message: message));
      } else {
        // First turn: respond with a bash tool call.
        final message = AssistantMessage(
          content: [
            ToolCall(
              id: 'tc-1',
              name: 'bash',
              arguments: const {'command': 'echo hello from wasm bash'},
            ),
          ],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        );
        stream.push(DoneEvent(reason: StopReason.stop, message: message));
      }
      stream.end();
      return stream;
    }

    final agent = Agent(
      model: Model(
        id: 'fake-model',
        api: 'fake-api',
        provider: 'fake',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are fah.',
      streamFunction: fakeLlm,
      toolRegistry: ToolRegistry(builtinTools(env)),
    );

    final service = AgentService(
      agent: agent,
      env: env,
      sessionsRoot: '${env.cwd}/sessions',
    );
    await service.initialize();

    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '${env.cwd}/sessions',
    )..addSession('test-session', service);
    await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
    await tester.pumpAndSettle();

    await service.sendText('run a bash echo command');

    // Wait for the tool loop to finish.
    await service.waitForIdle();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Debug: print all transcript messages.
    for (final m in service.messages) {
      debugPrint('MESSAGE role=${m.role} content=${m.content}');
    }

    // Verify the transcript contains a tool execution and its stdout.
    expect(
      service.messages.any(
        (m) => m.role == 'tool' && m.content.contains('hello from wasm bash'),
      ),
      isTrue,
      reason: 'bash tool should have produced "hello from wasm bash"',
    );

    // Screenshot for the human reviewer.
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'bash_tool_invoked',
    );
  });
}
