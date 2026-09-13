/// Session image registry (issue #171): unique images ride a provider
/// request exactly ONCE; every later occurrence in the kept window becomes
/// a stable text reference `[Image N]`.
///
/// The registry is DERIVED state, rebuilt from the request's message
/// window on every provider call — the session JSONL keeps message records
/// exactly as today (byte-level invariant I1), and the same window always
/// rebuilds the same registry (determinism I2). Request-assembly rules:
///
/// - Image content blocks in history (user messages and tool results) are
///   swapped for `[Image N]` text refs; the unique original rides in a
///   dedicated carrier user message `[TextBlock("[Image N]"), ImageBlock]`
///   inserted before the first referencing user message, or after the
///   tool-result run when the first reference lives in a tool result
///   (nothing may sit between a tool call and its result on the wire).
/// - The CURRENT user message (the last one in the window) always rides
///   its images in place, never as references (I3) — the model must see
///   what the user just sent; each in-place image carries its `[Image N]`
///   label so the model can cite it back (F3).
/// - A per-request cap on unique images drops by priority (current >
///   newest history > older history); every drop is reported through the
///   drop notice — never silent.
/// - No dangling refs (I4): an `[Image N]` mention whose original is not
///   in the request (compacted away, outside the window, or dropped by
///   the cap) resolves to the plain-text note [unavailableImageNote].
///   Authored citations in history are trusted only while the window was
///   never renumbered: once a compaction/trim boundary appears, history
///   citations degrade to the note too — after eviction the number may
///   name a DIFFERENT image, and a silent rebind would be wrong data
///   (F2). The current message is authored after the last renumbering and
///   stays trusted.
///
/// Mechanics ported from learn.ai's production Go engine
/// (`solution_chat/v2/core/workflow.go`): content-key dedup, first-seen
/// indexing, the `allowNew`-style cap gate, and resilient mention
/// resolution.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../context.dart';
import '../compaction/structured/markers.dart'
    show isCompactionMarkerText, localTrimMarkerPrefix;
import '../session/session_tree.dart'
    show branchSummaryPrefix, compactionSummaryPrefix;
import '../types.dart';

/// Default per-request cap on unique images (`images.maxPerRequest`).
/// Generous enough that ordinary sessions never hit it; photo-heavy long
/// threads stay flat instead of growing linearly. ~20 inline images is
/// well inside every current vision model's budget.
const defaultMaxImagesPerRequest = 20;

/// The note replacing image refs whose original is not in the request
/// (compaction interplay / cap drops — never a dangling ref).
const unavailableImageNote = '(image no longer available)';

/// The reference grammar: `[Image 3]` inline text.
final RegExp imageRefPattern = RegExp(r'\[Image (\d+)\]');

/// Renders the reference label for [index].
String imageRefLabel(int index) => '[Image $index]';

/// Settings for the `images:` config section (`~/.fah/config.yaml`).
final class ImageRegistryConfig {
  const ImageRegistryConfig({
    this.enabled = true,
    this.maxPerRequest = defaultMaxImagesPerRequest,
  });

  /// Kill switch: `images.registry: false` reproduces today's request
  /// shape byte-for-byte (no rewrite at all).
  final bool enabled;

  /// Per-request cap on unique images (`images.maxPerRequest`).
  final int maxPerRequest;
}

/// Process-wide image-registry settings, published by hosts at boot from
/// the `images:` config section (same pattern as
/// `providerTimeoutsOverride`): the rewrite happens deep inside the agent
/// loop's request build, far from any host config object.
ImageRegistryConfig imageRegistryConfig = const ImageRegistryConfig();

/// Host-visible drop notice: every image dropped by the per-request cap
/// is reported with its index and a key preview — never silent.
typedef ImageDropNotice = void Function(int index, String keyPreview);

/// Set by hosts that surface drops (the CLI prints a dim transcript line
/// + logs to fa.log). Same pattern as `transientRetryNotice`.
ImageDropNotice? imageDropNotice;

/// One unique image in the window.
final class ImageRegistryEntry {
  const ImageRegistryEntry({
    required this.index,
    required this.key,
    required this.data,
    required this.mimeType,
  });

  /// First-seen-order index inside the window (the `N` of `[Image N]`).
  final int index;

  /// Content key of the canonical payload string.
  final String key;

  /// Base64 payload (data-URL bytes).
  final String data;

  /// Mime type of the payload.
  final String mimeType;
}

/// The per-window image registry: content-keyed, rebuilt deterministically
/// from a message list (issue #171 I2).
final class ImageRegistry {
  const ImageRegistry._(this._entries);

  final List<ImageRegistryEntry> _entries;

  /// Scans [messages] (oldest first) assigning indexes in first-seen
  /// order over every image-bearing user message and tool result.
  static ImageRegistry scan(List<Message> messages) {
    final entries = <ImageRegistryEntry>[];
    final seen = <String>{};
    for (final message in messages) {
      for (final image in _imagesOf(message)) {
        final key = imageContentKey(image);
        if (seen.add(key)) {
          entries.add(
            ImageRegistryEntry(
              index: entries.length,
              key: key,
              data: image.data,
              mimeType: image.mimeType,
            ),
          );
        }
      }
    }
    return ImageRegistry._(entries);
  }

  /// Number of unique images in the window.
  int get length => _entries.length;

  /// The `{content key → index}` map (deterministic for one window).
  Map<String, int> get indexByKey => {
    for (final entry in _entries) entry.key: entry.index,
  };
}

/// Content key of an image: SHA-256 over the canonical payload string
/// (`data:<mime>;base64,<data>`). Same bytes under a different mime are
/// distinct entries (re-encoded occurrences dedup-miss — correct but
/// suboptimal, learn.ai's resilient-lookup semantics).
String imageContentKey(ImageContent image) => sha256
    .convert(utf8.encode('data:${image.mimeType};base64,${image.data}'))
    .toString();

/// A short, stable preview of a content key for drop notices.
String imageKeyPreview(String key) => key.substring(0, 8);

/// Rewrites the OUTGOING request payload (never the transcript): image
/// blocks become `[Image N]` refs, unique originals ride once as carriers,
/// the current user message rides in place, and the per-request cap drops
/// by priority (current > newest > older) reporting every drop.
///
/// Returns the SAME list instance when there is nothing to rewrite (no
/// images and no `[Image N]` mentions), so image-free sessions pay
/// nothing.
List<Message> rewriteHistoryImages(
  List<Message> messages, {
  int? maxPerRequest,
  void Function(int index, String keyPreview)? onDrop,
}) {
  var hasImages = false;
  for (final message in messages) {
    if (_imagesOf(message).isNotEmpty) {
      hasImages = true;
      break;
    }
  }
  if (!hasImages && !messages.any(_mentionsImageRef)) return messages;

  // F2 pre-pass: when the window carries a renumbering boundary, history
  // citations may name a different image than their number does now —
  // degrade AUTHORED text mentions before assembly. Block rewrites,
  // carrier labels and the current message are generated content-keyed
  // (or provably fresh) and must survive.
  final currentIdx0 = _lastUserMessageIndex(messages);
  final degraded = messages.any(_isRenumberingBoundary)
      ? [
          for (var i = 0; i < messages.length; i++)
            i == currentIdx0
                ? messages[i]
                : _resolveMentions(messages[i], const <int>{}, trusted: false),
        ]
      : messages;
  final cap = maxPerRequest ?? imageRegistryConfig.maxPerRequest;
  final entryByKey = <String, ImageRegistryEntry>{};
  final occurrences = <String, List<int>>{};
  _scanImages(degraded, entryByKey, occurrences);
  final currentIdx = _lastUserMessageIndex(degraded);
  final riding = _selectRiding(
    degraded,
    entryByKey,
    occurrences,
    currentIdx,
    cap,
    onDrop,
  );
  final carriers = _planCarriers(degraded, entryByKey, occurrences, riding);

  // Emit: rewritten history (image blocks → refs/notes), the current
  // message in place with fresh `[Image N]` labels (F3), carriers at
  // their anchors.
  final out = _emitRewritten(degraded, currentIdx, riding, carriers);

  // Mention pass (I4): every remaining `[Image N]` in text that does not
  // resolve to a riding index becomes the unavailable note. Authored
  // history citations were already degraded by the pre-pass; what
  // survives here is generated content-keyed text.
  final ridingIndexes = riding.indexByKey.values.toSet();
  return [for (final message in out) _resolveMentions(message, ridingIndexes)];
}

/// Whether [message] is a projected renumbering boundary: a classic
/// compaction summary, a structured hidden/checkpoint marker, or the
/// local trim valve note. Any of these means history was evicted at some
/// point, so `[Image N]` citations authored before it may now bind to a
/// different image (issue #195 F2).
bool _isRenumberingBoundary(Message message) {
  if (message is UserMessage) {
    final content = message.content;
    if (content is String) {
      return content.startsWith(compactionSummaryPrefix) ||
          content.startsWith(branchSummaryPrefix) ||
          content.startsWith(localTrimMarkerPrefix) ||
          isCompactionMarkerText(content);
    }
    return false;
  }
  if (message is ToolResultMessage) {
    // Structured hide keeps the tool_use visible and projects the hidden
    // result as a lone marker text — that is a renumbering boundary too.
    return message.content.any(
      (block) => block is TextContent && isCompactionMarkerText(block.text),
    );
  }
  return false;
}

/// Scan pass: first-seen entries + per-key occurrence positions.
void _scanImages(
  List<Message> messages,
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences,
) {
  for (var i = 0; i < messages.length; i++) {
    for (final image in _imagesOf(messages[i])) {
      final key = imageContentKey(image);
      var entry = entryByKey[key];
      if (entry == null) {
        entry = ImageRegistryEntry(
          index: entryByKey.length,
          key: key,
          data: image.data,
          mimeType: image.mimeType,
        );
        entryByKey[key] = entry;
      }
      occurrences.putIfAbsent(key, () => []).add(i);
    }
  }
}

/// The current user message: the LAST one in the window (I3 — a mid-run
/// steering message is the newest thing the user said).
int _lastUserMessageIndex(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i] is UserMessage) return i;
  }
  return -1;
}

/// The riding-set selection result.
final class _RidingSelection {
  const _RidingSelection(this.currentKeys, this.ridingKeys, this.indexByKey);

  /// Keys occurring in the current message (always ride, in place).
  final Set<String> currentKeys;

  /// Every key riding the request (current + capped history).
  final Set<String> ridingKeys;

  /// `{key → [Image N] index}` for riding keys.
  final Map<String, int> indexByKey;
}

/// Riding set. Current-message keys ALWAYS ride (in place — I3 outranks
/// the cap); the remaining slots go to the newest history keys, ties by
/// first-seen order. Every drop is reported — never silent.
_RidingSelection _selectRiding(
  List<Message> messages,
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences,
  int currentIdx,
  int cap,
  void Function(int index, String keyPreview)? onDrop,
) {
  final currentKeys = <String>{
    if (currentIdx >= 0)
      for (final image in _imagesOf(messages[currentIdx]))
        imageContentKey(image),
  };
  final historyKeys = [
    for (final entry in entryByKey.values)
      if (!currentKeys.contains(entry.key)) entry.key,
  ];
  int lastSeen(String key) => occurrences[key]!.last;
  historyKeys.sort((a, b) {
    final byRecency = lastSeen(b).compareTo(lastSeen(a));
    return byRecency != 0
        ? byRecency
        : entryByKey[a]!.index.compareTo(entryByKey[b]!.index);
  });
  final historySlots = (cap - currentKeys.length).clamp(0, historyKeys.length);
  for (final key in historyKeys.skip(historySlots)) {
    final entry = entryByKey[key]!;
    onDrop?.call(entry.index, imageKeyPreview(entry.key));
  }
  final ridingKeys = {...currentKeys, ...historyKeys.take(historySlots)};
  return _RidingSelection(currentKeys, ridingKeys, {
    for (final key in ridingKeys) key: entryByKey[key]!.index,
  });
}

/// The carrier insertion plan: index → carriers before/after that message.
final class _CarrierPlan {
  const _CarrierPlan(this.before, this.after);
  final Map<int, List<UserMessage>> before;
  final Map<int, List<UserMessage>> after;
}

/// One carrier per riding key that never occurs in the current message,
/// anchored at its FIRST occurrence — before the referencing user
/// message, or after the tool-result run that holds it (never inside:
/// nothing may sit between a tool call and its result).
_CarrierPlan _planCarriers(
  List<Message> messages,
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences,
  _RidingSelection riding,
) {
  final before = <int, List<UserMessage>>{};
  final after = <int, List<UserMessage>>{};
  final ridingByIndex = [...riding.ridingKeys]
    ..sort((a, b) => entryByKey[a]!.index.compareTo(entryByKey[b]!.index));
  for (final key in ridingByIndex) {
    if (riding.currentKeys.contains(key)) continue;
    final entry = entryByKey[key]!;
    final firstIdx = occurrences[key]!.first;
    final carrier = UserMessage(
      content: [
        TextContent(text: imageRefLabel(entry.index)),
        ImageContent(data: entry.data, mimeType: entry.mimeType),
      ],
      timestamp: messages[firstIdx].timestamp,
    );
    if (messages[firstIdx] is UserMessage) {
      before.putIfAbsent(firstIdx, () => []).add(carrier);
    } else {
      var runEnd = firstIdx;
      while (runEnd + 1 < messages.length &&
          messages[runEnd + 1] is ToolResultMessage) {
        runEnd++;
      }
      after.putIfAbsent(runEnd, () => []).add(carrier);
    }
  }
  return _CarrierPlan(before, after);
}

/// Emit pass: rewritten history (image blocks → refs/notes), untouched
/// current message, carriers at their anchors.
List<Message> _emitRewritten(
  List<Message> messages,
  int currentIdx,
  _RidingSelection riding,
  _CarrierPlan carriers,
) {
  final out = <Message>[];
  for (var i = 0; i < messages.length; i++) {
    out.addAll(carriers.before[i] ?? const <Message>[]);
    final message = messages[i];
    if (i == currentIdx) {
      out.add(_labelCurrentImages(message, riding.indexByKey));
    } else if (message is UserMessage) {
      final content = message.content;
      out.add(
        content is List<ContentBlock>
            ? _rewriteUserBlocks(message, content, riding.indexByKey)
            : message,
      );
    } else if (message is ToolResultMessage) {
      out.add(_rewriteResultBlocks(message, riding.indexByKey));
    } else {
      out.add(message);
    }
    out.addAll(carriers.after[i] ?? const <Message>[]);
  }
  return out;
}

/// F3: the current message's images ride in place AND carry their
/// `[Image N]` label as a preceding text block — the model can cite the
/// image it is looking at with the number the registry will honor.
Message _labelCurrentImages(Message message, Map<String, int> indexByKey) {
  if (message is! UserMessage) return message;
  final content = message.content;
  if (content is! List<ContentBlock>) return message;
  if (!content.any((block) => block is ImageContent)) return message;
  return UserMessage(
    content: [
      for (final block in content)
        if (block is ImageContent) ...[
          TextContent(
            text: imageRefLabel(indexByKey[imageContentKey(block)] ?? 0),
          ),
          block,
        ] else
          block,
    ],
    timestamp: message.timestamp,
  );
}

Iterable<ImageContent> _imagesOf(Message message) sync* {
  if (message is UserMessage) {
    final content = message.content;
    if (content is List<ContentBlock>) {
      yield* content.whereType<ImageContent>();
    }
  } else if (message is ToolResultMessage) {
    yield* message.content.whereType<ImageContent>();
  }
}

/// Whether any citable text surface of [message] carries a `[Image N]`
/// mention (fast-path guard — a miss here would leave a dangling ref).
bool _mentionsImageRef(Message message) {
  final texts = <String>[];
  switch (message) {
    case UserMessage(:final content):
      if (content is String) texts.add(content);
      if (content is List<ContentBlock>) {
        texts.addAll([
          for (final block in content)
            if (block is TextContent) block.text,
        ]);
      }
    case AssistantMessage(:final content):
      texts.addAll([
        for (final block in content)
          if (block is TextContent) block.text,
      ]);
    case ToolResultMessage(:final content):
      texts.addAll([
        for (final block in content)
          if (block is TextContent) block.text,
      ]);
  }
  return texts.any((text) => text.contains('[Image '));
}

UserMessage _rewriteUserBlocks(
  UserMessage message,
  List<ContentBlock> content,
  Map<String, int> ridingIndexByKey,
) {
  if (!content.any((block) => block is ImageContent)) return message;
  return UserMessage(
    content: _replaceImageBlocks(content, ridingIndexByKey),
    timestamp: message.timestamp,
  );
}

ToolResultMessage _rewriteResultBlocks(
  ToolResultMessage message,
  Map<String, int> ridingIndexByKey,
) {
  if (!message.content.any((block) => block is ImageContent)) return message;
  return ToolResultMessage(
    toolCallId: message.toolCallId,
    toolName: message.toolName,
    content: _replaceImageBlocks(message.content, ridingIndexByKey),
    isError: message.isError,
    timestamp: message.timestamp,
  );
}

/// Swaps image blocks for refs (riding) or the unavailable note (dropped).
List<ContentBlock> _replaceImageBlocks(
  List<ContentBlock> content,
  Map<String, int> ridingIndexByKey,
) {
  return [
    for (final block in content)
      switch (block) {
        ImageContent() => switch (ridingIndexByKey[imageContentKey(block)]) {
          final index? => TextContent(text: imageRefLabel(index)),
          null => const TextContent(text: unavailableImageNote),
        },
        _ => block,
      },
  ];
}

/// Resolves `[Image N]` text mentions against the riding set (I4).
///
/// When [trusted] is false (history authored before a renumbering
/// boundary — issue #195 F2), every mention degrades to the note: the
/// number may name a different image now, and a silent rebind would feed
/// the model wrong data.
Message _resolveMentions(
  Message message,
  Set<int> ridingIndexes, {
  bool trusted = true,
}) {
  String fix(String text) => text.contains('[Image ')
      ? text.replaceAllMapped(
          imageRefPattern,
          (match) =>
              trusted && ridingIndexes.contains(int.parse(match.group(1)!))
              ? match.group(0)!
              : unavailableImageNote,
        )
      : text;

  (List<ContentBlock>, bool) fixBlocks(List<ContentBlock> blocks) {
    var changed = false;
    return (
      [
        for (final block in blocks)
          switch (block) {
            TextContent(:final text) when text.contains('[Image ') => () {
              final fixed = fix(text);
              changed = changed || fixed != text;
              return block.copyWith(text: fixed);
            }(),
            _ => block,
          },
      ],
      changed,
    );
  }

  switch (message) {
    case UserMessage(:final content, :final timestamp):
      if (content is String) {
        final fixed = fix(content);
        return fixed == content
            ? message
            : UserMessage(content: fixed, timestamp: timestamp);
      }
      final (blocks, changed) = fixBlocks(content as List<ContentBlock>);
      return changed
          ? UserMessage(content: blocks, timestamp: timestamp)
          : message;
    case ToolResultMessage():
      final (blocks, changed) = fixBlocks(message.content);
      return changed
          ? ToolResultMessage(
              toolCallId: message.toolCallId,
              toolName: message.toolName,
              content: blocks,
              isError: message.isError,
              timestamp: message.timestamp,
            )
          : message;
    case AssistantMessage():
      final (blocks, changed) = fixBlocks(message.content);
      return changed ? message.copyWith(content: blocks) : message;
    default:
      return message;
  }
}
