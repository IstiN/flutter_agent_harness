/// Cross-harness session import (issue #1562): the typed foreign-record
/// union, the per-session scan result, and the import bounds.
///
/// Adapters (omp, claude) stream foreign JSONL stores read-only into
/// [ForeignRecord]s; the pure mapper ([mapForeignSession]) turns them into
/// FA append plans; the runner ([runImport]) writes through
/// `JsonlSessionRepo.create` + `Session.append*` only. Foreign stores are
/// never written.
library;

/// Import bounds (issue #1561 open questions 1 + 4, pinned at
/// implementation): files over [maxFileBytes] are refused before reading,
/// lines over [maxLineBytes] skip-with-count, image blobs embed only when
/// the file is present and at most [maxImageBytes], and the TUI keyword
/// search indexes at most [searchIndexBytes] of text per session.
final class ImportLimits {
  /// Creates [ImportLimits]. Defaults: 512 MiB per file, 16 MiB per line,
  /// 1 MiB per image blob, 64 KiB of search text per session.
  const ImportLimits({
    this.maxFileBytes = 512 * 1024 * 1024,
    this.maxLineBytes = 16 * 1024 * 1024,
    this.maxImageBytes = 1 * 1024 * 1024,
    this.searchIndexBytes = 64 * 1024,
  });

  /// Refusal threshold for one foreign session file (checked from the file
  /// size before any read).
  final int maxFileBytes;

  /// Skip threshold for one JSONL line.
  final int maxLineBytes;

  /// Embed threshold for one image blob (oversized blobs become counted
  /// placeholders).
  final int maxImageBytes;

  /// Search-text cap per session for the `/import` picker keyword index.
  final int searchIndexBytes;
}

/// A block of a foreign message's content.
///
/// Foreign content blocks are kept typed but lossless: anything the mapper
/// cannot place lands as [ForeignUnknownBlock] and is skipped-with-count,
/// never silently dropped.
sealed class ForeignContent {
  const ForeignContent();
}

/// Plain text.
final class ForeignText extends ForeignContent {
  /// Creates [ForeignText].
  const ForeignText(this.text);

  /// The text itself.
  final String text;
}

/// Model reasoning produced before or alongside the answer.
final class ForeignThinking extends ForeignContent {
  /// Creates [ForeignThinking].
  const ForeignThinking(this.thinking, {this.signature});

  /// The reasoning text.
  final String thinking;

  /// Provider-specific opaque signature, when the foreign record carried one.
  final String? signature;
}

/// A model request to invoke a tool.
final class ForeignToolCall extends ForeignContent {
  /// Creates [ForeignToolCall].
  const ForeignToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.partialArguments,
  });

  /// The call id a `toolResult` pairs with.
  final String id;

  /// The tool name.
  final String name;

  /// Parsed arguments, when the foreign record had a complete object.
  final Map<String, dynamic> arguments;

  /// Raw, not-yet-complete JSON argument text (interrupted streams).
  final String? partialArguments;
}

/// An image: embedded base64 (within bounds) or a counted placeholder.
final class ForeignImage extends ForeignContent {
  /// Creates an embedded image.
  const ForeignImage({required this.base64Data, required this.mimeType})
    : missingReason = null;

  /// Creates a skipped-image placeholder carrying the reason.
  const ForeignImage.skipped(this.missingReason)
    : base64Data = null,
      mimeType = null;

  /// Base64 image data, null when skipped.
  final String? base64Data;

  /// Declared MIME type (labeling only — never drives behavior).
  final String? mimeType;

  /// Why the image was skipped (missing blob, oversized, undecodable).
  final String? missingReason;
}

/// A content block the adapter does not model.
final class ForeignUnknownBlock extends ForeignContent {
  /// Creates [ForeignUnknownBlock].
  const ForeignUnknownBlock(this.type, this.raw);

  /// The foreign block `type` string.
  final String type;

  /// The raw block JSON map.
  final Map<String, dynamic> raw;
}

/// One foreign record, typed.
///
/// The union is deliberately shallow (per the retracted-IR ruling on the
/// GOAL card): adapters parse only what the mapper consumes; unmapped
/// foreign types land as [ForeignUnhandled] and map to FA `custom` entries.
sealed class ForeignRecord {
  /// Creates [ForeignRecord].
  const ForeignRecord({required this.lineNumber});

  /// 1-based line number in the foreign file (diagnostics only).
  final int lineNumber;
}

/// A title slot or `title_change` audit record.
final class ForeignTitleSlot extends ForeignRecord {
  /// Creates [ForeignTitleSlot].
  const ForeignTitleSlot({
    required super.lineNumber,
    required this.title,
    required this.source,
  });

  /// The title text.
  final String title;

  /// `user` or `auto` — user titles beat auto titles regardless of order.
  final String source;
}

/// The session header (`type:"session"`).
final class ForeignHeader extends ForeignRecord {
  /// Creates [ForeignHeader].
  const ForeignHeader({
    required super.lineNumber,
    required this.id,
    required this.cwd,
    required this.version,
    this.title,
    this.titleSource,
  });

  /// Foreign session id.
  final String id;

  /// Working directory recorded in the header (empty when absent).
  final String cwd;

  /// Format version (advisory — adapters tolerate 1-3).
  final int version;

  /// Legacy inline title (pre-title-slot files).
  final String? title;

  /// Legacy inline title source.
  final String? titleSource;
}

/// A conversation message (`type:"message"`).
final class ForeignMessage extends ForeignRecord {
  /// Creates [ForeignMessage].
  const ForeignMessage({
    required super.lineNumber,
    required this.role,
    required this.contents,
    required this.rawMessage,
    this.toolCallId,
    this.toolName,
    this.isError = false,
    this.model,
    this.provider,
    this.api,
    this.usage,
    this.stopReason,
    this.errorMessage,
  });

  /// camelCase foreign role (`user`, `developer`, `assistant`,
  /// `toolResult`, `bashExecution`, ...).
  final String role;

  /// Parsed content blocks.
  final List<ForeignContent> contents;

  /// The raw `message` JSON map (custom-entry fallbacks carry it verbatim).
  final Map<String, dynamic> rawMessage;

  /// `toolResult` pairing key.
  final String? toolCallId;

  /// `toolResult` tool name.
  final String? toolName;

  /// `toolResult` failure flag.
  final bool isError;

  /// Assistant model id, when the record carried one.
  final String? model;

  /// Assistant provider id, when the record carried one.
  final String? provider;

  /// Assistant API dialect, when the record carried one.
  final String? api;

  /// Raw usage map, when present (mapped best-effort onto FA [Usage]).
  final Map<String, dynamic>? usage;

  /// Raw terminal stop reason string, when present.
  final String? stopReason;

  /// Raw error message, when present.
  final String? errorMessage;
}

/// A `model_change` record.
final class ForeignModelChange extends ForeignRecord {
  /// Creates [ForeignModelChange].
  const ForeignModelChange({required super.lineNumber, required this.model});

  /// The model string verbatim (e.g. `zai/glm-5.3`).
  final String model;
}

/// A `thinking_level_change` record.
final class ForeignThinkingLevelChange extends ForeignRecord {
  /// Creates [ForeignThinkingLevelChange].
  const ForeignThinkingLevelChange({
    required super.lineNumber,
    required this.level,
  });

  /// The level, passed through (null/medium/high/xhigh/max or the raw
  /// foreign value).
  final String level;
}

/// A `compaction` record (summary verbatim; optional fields counted).
final class ForeignCompaction extends ForeignRecord {
  /// Creates [ForeignCompaction].
  const ForeignCompaction({
    required super.lineNumber,
    required this.summary,
    required this.droppedFields,
  });

  /// The summary text.
  final String summary;

  /// Optional fields present on the record but dropped (counted, never
  /// silent).
  final List<String> droppedFields;
}

/// A `custom` record: `customType` preserved byte-exact through the mapper.
final class ForeignCustom extends ForeignRecord {
  /// Creates [ForeignCustom].
  const ForeignCustom({
    required super.lineNumber,
    required this.customType,
    required this.data,
  });

  /// The foreign `customType` string (byte-exact).
  final String customType;

  /// The foreign `data` payload.
  final Object? data;
}

/// A `custom_message` record.
final class ForeignCustomMessage extends ForeignRecord {
  /// Creates [ForeignCustomMessage].
  const ForeignCustomMessage({
    required super.lineNumber,
    required this.customType,
    required this.content,
    required this.display,
    this.details,
    this.attribution,
  });

  /// The foreign `customType` string (byte-exact).
  final String customType;

  /// Plain text or parsed content blocks.
  final Object content;

  /// Whether the message renders in the transcript.
  final bool display;

  /// Foreign details payload.
  final Object? details;

  /// `user` or `agent`, when present.
  final String? attribution;
}

/// Any foreign record type (or message role) the adapter does not model —
/// tolerated and mapped to an inert `custom` entry, never a raw line.
final class ForeignUnhandled extends ForeignRecord {
  /// Creates [ForeignUnhandled].
  const ForeignUnhandled({
    required super.lineNumber,
    required this.type,
    required this.raw,
  });

  /// The foreign `type` (or role) string.
  final String type;

  /// The raw record JSON map.
  final Map<String, dynamic> raw;
}

/// A discovered foreign session (read-only reference + scan summary).
final class ForeignSessionSummary {
  /// Creates [ForeignSessionSummary].
  const ForeignSessionSummary({
    required this.harness,
    required this.sourceId,
    required this.sourcePath,
    required this.sizeBytes,
    required this.headerCwd,
    required this.title,
    required this.titleSource,
    required this.firstPreview,
    required this.lastPreview,
    required this.searchText,
    required this.mtimeMs,
  });

  /// The harness id (`omp`, `claude`, ...).
  final String harness;

  /// The foreign session id (header id when present, else the filename id).
  final String sourceId;

  /// Absolute path of the foreign file (read-only).
  final String sourcePath;

  /// File size in bytes.
  final int sizeBytes;

  /// Working directory recorded inside the file (empty when absent).
  final String headerCwd;

  /// The newest known title, if any.
  final String title;

  /// `user` or `auto` for [title].
  final String titleSource;

  /// First message text preview (≤160 chars, `-` when none).
  final String firstPreview;

  /// Last message text preview (≤160 chars, `-` when none).
  final String lastPreview;

  /// Bounded text blob (title + message text) for the TUI keyword search.
  final String searchText;

  /// File modification time (recency ordering).
  final int mtimeMs;
}

/// The result of fully reading one foreign session (leaf path only).
final class ForeignParseResult {
  /// Creates [ForeignParseResult].
  const ForeignParseResult({
    required this.records,
    required this.skippedRecords,
    required this.skippedBlocks,
  });

  /// Parsed records of the active (leaf-path) branch, root-first.
  final List<ForeignRecord> records;

  /// Whole records dropped while parsing (oversized/undecodable lines,
  /// off-branch records, sidechain entries) — reported in the summary.
  final int skippedRecords;

  /// Content blocks dropped inside mapped records (placeholder-ed).
  final int skippedBlocks;
}

/// Flattens a message-like content list to preview text (used for the
/// first/last previews and the keyword search index).
String foreignContentText(List<ForeignContent> contents) {
  final buffer = StringBuffer();
  for (final content in contents) {
    final text = switch (content) {
      ForeignText(:final text) => text,
      ForeignThinking(:final thinking) => thinking,
      _ => null,
    };
    if (text == null || text.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(text);
  }
  return buffer.toString();
}

/// Flattens [raw] string-or-block content into typed blocks, counting
/// unmappable blocks into [skippedBlocks].
///
/// [resolveBlob], when given (omp), turns a `blob:sha256:<hash>` reference
/// into an embedded-or-skipped [ForeignImage].
List<ForeignContent> parseForeignContent(
  Object? raw,
  void Function() onSkip, {
  ForeignImage? Function(String blobRef)? resolveBlob,
}) {
  if (raw is String) return [ForeignText(raw)];
  if (raw is! List) return const [];
  final blocks = <ForeignContent>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) {
      onSkip();
      continue;
    }
    if (item['type'] == 'tool_result') {
      // Claude lifts tool_result blocks into their own message records at
      // adapter level; here they are simply not a content block.
      onSkip();
      continue;
    }
    final block = _parseForeignBlock(item, onSkip, resolveBlob);
    if (block != null) blocks.add(block);
  }
  return blocks;
}

ForeignContent? _parseForeignBlock(
  Map<String, dynamic> json,
  void Function() onSkip,
  ForeignImage? Function(String blobRef)? resolveBlob,
) {
  switch (json['type']) {
    case 'text':
      return ForeignText(json['text'] as String? ?? '');
    case 'thinking':
      return ForeignThinking(
        json['thinking'] as String? ?? '',
        signature: (json['thinkingSignature'] ?? json['signature']) as String?,
      );
    case 'toolCall' || 'tool_use':
      final arguments = json['arguments'] ?? json['input'];
      final partial =
          (json['partialArguments'] ?? json['partialArgs']) as String?;
      return ForeignToolCall(
        id: (json['id'] ?? json['tool_use_id']) as String? ?? '',
        name: json['name'] as String? ?? '',
        arguments: arguments is Map<String, dynamic>
            ? arguments
            : const <String, dynamic>{},
        partialArguments: partial ?? (arguments is String ? arguments : null),
      );
    case 'image':
      return _parseForeignImage(json, resolveBlob);
    default:
      onSkip();
      return null;
  }
}

/// The bounded image rule (GOAL security section): blob references resolve
/// through [resolveBlob]; inline payloads (omp base64 or the claude
/// `source:{type:'base64',data,media_type}` shape) pass through when
/// decodable. Anything undecodable becomes a counted placeholder. The
/// declared mimeType is labeling only.
ForeignImage _parseForeignImage(
  Map<String, dynamic> json,
  ForeignImage? Function(String blobRef)? resolveBlob,
) {
  Object? data = json['data'];
  var mimeType = json['mimeType'];
  if (data == null) {
    final source = json['source'];
    if (source is Map<String, dynamic>) {
      data = source['data'];
      mimeType ??= source['media_type'];
    }
  }
  if (data is String && data.startsWith('blob:')) {
    final resolved = resolveBlob?.call(data);
    return resolved ?? ForeignImage.skipped('blob not found: $data');
  }
  final base64 = data is String ? _inlineBase64(data) : null;
  if (base64 == null) {
    return ForeignImage.skipped('undecodable image payload');
  }
  return ForeignImage(
    base64Data: base64,
    mimeType: mimeType as String? ?? 'image/png',
  );
}

/// Strips a data-URL header and validates the remainder is base64.
String? _inlineBase64(String data) {
  var payload = data;
  final header = RegExp(r'^data:[^;,]*(;base64)?,');
  final match = header.firstMatch(payload);
  if (match != null) {
    if (match.group(1) == null) return null;
    payload = payload.substring(match.end);
  }
  if (payload.isEmpty || !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(payload)) {
    return null;
  }
  return payload;
}

/// A missing store: the harness root does not exist at all (exit 2 class).
class ForeignStoreAbsent implements Exception {
  /// Creates [ForeignStoreAbsent].
  const ForeignStoreAbsent(this.root);

  /// The expected store root path.
  final String root;

  @override
  String toString() => 'no harness store at $root';
}

/// A read/parse failure for one foreign file (exit 3 class under --all,
/// with the reason shown).
class ForeignFileError implements Exception {
  /// Creates [ForeignFileError].
  const ForeignFileError(this.message);

  /// The human-readable reason (never file content).
  final String message;

  @override
  String toString() => message;
}
