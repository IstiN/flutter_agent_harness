/// Phase 2 of the subagents 2.0 plan: compaction-time memory extraction.
///
/// The [memoryExtractionHook] on [CompactionManager] receives the summarized
/// span's text and mines it for durable facts through the smol model using
/// the `prompts/memory/extract_durable.md` prompt. Extracted entries land in
/// the [MemoryController]; failures never block the compaction itself.
library;

import 'dart:convert';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../types.dart';
import 'memory_controller.dart';

/// One extracted durable-fact entry (the extract prompt's JSON shape).
final class ExtractedMemoryEntry {
  const ExtractedMemoryEntry({
    required this.text,
    this.type = 'note',
    this.topics = const [],
    this.tags = const [],
    this.importance = 0.5,
  });

  final String text;
  final String type;
  final List<String> topics;
  final List<String> tags;
  final double importance;

  factory ExtractedMemoryEntry.fromJson(Map<String, dynamic> json) =>
      ExtractedMemoryEntry(
        text: json['text'] as String? ?? '',
        type: json['type'] as String? ?? 'note',
        topics: (json['topics'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .take(3)
            .toList(),
        tags: (json['tags'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .take(3)
            .toList(),
        importance: (json['importance'] as num?)?.toDouble() ?? 0.5,
      );
}

/// Input cap for the extraction prompt (chars, ~8k tokens of source text).
const maxExtractionSpanChars = 32 * 1024;

/// Builds the [CompactionManager.memoryExtractionHook] wired to [memory].
///
/// [stream] / [model] back the smol-role extraction call; every failure
/// (network, malformed JSON, memory-store error) is swallowed — extraction
/// must never block or fail a compaction.
Future<void> Function(String summarizedText)? compactionMemoryHook({
  required MemoryController? memory,
  required StreamFunction? stream,
  required Model? model,
}) {
  if (memory == null || stream == null || model == null) return null;
  return (String summarizedText) async {
    try {
      final entries = await extractDurableEntries(
        stream,
        model,
        summarizedText,
      );
      for (final entry in entries) {
        await memory.add(
          text: entry.text,
          type: entry.type,
          tags: entry.tags,
          importance: entry.importance,
        );
      }
    } on Object {
      // Non-blocking by contract (phase 2 spec): log-and-skip.
    }
  };
}

/// Sends the capped span to the model with the extraction prompt and parses
/// the JSON array response. Malformed output yields no entries (skip).
Future<List<ExtractedMemoryEntry>> extractDurableEntries(
  StreamFunction stream,
  Model model,
  String span, {
  CancelToken? cancelToken,
}) async {
  final capped = _capSpan(span);
  final prompt = memoryExtractDurablePrompt.replaceAll('{{span}}', capped);
  // ignore: avoid_redundant_argument_values
  final response = await stream(
    model,
    Context(
      systemPrompt: prompt,
      messages: [UserMessage.text('Extract the durable facts.')],
    ),
    cancelToken: cancelToken,
  ).result;
  if (response.stopReason != StopReason.stop &&
      response.stopReason != StopReason.toolUse &&
      response.stopReason != StopReason.length) {
    return const [];
  }
  final text = response.content
      .whereType<TextContent>()
      .map((block) => block.text)
      .join('\n')
      .trim();
  return parseExtractedEntries(text);
}

/// Parses the model's JSON array (tolerant: strips code fences, extracts
/// the outermost `[…]`; same defensive posture as the task schema parser).
List<ExtractedMemoryEntry> parseExtractedEntries(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  final json = _tryParse(_stripFence(trimmed)) ?? _tryParse(trimmed);
  if (json == null) {
    // Outermost array span fallback.
    final start = trimmed.indexOf('[');
    final end = trimmed.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    final inner = _tryParse(trimmed.substring(start, end + 1));
    if (inner is! List) return const [];
    return _entriesFromList(inner);
  }
  if (json is! List) return const [];
  return _entriesFromList(json);
}

List<ExtractedMemoryEntry> _entriesFromList(List<dynamic> list) {
  final entries = <ExtractedMemoryEntry>[];
  for (final item in list) {
    if (item is Map<String, dynamic>) {
      final entry = ExtractedMemoryEntry.fromJson(item);
      if (entry.text.trim().isNotEmpty) entries.add(entry);
    }
  }
  return entries;
}

String _capSpan(String span) {
  if (span.length <= maxExtractionSpanChars) return span;
  // Head + tail split of the budget, keeping a marker for the cut middle.
  final half = maxExtractionSpanChars ~/ 2;
  return '${span.substring(0, half)}\n\n[… middle of the span elided …]\n\n'
      '${span.substring(span.length - half)}';
}

String _stripFence(String text) {
  final fence = RegExp(r'```(?:json|JSON)?\s*\r?\n([\s\S]*?)```');
  final matches = fence.allMatches(text).toList();
  if (matches.isEmpty) return text;
  return matches.last.group(1)!.trim();
}

Object? _tryParse(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
