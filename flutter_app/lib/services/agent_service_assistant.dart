// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the assistant-run finalization member of
// [AgentService] lives here so the main file stays under the 2800-line
// guard. Same library, so private members resolve.

part of 'agent_service.dart';

extension AgentServiceAssistant on AgentService {
  void _finalizeAssistant(AssistantMessage message) {
    debugPrint(
      '[Fa] finalizeAssistant: stopReason=${message.stopReason}, '
      'contentBlocks=${message.content.length}, '
      'errorMessage=${message.errorMessage}',
    );
    var text = message.content
        .whereType<TextContent>()
        .map((b) => b.text)
        .join();
    final thinking = message.content
        .whereType<ThinkingContent>()
        .map((b) => b.thinking)
        .join();
    final hasToolCalls = message.content.any((block) => block is ToolCall);
    if (text.trim().isEmpty &&
        !hasToolCalls &&
        message.stopReason != StopReason.error &&
        message.stopReason != StopReason.aborted) {
      // A completed turn with neither text nor tool calls (small on-device
      // models do this) must not render as a blank bubble.
      text = emptyResponsePlaceholder;
      // An empty completion right after an image-bearing prompt usually
      // means the model silently ignored/rejected image input - say so
      // instead of a bare retry suggestion.
      // UserMessage.content is Object: a plain String or a block list.
      final lastUserContent = _agent.state.messages.reversed
          .whereType<UserMessage>()
          .firstOrNull
          ?.content;
      final lastUserBlocks = switch (lastUserContent) {
        final List blocks => blocks,
        _ => const <Object>[],
      };
      final hadImage = lastUserBlocks.any((b) => b is ImageContent);
      if (hadImage) {
        text =
            '$text\n\nThe model returned nothing for a message with '
            'an image attachment - it likely does not support image input. '
            'Try a vision-capable model or resend without the attachment.';
      }
    }
    final target = _currentAssistantMessage;
    if (target == null) {
      messages.add(FahChatMessage(role: 'assistant', content: text));
    } else {
      target.content = text;
    }
    _currentAssistantMessage = null;
    final thinkingTarget = _currentThinkingMessage;
    if (thinkingTarget == null) {
      if (thinking.isNotEmpty) {
        messages.add(FahChatMessage(role: 'thinking', content: thinking));
      }
    } else {
      thinkingTarget.content = thinking.isNotEmpty
          ? thinking
          : thinkingTarget.content;
    }
    _currentThinkingMessage = null;
    if (message.stopReason == StopReason.error) {
      // A failed run must be VISIBLE: an error tile in the transcript
      // (the shared renderer styles it), not just the banner field —
      // otherwise a dead key silently looks like "no answer".
      final text =
          message.errorMessage ?? 'Run failed (${StopReason.error.name})';
      error = text;
      messages.add(
        FahChatMessage(
          role: 'tool',
          content: text,
          toolName: 'error',
          isError: true,
        ),
      );
    } else if (message.stopReason == StopReason.aborted) {
      error = message.errorMessage ?? 'Run aborted';
    }
    _notify();
  }
}
