// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Matches the agent-facing `[attached file: `<path>` — read it with your
/// tools]` reference every send path prepends per attachment.
final RegExp _attachedFilePattern = RegExp(
  r'\[attached file: (\S+?)(?: — read it with your tools)?\]\s*\n?',
);

/// Splits a user text into the visible content and the attachment parts
/// encoded by its `[attached file: …]` references (issue #461): every
/// reference becomes a record entry — a file chip, or the
/// `[image unavailable]` placeholder when the path is a raster image no
/// longer carrying bytes (text-only backends never inline them).
(String, List<FaChatAttachment>) _projectAttachmentText(String text) {
  final attachments = <FaChatAttachment>[
    for (final match in _attachedFilePattern.allMatches(text))
      (bytes: null, path: match.group(1)),
  ];
  if (attachments.isEmpty) return (text, const []);
  return (text.replaceAll(_attachedFilePattern, '').trim(), attachments);
}

/// Projects a persisted context [Message] back into the UI transcript.
FahChatMessage _toChatMessage(Message message) {
  switch (message) {
    case UserMessage(:final content):
      if (content is String) {
        final (visible, attachments) = _projectAttachmentText(content);
        return FahChatMessage(
          role: 'user',
          content: visible,
          attachments: attachments,
        );
      }
      final blocks = content as List<ContentBlock>;
      final imageBytes = [
        for (final block in blocks.whereType<ImageContent>())
          base64Decode(block.data),
      ];
      // Issue #461: the bubble renders from the record's attachment
      // parts. Every attachment rides an agent-facing path reference;
      // hosted providers additionally inline the raster ones as image
      // content, in the same order the references appear — so pair them
      // positionally. A raster reference without bytes means the record
      // lost the image (registry cap/drop, on-device path-only sends):
      // the tile shows the `[image unavailable]` placeholder. Other
      // references render as file chips; leftover image content (bytes
      // sent without a reference — in-app screenshots) as thumbnails.
      final text = blocks
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');
      var consumed = 0;
      final attachments = <FaChatAttachment>[
        for (final match in _attachedFilePattern.allMatches(text))
          if (isInlineImageMimeType(mimeTypeForUploadName(match.group(1)!)))
            (
              bytes: consumed < imageBytes.length
                  ? imageBytes[consumed++]
                  : null,
              path: match.group(1),
            )
          else
            (bytes: null, path: match.group(1)),
        for (var i = consumed; i < imageBytes.length; i++)
          (bytes: imageBytes[i], path: null),
      ];
      // Strip the agent-facing references from the visible text — the
      // attachment row carries the content, the paths are for the agent.
      return FahChatMessage(
        role: 'user',
        content: text.replaceAll(_attachedFilePattern, '').trim(),
        attachments: attachments,
      );
    case AssistantMessage(:final content):
      return FahChatMessage(
        role: 'assistant',
        content: content.whereType<TextContent>().map((b) => b.text).join(),
      );
    case ToolResultMessage(:final content, :final toolName, :final isError):
      return FahChatMessage(
        role: 'tool',
        content: content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n'),
        toolName: toolName,
        isError: isError,
      );
    default:
      return FahChatMessage(role: 'system', content: message.toString());
  }
}
