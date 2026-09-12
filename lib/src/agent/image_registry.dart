/// Per-session image registry — issue #155 work package E.
///
/// Port of learn.ai's global `[Image N]` indexing. Each unique image in
/// the outgoing request context rides exactly once, at its first
/// chronological occurrence, labeled `[Image N]`; every later occurrence
/// of the same bytes is replaced by the bare text reference `[Image N]`.
/// A photo from 50 turns ago costs a reference, not a re-upload.
///
/// Uniqueness is exact-content dedup (mime type + base64 body). When the
/// number of unique images exceeds [maxImages], the NEWEST occurrences
/// win and each dropped image is reported through [onSkip] — never
/// random, never silent.
///
/// Pure request-payload rewrite: installed via [attachImageRegistry] as
/// an [Agent.transformContext] hook (chained after any existing hook, the
/// same pattern as the secret redactor). The transcript itself is never
/// mutated — only what the provider sees.
library;

import 'dart:async';

import 'agent.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../types.dart';

/// Default cap on unique images per request (env `FAH_MAX_IMAGES`
/// overrides; 0 disables the registry).
const defaultMaxImagesPerRequest = 10;

/// Rewrites [messages] so every unique image rides once.
///
/// Returns the SAME list instance when there is nothing to rewrite (the
/// common text-only case — zero allocation).
List<Message> applyImageRegistry(
  List<Message> messages, {
  int maxImages = defaultMaxImagesPerRequest,
  void Function(String note)? onSkip,
}) {
  if (maxImages <= 0) return messages;

  // Pass 1: collect unique images (mime+data) in first-occurrence order
  // and the occurrence order of every block.
  final indexOf = <String, int>{}; // content key -> registry index
  final occurrences = <(_Occurrence, int)>[]; // occurrence -> registry index
  for (final message in messages) {
    for (final (blockIndex, block) in _imageBlocks(message)) {
      final key = '${block.mimeType}\n${block.data}';
      final index = indexOf.putIfAbsent(key, () => indexOf.length);
      occurrences.add((_Occurrence(message, blockIndex), index));
    }
  }
  if (occurrences.isEmpty) return messages;

  // Pass 2: pick which unique images ride. Over the cap the newest
  // occurrences win: an image seen recently is likelier to matter than
  // one from 50 turns ago.
  final riding = _ridingIndexes(occurrences, maxImages, onSkip);

  // Pass 3: rebuild every message holding images. The carrier of a
  // riding index is its FIRST occurrence (stable `[Image N]` labels
  // across turns); every other occurrence becomes the bare reference.
  final occurrenceOrdinal = <Message, Map<int, int>>{};
  final carrierOf = <int, int>{}; // registry index -> carrier occurrence
  for (final (ordinal, (occurrence, registryIndex)) in occurrences.indexed) {
    occurrenceOrdinal
        .putIfAbsent(occurrence.message, () => {})
        .putIfAbsent(occurrence.blockIndex, () => ordinal);
    carrierOf.putIfAbsent(registryIndex, () => ordinal);
  }
  return [
    for (final message in messages)
      _rewriteMessage(message, occurrenceOrdinal[message], carrierOf, indexOf, riding),
  ];
}

/// The [Agent.transformContext] hook form of the registry.
Future<List<Message>> imageRegistryTransform(
  List<Message> messages,
  CancelToken? cancelToken,
) async => applyImageRegistry(messages);

/// Installs the registry on [agent], chaining after any existing
/// [Agent.transformContext] hook.
void attachImageRegistry(
  Agent agent, {
  int maxImages = defaultMaxImagesPerRequest,
  void Function(String note)? onSkip,
}) {
  final previous = agent.transformContext;
  agent.transformContext = (messages, cancelToken) async {
    final input = await previous?.call(messages, cancelToken) ?? messages;
    return applyImageRegistry(input, maxImages: maxImages, onSkip: onSkip);
  };
}

final class _Occurrence {
  const _Occurrence(this.message, this.blockIndex);

  final Message message;
  final int blockIndex;
}

Object? _rawContent(Message message) => switch (message) {
  UserMessage(:final content) => content,
  ToolResultMessage(:final content) => content,
  AssistantMessage(:final content) => content,
  _ => null,
};

/// Image blocks with their indexes in the FULL content list (text blocks
/// shift them; the rewrite iterates the full list).
List<(int, ImageContent)> _imageBlocks(Message message) {
  final raw = _rawContent(message);
  if (raw is! List<ContentBlock>) return const [];
  return [
    for (final (blockIndex, block) in raw.indexed)
      if (block is ImageContent) (blockIndex, block),
  ];
}

/// Replaces the dropped/`ref` image blocks in [message] with text refs;
/// labels the carrier of each riding image `[Image N]`.
Message _rewriteMessage(
  Message message,
  Map<int, int>? ordinalOfBlock,
  Map<int, int> carrierOf,
  Map<String, int> indexOf,
  Set<int> riding,
) {
  final Object? raw = _rawContent(message);
  if (raw is! List<ContentBlock>) return message;
  var changed = false;
  final out = <ContentBlock>[];
  for (final (blockIndex, block) in raw.indexed) {
    if (block is! ImageContent) {
      out.add(block);
      continue;
    }
    final registryIndex = indexOf['${block.mimeType}\n${block.data}']!;
    final label = '[Image $registryIndex]';
    final isCarrier =
        carrierOf[registryIndex] == ordinalOfBlock?[blockIndex] &&
        riding.contains(registryIndex);
    changed = true;
    if (isCarrier) {
      // Label the image so the model can cite it.
      out
        ..add(TextContent(text: label))
        ..add(block);
    } else {
      out.add(TextContent(text: label));
    }
  }
  if (!changed) return message;
  return switch (message) {
    UserMessage() => UserMessage(content: out, timestamp: message.timestamp),
    ToolResultMessage() => ToolResultMessage(
      toolCallId: message.toolCallId,
      toolName: message.toolName,
      content: out,
      isError: message.isError,
      timestamp: message.timestamp,
    ),
    AssistantMessage() => message.copyWith(content: out),
    _ => message,
  };
}

/// The registry indexes that ride this request, newest-occurrence-first.
Set<int> _ridingIndexes(
  List<(_Occurrence, int)> occurrences,
  int maxImages,
  void Function(String note)? onSkip,
) {
  final unique = {
    for (final (_, registryIndex) in occurrences) registryIndex,
  };
  if (unique.length <= maxImages) return unique;
  // Walk occurrences newest-first; the first maxImages distinct indexes
  // ride.
  final riding = <int>{};
  for (final (_, registryIndex) in occurrences.reversed) {
    if (riding.length >= maxImages) break;
    riding.add(registryIndex);
  }
  final dropped = unique.difference(riding).toList()..sort();
  for (final registryIndex in dropped) {
    onSkip?.call(
      '[Image $registryIndex] dropped: over per-request image cap '
      '($maxImages; priority: newest)',
    );
  }
  return riding;
}
