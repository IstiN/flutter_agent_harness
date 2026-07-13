/// Conversation-context types: user and tool-result messages, tools, and the
/// [Context] handed to provider adapters.
///
/// Ported from pi-mono `packages/ai/src/types.ts` (`UserMessage`,
/// `ToolResultMessage`, `Tool`, `Context`). Kept mechanically close to the
/// TypeScript originals so future pi fixes port trivially.
library;

import 'types.dart';

/// A message authored by the user.
///
/// Ported from pi's `UserMessage`. [content] is either a plain [String] or a
/// `List<ContentBlock>` containing [TextContent] and/or [ImageContent],
/// mirroring pi's `string | (TextContent | ImageContent)[]`.
final class UserMessage implements Message {
  const UserMessage({required this.content, required this.timestamp});

  /// Convenience constructor for a plain-text user message.
  UserMessage.text(String text, {DateTime? timestamp})
    : content = text,
      timestamp = timestamp ?? DateTime.now();

  /// Plain text, or content blocks (text and images).
  final Object content;

  @override
  final DateTime timestamp;

  @override
  String get role => 'user';

  @override
  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content is String
        ? content
        : [
            for (final block in content as List<ContentBlock>) block.toJson(),
          ],
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory UserMessage.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'];
    return UserMessage(
      content: rawContent is String
          ? rawContent
          : [
              for (final block in (rawContent as List?) ?? const [])
                ContentBlock.fromJson(block as Map<String, dynamic>),
            ],
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int? ?? 0,
      ),
    );
  }
}

/// The result of executing a tool the model asked to invoke.
///
/// Ported from pi's `ToolResultMessage` (without the `details` generic and
/// `addedToolNames`, which belong to a later phase).
final class ToolResultMessage implements Message {
  const ToolResultMessage({
    required this.toolCallId,
    required this.toolName,
    required this.content,
    required this.isError,
    required this.timestamp,
  });

  /// The [ToolCall.id] this result answers.
  final String toolCallId;

  /// The name of the tool that produced this result.
  final String toolName;

  /// Result content: text and/or images.
  final List<ContentBlock> content;

  /// Whether the tool execution failed.
  final bool isError;

  @override
  final DateTime timestamp;

  @override
  String get role => 'toolResult';

  @override
  Map<String, dynamic> toJson() => {
    'role': role,
    'toolCallId': toolCallId,
    'toolName': toolName,
    'content': content.map((block) => block.toJson()).toList(),
    'isError': isError,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory ToolResultMessage.fromJson(Map<String, dynamic> json) =>
      ToolResultMessage(
        toolCallId: json['toolCallId'] as String? ?? '',
        toolName: json['toolName'] as String? ?? '',
        content: [
          for (final block in (json['content'] as List?) ?? const [])
            ContentBlock.fromJson(block as Map<String, dynamic>),
        ],
        isError: json['isError'] as bool? ?? false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          json['timestamp'] as int? ?? 0,
        ),
      );
}

/// Deserializes a [Message] from its JSON map, dispatching on `role`.
Message messageFromJson(Map<String, dynamic> json) {
  return switch (json['role']) {
    'user' => UserMessage.fromJson(json),
    'assistant' => AssistantMessage.fromJson(json),
    'toolResult' => ToolResultMessage.fromJson(json),
    _ => throw FormatException('Unknown message role: ${json['role']}'),
  };
}

/// A tool the model may invoke, with a JSON Schema for its parameters.
///
/// Ported from pi's `Tool`. pi carries a TypeBox schema; here [parameters] is
/// the equivalent plain JSON Schema map.
final class Tool {
  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  /// The tool's name (what the model calls).
  final String name;

  /// Human- and model-readable description of what the tool does.
  final String description;

  /// JSON Schema for the tool's arguments.
  final Map<String, dynamic> parameters;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'parameters': parameters,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory Tool.fromJson(Map<String, dynamic> json) => Tool(
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    parameters:
        (json['parameters'] as Map<String, dynamic>?) ??
        const <String, dynamic>{},
  );
}

/// Everything a provider needs to produce the next assistant message.
///
/// Ported from pi's `Context`.
final class Context {
  const Context({this.systemPrompt, required this.messages, this.tools});

  /// Optional system prompt, sent first by providers that support one.
  final String? systemPrompt;

  /// The conversation so far, oldest first.
  final List<Message> messages;

  /// Tools available to the model, if any.
  final List<Tool>? tools;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    if (systemPrompt != null) 'systemPrompt': systemPrompt,
    'messages': messages.map((message) => message.toJson()).toList(),
    if (tools != null) 'tools': tools!.map((tool) => tool.toJson()).toList(),
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory Context.fromJson(Map<String, dynamic> json) => Context(
    systemPrompt: json['systemPrompt'] as String?,
    messages: [
      for (final message in (json['messages'] as List?) ?? const [])
        messageFromJson(message as Map<String, dynamic>),
    ],
    tools: (json['tools'] as List?)
        ?.map((tool) => Tool.fromJson(tool as Map<String, dynamic>))
        .toList(),
  );
}
