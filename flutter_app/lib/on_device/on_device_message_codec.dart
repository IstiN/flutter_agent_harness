// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// One shared message walk for the three on-device providers
/// (gemma, transformers.js, WebLLM): a harness [Context] projects onto
/// provider-neutral [OnDeviceMessage] records through an
/// [OnDeviceCodecProfile]; each provider's codec is a tiny adapter mapping
/// the neutral records onto its engine's chat-message type.
///
/// The walk owns the rules all three engines share — skip empty text,
/// join multi-part text with newlines, degrade images with an omission
/// note, render historical tool calls, render tool results with a
/// `(no output)` fallback — and the profile carries the wire quirks:
/// the system message policy (gemma travels its system prompt through a
/// separate `systemInstruction` parameter and emits no system message),
/// the image policy (transformers.js passes decodable `data:` URIs when
/// the preset supports vision; gemma/WebLLM are text-only), and the
/// tool-call/tool-result shapes (gemma emits a separate OpenAI-style
/// `tool_call` message + a `tool_result` role; transformers.js/WebLLM
/// inline `[tool call: …]` lines and a `[tool result]` user header).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Provider-neutral projection of one harness message onto an on-device
/// engine's wire shape. [images] holds `data:` URIs (transformers.js
/// vision); [toolName] travels only on gemma's `tool_result` role.
typedef OnDeviceMessage = ({
  String role,
  String content,
  String? toolName,
  List<String> images,
});

/// The per-provider wire quirks [convertOnDeviceMessages] consults.
final class OnDeviceCodecProfile {
  const OnDeviceCodecProfile({
    required this.systemMessage,
    required this.projectImages,
    required this.toolCallLine,
    required this.extraAssistantMessages,
    required this.toolResultMessage,
  });

  /// The conversation-opening system message, or null when the provider
  /// carries the system prompt elsewhere. [hasTools] tells the no-tools
  /// note apart from the tool-instructions case.
  final OnDeviceMessage? Function(String system, bool hasTools) systemMessage;

  /// Projects user-attached images onto `(dataUris, omissionNote)`; the
  /// walk appends the note to the text parts when set.
  final ({List<String> dataUris, String? omissionNote}) Function(
    List<ImageContent> images,
  )
  projectImages;

  /// The inline `[tool call: …]` text line for a historical tool call, or
  /// null when calls travel as separate messages (gemma).
  final String? Function(ToolCall call) toolCallLine;

  /// Extra messages a historical tool-call turn emits beyond the text
  /// message (gemma's OpenAI-style `tool_call` envelope; empty for the
  /// inline-line providers).
  final List<OnDeviceMessage> Function(List<ToolCall> calls)
  extraAssistantMessages;

  /// The message a tool result becomes. [resultText] is the raw newline
  /// join of the result's text blocks, already collapsed to
  /// [onDeviceNoOutput] when empty.
  final OnDeviceMessage Function(ToolResultMessage result, String resultText)
  toolResultMessage;
}

/// Projects [context] onto provider-neutral message records through
/// [profile].
List<OnDeviceMessage> convertOnDeviceMessages(
  Context context,
  OnDeviceCodecProfile profile,
) {
  final messages = <OnDeviceMessage>[];

  final system = profile.systemMessage(
    context.systemPrompt ?? '',
    context.tools != null && context.tools!.isNotEmpty,
  );
  if (system != null) messages.add(system);

  for (final message in context.messages) {
    switch (message) {
      case UserMessage():
        _projectUser(message, profile, messages);
      case AssistantMessage():
        _projectAssistant(message, profile, messages);
      case ToolResultMessage():
        final resultText = onDeviceResultText(message);
        messages.add(
          profile.toolResultMessage(
            message,
            resultText.isEmpty ? onDeviceNoOutput : resultText,
          ),
        );
    }
  }
  return messages;
}

void _projectUser(
  UserMessage message,
  OnDeviceCodecProfile profile,
  List<OnDeviceMessage> messages,
) {
  final content = message.content;
  if (content is String) {
    if (content.trim().isNotEmpty) {
      messages.add((
        role: 'user',
        content: content,
        toolName: null,
        images: const [],
      ));
    }
    return;
  }
  final blocks = content as List<ContentBlock>;
  final parts = <String>[
    for (final block in blocks)
      if (block is TextContent && block.text.trim().isNotEmpty) block.text,
  ];
  final projected = profile.projectImages(
    blocks.whereType<ImageContent>().toList(),
  );
  final omissionNote = projected.omissionNote;
  if (omissionNote != null) parts.add(omissionNote);
  if (parts.isNotEmpty || projected.dataUris.isNotEmpty) {
    messages.add((
      role: 'user',
      content: parts.join('\n'),
      toolName: null,
      images: projected.dataUris,
    ));
  }
}

void _projectAssistant(
  AssistantMessage message,
  OnDeviceCodecProfile profile,
  List<OnDeviceMessage> messages,
) {
  final parts = <String>[
    for (final block in message.content)
      if (block is TextContent && block.text.trim().isNotEmpty) block.text,
  ];
  final calls = [
    for (final block in message.content)
      if (block is ToolCall) block,
  ];
  for (final call in calls) {
    final line = profile.toolCallLine(call);
    if (line != null) parts.add(line);
  }
  if (parts.isNotEmpty) {
    messages.add((
      role: 'assistant',
      content: parts.join('\n'),
      toolName: null,
      images: const [],
    ));
  }
  messages.addAll(profile.extraAssistantMessages(calls));
}

/// The raw newline join of a tool result's text blocks — the exact text
/// all three engines forwarded pre-refactor (no filtering; the empty join
/// collapses to [onDeviceNoOutput] downstream).
String onDeviceResultText(ToolResultMessage result) => result.content
    .whereType<TextContent>()
    .map((block) => block.text)
    .join('\n');

/// The plain-text fallback for an empty tool result (all three engines).
const onDeviceNoOutput = '(no output)';

/// The inline `[tool call: name(json)]` line for a historical tool call
/// (transformers.js and WebLLM wire shapes — role alternation is preserved
/// without a tool role).
String onDeviceToolCallLine(ToolCall call) =>
    '[tool call: ${call.name}(${jsonEncode(call.arguments)})]';

/// The `[tool result · name · error]` header transformers.js and WebLLM
/// prefix tool results with (their chat templates have no tool role, so
/// results become user messages).
String onDeviceToolResultHeader(ToolResultMessage result) =>
    '[tool result · ${result.toolName}'
    '${result.isError ? ' · error' : ''}]';
