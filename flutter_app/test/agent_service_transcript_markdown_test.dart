import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Agent _agent() {
  return Agent(
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
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(const []),
    emptyHiccupBaseDelay: Duration.zero,
  );
}

void main() {
  test('transcriptMarkdown renders every role and attachment shape', () {
    final service = AgentService(
      agent: _agent(),
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
    addTearDown(service.dispose);
    expect(service.transcriptMarkdown(), isEmpty);

    service.messages.addAll([
      FahChatMessage(
        role: 'user',
        content: 'look at these',
        attachments: [
          (bytes: Uint8List.fromList(const [1, 2, 3]), path: 'diagram.png'),
          (bytes: null, path: '/tmp/notes.txt'),
          (bytes: Uint8List.fromList(const [4]), path: null),
        ],
      ),
      FahChatMessage(role: 'assistant', content: ''),
      FahChatMessage(role: 'tool', toolName: 'bash', content: 'done'),
      FahChatMessage(role: 'tool', content: ''),
      FahChatMessage(role: 'systemNotice', content: 'saved'),
    ]);

    expect(service.transcriptMarkdown(), '''
## You
[image attached ×2]
[attached file: /tmp/notes.txt]
look at these

## Fa

## tool (bash)
done

## tool (call)

## systemNotice
saved

''');
  });
}
