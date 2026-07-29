import '../context.dart';
import '../types.dart';

/// TUI-mode replay entry in the ACTIVE session's format: the user message
/// as the same background echo box the TUI draws at submit time, the
/// assistant text as raw markdown ([AnsiMarkdown] styles it at render
/// time, exactly like a live stream), and the tool calls of a
/// text-bearing message as one dim indicator row. Call-only assistant
/// messages collapse through the pending-runs machinery instead.
List<String> replayLinesTui(
  Message message, {
  required int width,
  required String Function(String) dim,
}) {
  const maxRows = 20;
  switch (message) {
    case UserMessage(:final content):
      final text = content is String
          ? content
          : (content as List<ContentBlock>)
                .whereType<TextContent>()
                .map((b) => b.text)
                .join('\n');
      if (text.trim().isEmpty) return const [];
      const bg = '\x1b[48;2;30;34;42m';
      const reset = '\x1b[0m';
      return [
        dim('─' * width),
        for (final line in text.split('\n')) '$bg$line$reset',
        '',
      ];
    case AssistantMessage(:final content):
      final texts = content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n')
          .trim();
      if (texts.isEmpty) return const [];
      final rows = texts.split('\n');
      final head = rows.take(maxRows).toList();
      if (rows.length > maxRows) head[head.length - 1] = '${head.last} …';
      final calls = content
          .whereType<ToolCall>()
          .map((c) => '[${c.name}]')
          .join(' ');
      return [...head, if (calls.isNotEmpty) dim(calls)];
    default:
      return const [];
  }
}

/// One compact line-mode replay entry (≤ [maxRows] rows), or none for
/// messages the replay skips (tool results — their calls are already
/// shown).
List<String> replayLines(Message message, {required int maxRows}) {
  final String text;
  final String prefix;
  switch (message) {
    case UserMessage(:final content):
      prefix = 'you: ';
      text = content is String
          ? content
          : (content as List<ContentBlock>)
                .whereType<TextContent>()
                .map((b) => b.text)
                .join(' ');
    case AssistantMessage(:final content):
      final texts = content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join(' ')
          .trim();
      final calls = content
          .whereType<ToolCall>()
          .map((c) => '[${c.name}]')
          .join(' ');
      text = [texts, calls].where((s) => s.isNotEmpty).join(' ');
      prefix = 'fa:  ';
    default:
      return const [];
  }
  if (text.trim().isEmpty) return const [];
  final rows = text.split('\n');
  final head = rows.take(maxRows).toList();
  final suffix = rows.length > maxRows ? ' …' : '';
  final indent = ' ' * prefix.length;
  return [
    for (var i = 0; i < head.length; i++)
      '${i == 0 ? prefix : indent}${head[i]}${i == head.length - 1 ? suffix : ''}',
  ];
}
