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

  testWidgets('agent edits a file with the edit tool', (tester) async {
    final env = await createPlatformEnv();

    // Seed a source file in the sandbox.
    await env.exec(
      "mkdir -p /edit_demo && "
      "echo 'void main() { print(\"hello\"); }' > /edit_demo/main.dart",
    );

    AssistantMessageEventStream fakeLlm(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      final stream = AssistantMessageEventStream();
      final last = context.messages.lastOrNull;
      if (last is ToolResultMessage) {
        final message = AssistantMessage(
          content: const [
            TextContent(text: 'Replaced the greeting with "world".'),
          ],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        );
        stream.push(DoneEvent(reason: StopReason.stop, message: message));
      } else {
        final message = AssistantMessage(
          content: [
            ToolCall(
              id: 'tc-edit-1',
              name: 'edit',
              arguments: const {
                'path': '/edit_demo/main.dart',
                'oldText': 'print("hello");',
                'newText': 'print("world");',
              },
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

    await service.sendText('change hello to world');
    await service.waitForIdle();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // The tool executed and reported the edit.
    expect(
      service.messages.any(
        (m) => m.role == 'tool' && m.content.contains('Edited'),
      ),
      isTrue,
      reason: 'the edit tool should report a successful edit',
    );

    // The file actually changed.
    final cat = await env.exec('cat /edit_demo/main.dart');
    expect(cat.valueOrNull?.stdout, contains('print("world");'));

    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'edit_tool_invoked',
    );
  });
}
