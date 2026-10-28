import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  final boundary = '$compactionSummaryPrefix'
      'Old work.$compactionSummarySuffix';
  print('starts with prefix: ${boundary.startsWith(compactionSummaryPrefix)}');
  final window = [
    UserMessage.text(boundary),
    ToolResultMessage(
      toolCallId: 't0',
      toolName: 'read',
      content: [ImageContent(data: 'x' * 3000, mimeType: 'image/png')],
      isError: false,
      timestamp: DateTime.utc(2026),
    ),
    UserMessage.text('continue'),
  ];
  final out = rewriteHistoryImages(window);
  for (final m in out) {
    print('--- ${m.runtimeType}');
    final blocks = switch (m) {
      UserMessage(:final content) when content is List<ContentBlock> => content,
      UserMessage(:final content) => [TextContent(text: content as String)],
      ToolResultMessage(:final content) => content,
      _ => <ContentBlock>[],
    };
    for (final b in blocks) {
      print('   ${b.runtimeType}: '
          '${b is TextContent ? (b.text.length > 80 ? '${b.text.substring(0, 80)}...' : b.text) : b is ImageContent ? 'IMAGE ${b.data.length}' : ''}');
    }
  }
}
