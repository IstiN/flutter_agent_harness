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
    if (_isBlankCompletion(message, text, hasToolCalls)) {
      text = _blankCompletionText(text);
    }
    _applyAssistantRow(message, text, hasToolCalls);
    _applyThinkingRow(thinking);
    _reportStopFailure(message);
    _notify();
  }

  /// A completed turn with neither text nor tool calls (small on-device
  /// models do this) — the blank-bubble candidate.
  bool _isBlankCompletion(
    AssistantMessage message,
    String text,
    bool hasToolCalls,
  ) {
    return text.trim().isEmpty &&
        !hasToolCalls &&
        message.stopReason != StopReason.error &&
        message.stopReason != StopReason.aborted;
  }

  /// The text rendered for a blank completion: the placeholder, or — an
  /// empty completion right after an image-bearing prompt usually means
  /// the model silently ignored/rejected image input — the say-so hint
  /// instead of a bare retry suggestion. UserMessage.content is Object:
  /// a plain String or a block list.
  String _blankCompletionText(String text) {
    final lastUserContent = _agent.state.messages.reversed
        .whereType<UserMessage>()
        .firstOrNull
        ?.content;
    final lastUserBlocks = switch (lastUserContent) {
      final List blocks => blocks,
      _ => const <Object>[],
    };
    final hadImage = lastUserBlocks.any((b) => b is ImageContent);
    if (!hadImage) return emptyResponsePlaceholder;
    return '$emptyResponsePlaceholder\n\nThe model returned nothing for a message with '
        'an image attachment - it likely does not support image input. '
        'Try a vision-capable model or resend without the attachment.';
  }

  /// The assistant transcript row (issue #692 F — content-or-error
  /// invariant: an assistant row with no visible content and no error
  /// state must be structurally impossible. Tool-call-only rounds (the
  /// row would be an invisible bubble between tool tiles) and
  /// error/aborted stops (the error tile below IS the visible answer) add
  /// NO assistant row at all), updating the streamed row when present.
  void _applyAssistantRow(
    AssistantMessage message,
    String text,
    bool hasToolCalls,
  ) {
    final target = _currentAssistantMessage;
    if (target == null) {
      if (!_skipAssistantRow(text, hasToolCalls, message)) {
        messages.add(FahChatMessage(role: 'assistant', content: text));
      }
    } else if (text.trim().isNotEmpty) {
      target.content = text;
    } else if (target.content.trim().isEmpty) {
      // Defensive: a streamed-but-empty target (empty deltas, aborted
      // run) must not linger as an invisible bubble either.
      messages.remove(target);
    }
    _currentAssistantMessage = null;
  }

  /// Whether a null-target completion adds NO assistant row.
  bool _skipAssistantRow(
    String text,
    bool hasToolCalls,
    AssistantMessage message,
  ) {
    return text.trim().isEmpty &&
        (hasToolCalls ||
            message.stopReason == StopReason.error ||
            message.stopReason == StopReason.aborted);
  }

  /// The thinking transcript row: appended when new, else folded into the
  /// streamed thinking row (an empty tail keeps the streamed content).
  void _applyThinkingRow(String thinking) {
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
  }

  /// Error/aborted stops surface visibly: a failed run is a VISIBLE error
  /// tile in the transcript (the shared renderer styles it), not just the
  /// banner field — otherwise a dead key silently looks like "no answer".
  void _reportStopFailure(AssistantMessage message) {
    if (message.stopReason == StopReason.error) {
      // Issue #867: a structured 429 renders the localized human message
      // (plan, server-derived countdown, next step); the raw payload stays
      // on the info and never reaches the bubble.
      final text = _stopFailureText(message);
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
  }

  /// The visible failure text: the localized rate-limit message for a
  /// structured 429, else the raw error (or a generic fallback).
  String _stopFailureText(AssistantMessage message) {
    final info = message.rateLimit;
    return info != null
        ? formatRateLimitMessage(
            info,
            // The app's locale decision, not the bare platform value —
            // empty device locales and overrides resolve like everywhere
            // else (issue #867 thread).
            localeCode: resolveAppLocale(
              WidgetsBinding.instance.platformDispatcher.locale,
            ).languageCode,
          )
        : message.errorMessage ?? 'Run failed (${StopReason.error.name})';
  }
}
