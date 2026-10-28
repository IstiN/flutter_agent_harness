import 'package:flutter_agent_harness/flutter_agent_harness.dart';

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) => AssistantMessage(
  content: content,
  api: 'test-api',
  provider: 'copilot',
  model: 'vision',
  usage: Usage.zero,
  stopReason: stopReason,
  errorMessage: errorMessage,
  timestamp: DateTime.utc(2026),
);

void main() async {
  final contexts = <Context>[];
  StreamFunction fake = (model, context, {cancelToken}) {
    contexts.add(context);
    var imageBytes = 0;
    for (final m in context.messages) {
      final blocks = switch (m) {
        UserMessage(:final content) when content is List<ContentBlock> => content,
        ToolResultMessage(:final content) => content,
        _ => const <ContentBlock>[],
      };
      for (final b in blocks) {
        if (b is ImageContent) imageBytes += b.data.length;
      }
    }
    print('call ${contexts.length}: imageBytes=$imageBytes msgs=${context.messages.length}');
    final stream = AssistantMessageEventStream();
    if (imageBytes > 5 * 1000 * 1000) {
      final msg = _assistant(
        stopReason: StopReason.error,
        errorMessage: 'error: 413: Request Entity Too Large',
      );
      stream
        ..push(StartEvent(partial: msg))
        ..push(ErrorEvent(reason: StopReason.error, error: msg));
    } else {
      final empty = _assistant();
      final partial = _assistant(content: [const TextContent(text: 'done')]);
      stream
        ..push(StartEvent(partial: empty))
        ..push(TextStartEvent(contentIndex: 0, partial: empty))
        ..push(TextDeltaEvent(contentIndex: 0, delta: 'done', partial: partial))
        ..push(DoneEvent(reason: StopReason.stop, message: partial));
    }
    stream.end();
    return stream;
  };

  final history = <Message>[];
  for (var i = 0; i < 8; i++) {
    history.addAll([
      AssistantMessage(
        content: [
          ToolCall(id: 'call$i', name: 'read', arguments: {'path': '/tmp/i.png'}),
        ],
        api: 'test-api',
        provider: 'copilot',
        model: 'vision',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, i * 1000),
      ),
      ToolResultMessage(
        toolCallId: 'call$i',
        toolName: 'read',
        content: [ImageContent(data: 'x' * (3 * 1000 * 1000), mimeType: 'image/png')],
        isError: false,
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, i * 1000 + 500),
      ),
    ]);
  }

  final events = <AgentEvent>[];
  final messages = await runAgentLoop(
    prompts: [UserMessage.text('continue')],
    context: Context(messages: history),
    config: AgentLoopConfig(
      model: Model(
        id: 'vision', api: 'test-api', provider: 'copilot',
        baseUrl: 'https://example.test', input: const ['text', 'image'],
        contextWindow: 100000, maxTokens: 4096,
      ),
      imageRecovery: ImagePayloadRecoveryState(),
    ),
    streamFunction: fake,
    toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
    emit: events.add,
  );
  print('calls: ${contexts.length}');
  for (final e in events) {
    if (e is ImagePayloadRecoveryEvent) print('recovery event: pass=${e.pass} dropped=${e.dropped} stripped=${e.stripped} failed=${e.failed}');
  }
  final last = messages.whereType<AssistantMessage>().last;
  print('final stop=${last.stopReason} err=${last.errorMessage}');
}
