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

/// Resolves every auth-expired card in the live transcript (issue #623).
///
/// A failed provider run lands its `[[auth-expired:<id>]]` error in the
/// transcript as an actionable "Session expired — Authorize" card (see
/// `_finalizeAssistant`). Once a sign-in completes — from that card's own
/// button, the extension cookie flow, or Settings — the card no longer
/// reflects reality, and leaving it up invites a pointless second
/// authorize for a session that is already READY. All stale cards are
/// removed and a single system note lands where the newest one was, so
/// the transcript reads as resolved instead of stuck.
extension AgentServiceTranscript on AgentService {
  void resolveAuthExpiredCards() {
    final staleIndexes = <int>[
      for (var i = 0; i < messages.length; i++)
        if (authExpiredProvider(messages[i].content) != null) i,
    ];
    if (staleIndexes.isEmpty) return;
    final providerId =
        authExpiredProvider(messages[staleIndexes.last].content) ?? 'codemie';
    // Tail-first removal keeps the pending indexes valid.
    for (final index in staleIndexes.reversed) {
      messages.removeAt(index);
    }
    // The newest card's slot, shifted by the cards removed ahead of it.
    final noteAt = staleIndexes.last - (staleIndexes.length - 1);
    messages.insert(
      noteAt.clamp(0, messages.length),
      FaChatMessage(
        role: 'system',
        content: 'Authorization successful — the $providerId session was '
            'refreshed. Try sending your message again.',
      ),
    );
    _notify();
  }
}
