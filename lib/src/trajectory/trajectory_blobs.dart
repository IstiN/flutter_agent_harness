/// Content-addressed blobs behind the trajectory's request drill-in
/// (issue #385).
///
/// The ledger keeps per-request SUMMARIES (sizes, previews, names); the
/// full outbound reality — system-prompt text, tool manifests with
/// descriptions and schemas, and the opt-in raw wire dump — lives in
/// per-session blobs keyed by a content hash. A unique prompt or manifest
/// version is stored ONCE no matter how many requests carried it, so a
/// 30k-record session with a handful of prompt edits pays bytes, not
/// payload-per-request (the #262 open gate stays load-bearing).
///
/// Pure data + pure functions: no IO, no builder state. Hosts persist the
/// blobs as `trajectory_prompt_blob` / `trajectory_manifest_blob` /
/// `trajectory_wire_dump` custom records (deduped through
/// [TrajectoryBlobPersister]); the snapshot builder folds them back into
/// [TrajectoryBlobTable]s for the renderers.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../context.dart';
import '../types.dart';
import 'trajectory_record.dart';

/// Character bound of one tool schema inside a manifest blob (E3).
const int toolSchemaMaxChars = 2048;

/// Character bound of one request-message block's full text (F3) —
/// generous (vs the 200-char single-line preview) but bounded.
const int requestBlockChars = 8192;

/// Character cap of a persisted wire dump (F5). The payload is cut at the
/// cap with a truncation marker; only wire dumps are capped — system
/// prompts and manifests are not (E2).
const int wireDumpMaxChars = 2 * 1024 * 1024;

/// Marker appended to a wire dump cut at [wireDumpMaxChars].
const String wireDumpTruncationMarker =
    '\n…[wire dump truncated at $wireDumpMaxChars chars]';

/// Stable content hash of [text]: two independent 32-bit FNV-1a lanes
/// (different basis/primes) over the UTF-8 bytes, hex-encoded as 16
/// characters. Not a security primitive — a dedup key for blob tables.
/// Two lanes instead of one 64-bit hash because 64-bit literals cannot be
/// represented exactly under dart2js (web builds).
String trajectoryContentHash(String text) {
  var hi = 0x811c9dc5;
  var lo = 0x811c9dc5;
  for (final byte in utf8.encode(text)) {
    hi = ((hi ^ byte) * 0x01000193) & 0xFFFFFFFF;
    lo = ((lo ^ byte) * 0x01935619) & 0xFFFFFFFF;
  }
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

/// One full system-prompt version (F1). The text is stored whole — no cap
/// (E2: a giant AGENTS.md merge is exactly the case worth auditing).
final class TrajectoryPromptBlob {
  /// Creates a prompt blob.
  const TrajectoryPromptBlob({required this.hash, required this.text});

  /// Content hash of [text] ([trajectoryContentHash]).
  final String hash;

  /// The full prompt text.
  final String text;

  /// The blob for [text].
  factory TrajectoryPromptBlob.of(String text) =>
      TrajectoryPromptBlob(hash: trajectoryContentHash(text), text: text);

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {'hash': hash, 'text': text};

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryPromptBlob.fromJson(Map<String, dynamic> json) =>
      TrajectoryPromptBlob(
        hash: json['hash'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );
}

/// One tool of a manifest blob: the manifest is exactly what the `tools`
/// array of the request carried (F2).
final class TrajectoryToolManifestEntry {
  /// Creates a manifest entry.
  const TrajectoryToolManifestEntry({
    required this.name,
    required this.description,
    required this.schemaJson,
    required this.schemaChars,
    required this.schemaTruncated,
  });

  /// The tool's name.
  final String name;

  /// The tool's description, whole.
  final String description;

  /// Pretty-printed JSON Schema, bounded to [toolSchemaMaxChars] (E3: an
  /// oversized or unparseable schema degrades to a bounded placeholder,
  /// never a crash).
  final String schemaJson;

  /// Original schema size in characters.
  final int schemaChars;

  /// Whether [schemaJson] was cut at the bound.
  final bool schemaTruncated;

  /// The entry for [tool].
  factory TrajectoryToolManifestEntry.of(Tool tool) {
    final schema = const JsonEncoder.withIndent('  ').convert(tool.parameters);
    final truncated = schema.length > toolSchemaMaxChars;
    return TrajectoryToolManifestEntry(
      name: tool.name,
      description: tool.description,
      schemaJson: truncated ? schema.substring(0, toolSchemaMaxChars) : schema,
      schemaChars: schema.length,
      schemaTruncated: truncated,
    );
  }

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'schemaJson': schemaJson,
    'schemaChars': schemaChars,
    'schemaTruncated': schemaTruncated,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryToolManifestEntry.fromJson(Map<String, dynamic> json) =>
      TrajectoryToolManifestEntry(
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        schemaJson: json['schemaJson'] as String? ?? '',
        schemaChars: json['schemaChars'] as int? ?? 0,
        schemaTruncated: json['schemaTruncated'] as bool? ?? false,
      );
}

/// One full tool-manifest version (F2), content-addressed over the
/// serialized entries so equal tool sets dedup.
final class TrajectoryToolManifestBlob {
  /// Creates a manifest blob.
  const TrajectoryToolManifestBlob({required this.hash, required this.tools});

  /// Content hash of the serialized entries.
  final String hash;

  /// The tools, in request order.
  final List<TrajectoryToolManifestEntry> tools;

  /// The blob for [tools].
  factory TrajectoryToolManifestBlob.of(List<Tool> tools) {
    final entries = [
      for (final tool in tools) TrajectoryToolManifestEntry.of(tool),
    ];
    return TrajectoryToolManifestBlob(
      hash: trajectoryContentHash(jsonEncode(entries)),
      tools: entries,
    );
  }

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'hash': hash,
    'tools': [for (final tool in tools) tool.toJson()],
  };
  factory TrajectoryToolManifestBlob.fromJson(Map<String, dynamic> json) =>
      TrajectoryToolManifestBlob(
        hash: json['hash'] as String? ?? '',
        tools: [
          for (final tool in (json['tools'] as List?) ?? const [])
            TrajectoryToolManifestEntry.fromJson(
              (tool as Map).cast<String, dynamic>(),
            ),
        ],
      );
}

/// Host-side persistence helper for request blobs (issue #385): turns one
/// outbound-request capture into the custom records to append, in chain
/// order — unseen prompt blob, unseen manifest blob, wire dump (when the
/// request carries a raw one), then the `model_request_summary` with its
/// pointers. Per-session instance: the seen-hash sets implement the F1/F2
/// dedup (a unique prompt or manifest version is persisted ONCE).
final class TrajectoryBlobPersister {
  /// Creates a persister. [redact] is the host's active pipeline pass
  /// (E1: each dump is redacted under the config active at capture time);
  /// wire dumps are capped at [maxWireDumpChars].

  final String Function(String)? _redact;

  /// Wire-dump character cap (tests shrink it).
  final int maxWireDumpChars;
  TrajectoryBlobPersister({
    String Function(String)? redactText,
    this.maxWireDumpChars = wireDumpMaxChars,
  }) : _redact = redactText;

  final Set<String> _seenPrompts = {};
  final Set<String> _seenManifests = {};

  /// The last request-context version the host turned into a
  /// `model_change` record (issue #440): the (prompt, manifest) hash
  /// pair. Records are structural, so equality is the content address.
  (String?, String?)? _lastModelChangePair;

  /// Drops the seen-hash state (new session).
  void reset() {
    _seenPrompts.clear();
    _seenManifests.clear();
    _lastModelChangePair = null;
  }

  /// The records for one request, in chain order.
  List<({String customType, Map<String, dynamic> data})> recordsFor(
    TrajectoryRequestDetail detail, {
    TrajectoryPromptBlob? promptBlob,
    TrajectoryToolManifestBlob? manifestBlob,
    String? rawWireDump,
  }) {
    final records = <({String customType, Map<String, dynamic> data})>[];
    if (promptBlob != null && _seenPrompts.add(promptBlob.hash)) {
      records.add((
        customType: 'trajectory_prompt_blob',
        data: promptBlob.toJson(),
      ));
    }
    if (manifestBlob != null && _seenManifests.add(manifestBlob.hash)) {
      records.add((
        customType: 'trajectory_manifest_blob',
        data: manifestBlob.toJson(),
      ));
    }
    var summary = detail.toJson();
    if (rawWireDump != null) {
      final dump = trajectoryBuildWireDump(rawWireDump, redact: _redact);
      records.add((customType: 'trajectory_wire_dump', data: dump.toJson()));
      summary = {...summary, 'wireDumpHash': dump.hash};
    }
    records.add((customType: 'model_request_summary', data: summary));
    return records;
  }

  /// Whether [detail] opens a new request-context version (issue #440):
  /// the host appends a `model_change` record — the trajectory's System
  /// row, which the request summary that follows on the chain stamps
  /// with the blob pointers (F7a) — whenever the effective system-prompt
  /// or tool-manifest hash changed. Content-addressed like the blob
  /// dedup: once per version run, never per request. A fully uncaptured
  /// request (both hashes null, E6) is not a version and never lands a
  /// row.
  bool shouldAppendModelChange(TrajectoryRequestDetail detail) {
    final pair = (detail.systemPromptHash, detail.toolManifestHash);
    if (pair.$1 == null && pair.$2 == null) return false;
    if (_lastModelChangePair == pair) return false;
    _lastModelChangePair = pair;
    return true;
  }
}

/// One opt-in raw wire dump (F5): the exact outbound request payload,
/// redacted and capped before persist. Keyed by the dump's own content
/// hash; the request summary points at it via `wireDumpHash`.
final class TrajectoryWireDump {
  /// Creates a wire dump.
  const TrajectoryWireDump({
    required this.hash,
    required this.payload,
    required this.truncated,
  });

  /// Content hash of [payload] (post-redaction, post-cap).
  final String hash;

  /// The redacted outbound JSON, whole or cut at [wireDumpMaxChars].
  final String payload;

  /// Whether [payload] was cut at the cap ([wireDumpTruncationMarker]).
  final bool truncated;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'hash': hash,
    'payload': payload,
    'truncated': truncated,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryWireDump.fromJson(Map<String, dynamic> json) =>
      TrajectoryWireDump(
        hash: json['hash'] as String? ?? '',
        payload: json['payload'] as String? ?? '',
        truncated: json['truncated'] as bool? ?? false,
      );
}

/// The per-session blob table: hash → blob for each blob kind, folded from
/// the session's blob records. Renderers resolve request pointers
/// (`systemPromptHash` etc.) through it; entries not present mean "not
/// captured for this session" (E6) — old sessions render exactly as today.
final class TrajectoryBlobTable {
  /// Creates a blob table.
  const TrajectoryBlobTable({
    this.systemPrompts = const {},
    this.toolManifests = const {},
    this.wireDumps = const {},
  });

  /// System-prompt versions by hash, insertion-ordered (first capture
  /// first) so "previous version" resolves deterministically.
  final Map<String, TrajectoryPromptBlob> systemPrompts;

  /// Tool-manifest versions by hash.
  final Map<String, TrajectoryToolManifestBlob> toolManifests;

  /// Opt-in wire dumps by hash.
  final Map<String, TrajectoryWireDump> wireDumps;

  /// Whether nothing was ever captured (E6 honesty check).
  bool get isEmpty =>
      systemPrompts.isEmpty && toolManifests.isEmpty && wireDumps.isEmpty;

  /// The table plus [blob] (an equal hash is a no-op — dedup).
  TrajectoryBlobTable withPromptBlob(TrajectoryPromptBlob blob) =>
      systemPrompts.containsKey(blob.hash)
      ? this
      : TrajectoryBlobTable(
          systemPrompts: {...systemPrompts, blob.hash: blob},
          toolManifests: toolManifests,
          wireDumps: wireDumps,
        );

  /// The table plus [blob] (an equal hash is a no-op — dedup).
  TrajectoryBlobTable withManifestBlob(TrajectoryToolManifestBlob blob) =>
      toolManifests.containsKey(blob.hash)
      ? this
      : TrajectoryBlobTable(
          systemPrompts: systemPrompts,
          toolManifests: {...toolManifests, blob.hash: blob},
          wireDumps: wireDumps,
        );

  /// The table plus [dump] (an equal hash is a no-op — dedup).
  TrajectoryBlobTable withWireDump(TrajectoryWireDump dump) =>
      wireDumps.containsKey(dump.hash)
      ? this
      : TrajectoryBlobTable(
          systemPrompts: systemPrompts,
          toolManifests: toolManifests,
          wireDumps: {...wireDumps, dump.hash: dump},
        );

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'systemPrompts': [for (final blob in systemPrompts.values) blob.toJson()],
    'toolManifests': [for (final blob in toolManifests.values) blob.toJson()],
    'wireDumps': [for (final dump in wireDumps.values) dump.toJson()],
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryBlobTable.fromJson(Map<String, dynamic> json) {
    TrajectoryPromptBlob prompt(Map raw) =>
        TrajectoryPromptBlob.fromJson(raw.cast<String, dynamic>());
    TrajectoryToolManifestBlob manifest(Map raw) =>
        TrajectoryToolManifestBlob.fromJson(raw.cast<String, dynamic>());
    TrajectoryWireDump dump(Map raw) =>
        TrajectoryWireDump.fromJson(raw.cast<String, dynamic>());
    return TrajectoryBlobTable(
      systemPrompts: {
        for (final raw
            in ((json['systemPrompts'] as List?) ?? const []).cast<Map>())
          prompt(raw).hash: prompt(raw),
      },
      toolManifests: {
        for (final raw
            in ((json['toolManifests'] as List?) ?? const []).cast<Map>())
          manifest(raw).hash: manifest(raw),
      },
      wireDumps: {
        for (final raw
            in ((json['wireDumps'] as List?) ?? const []).cast<Map>())
          dump(raw).hash: dump(raw),
      },
    );
  }
}

/// One line of a bounded text diff (the section that changed, with a few
/// context lines on each side).
final class TrajectoryDiffLine {
  /// Creates a diff line.
  const TrajectoryDiffLine(this.kind, this.text);

  /// `context`, `added`, `removed`, or `ellipsis`.
  final String kind;

  /// The line's text (unprefixed — renderers own the sign).
  final String text;
}

/// Trims the common prefix/suffix of two line lists (issue #385 AC2),
/// returning the changed range — the walk half of
/// [trajectoryPromptDiff], split out to keep both halves simple.
({int start, int beforeEnd, int afterEnd}) _diffChangedRange(
  List<String> beforeLines,
  List<String> afterLines,
) {
  var start = 0;
  while (start < beforeLines.length &&
      start < afterLines.length &&
      beforeLines[start] == afterLines[start]) {
    start++;
  }
  var beforeEnd = beforeLines.length;
  var afterEnd = afterLines.length;
  while (beforeEnd > start &&
      afterEnd > start &&
      beforeLines[beforeEnd - 1] == afterLines[afterEnd - 1]) {
    beforeEnd--;
    afterEnd--;
  }
  return (start: start, beforeEnd: beforeEnd, afterEnd: afterEnd);
}

/// Minimal unified-style line diff between two prompt versions (AC2): the
/// common prefix/suffix is trimmed, the middle renders as one changed
/// block, up to 3 context lines flank it, and collapsed ranges show an
/// `ellipsis` line. Pure — the UI tab and the CLI mirror share it.
List<TrajectoryDiffLine> trajectoryPromptDiff(String before, String after) {
  if (before == after) return const [];
  final beforeLines = before.split('\n');
  final afterLines = after.split('\n');
  final (:start, :beforeEnd, :afterEnd) = _diffChangedRange(
    beforeLines,
    afterLines,
  );
  const context = 3;

  final lines = <TrajectoryDiffLine>[];
  void contextRange(int from, int to, List<String> source) {
    for (var i = from; i < to; i++) {
      lines.add(TrajectoryDiffLine('context', source[i]));
    }
  }

  final contextStart = start > context ? start - context : 0;
  if (contextStart > 0) lines.add(const TrajectoryDiffLine('ellipsis', '…'));
  contextRange(contextStart, start, beforeLines);
  for (var i = start; i < beforeEnd; i++) {
    lines.add(TrajectoryDiffLine('removed', beforeLines[i]));
  }
  for (var i = start; i < afterEnd; i++) {
    lines.add(TrajectoryDiffLine('added', afterLines[i]));
  }
  final contextEnd = beforeLines.length - beforeEnd > context
      ? beforeEnd + context
      : beforeLines.length;
  contextRange(beforeEnd, contextEnd, beforeLines);
  if (contextEnd < beforeLines.length) {
    lines.add(const TrajectoryDiffLine('ellipsis', '…'));
  }
  return lines;
}

/// The tool-set diff between two manifest versions (F2): names only —
/// renderers pull descriptions/schemas from the blobs.
({List<String> added, List<String> removed, List<String> modified})
trajectoryToolManifestDiff(
  TrajectoryToolManifestBlob? before,
  TrajectoryToolManifestBlob? after,
) {
  if (before == null || after == null) {
    return (added: const [], removed: const [], modified: const []);
  }
  final beforeByName = {for (final tool in before.tools) tool.name: tool};
  final afterByName = {for (final tool in after.tools) tool.name: tool};
  return (
    added: [
      for (final tool in after.tools)
        if (!beforeByName.containsKey(tool.name)) tool.name,
    ],
    removed: [
      for (final tool in before.tools)
        if (!afterByName.containsKey(tool.name)) tool.name,
    ],
    modified: [
      for (final tool in after.tools)
        if (beforeByName[tool.name] != null &&
            beforeByName[tool.name]!.schemaJson != tool.schemaJson)
          tool.name,
    ],
  );
}

/// Builds the raw wire-dump payload for a request (F5): the outbound
/// context as JSON with base64 image bytes replaced by
/// `[dump: image omitted]` markers (E5). RAW — the host redacts through
/// its [RedactionPipeline] and caps through [trajectoryCapWireDump]
/// before persisting.
String trajectoryWireDumpPayload(Context context) {
  Map<String, dynamic> messageJson(Message message) {
    final json = message.toJson();
    final content = json['content'];
    if (content is List) {
      json['content'] = [for (final block in content) _dumpBlock(block)];
    }
    return json;
  }

  // The toEncodable fallback keeps the capture crash-free (issue #385 E3):
  // an unserializable argument value degrades to a placeholder in place.
  return const JsonEncoder.withIndent('  ', _unserializableFallback).convert({
    if (context.systemPrompt != null) 'systemPrompt': context.systemPrompt,
    'messages': [for (final message in context.messages) messageJson(message)],
    if (context.tools != null)
      'tools': [for (final tool in context.tools!) tool.toJson()],
  });
}

/// Replaces base64 image payloads in one serialized content block with an
/// omission marker (E5).
Object _dumpBlock(Object block) {
  if (block is Map && block['type'] == 'image' && block['data'] is String) {
    return {...block.cast<String, dynamic>(), 'data': '[dump: image omitted]'};
  }
  return block;
}

/// Applies the wire-dump cap: payloads beyond [maxChars] are cut and carry
/// [wireDumpTruncationMarker] (F5 cap enforcement). Returns the capped
/// payload plus whether it was cut.
(String, bool) trajectoryCapWireDump(
  String payload, {
  int maxChars = wireDumpMaxChars,
}) {
  if (payload.length <= maxChars) return (payload, false);
  return ('${payload.substring(0, maxChars)}$wireDumpTruncationMarker', true);
}

/// Builds a wire dump record payload from the raw request JSON: redacts
/// through [redact] (the host's active pipeline — E1: each dump is
/// redacted under the config active at capture time), then caps. Returns
/// the finished [TrajectoryWireDump].
TrajectoryWireDump trajectoryBuildWireDump(
  String rawPayload, {
  String Function(String)? redact,
}) {
  final redacted = redact == null ? rawPayload : redact(rawPayload);
  final (payload, truncated) = trajectoryCapWireDump(redacted);
  return TrajectoryWireDump(
    hash: trajectoryContentHash(payload),
    payload: payload,
    truncated: truncated,
  );
}

/// One parsed content block of an outbound request message (F3): block
/// structure with a generous bounded full text and `[image WxH]` markers.
final class TrajectoryRequestMessageBlock {
  /// Creates a request message block.
  const TrajectoryRequestMessageBlock({
    required this.type,
    required this.chars,
    required this.text,
    this.truncated = false,
    this.imageMarker,
    this.callId,
    this.toolName,
  });

  /// Block type discriminator (`text`, `thinking`, `toolCall`, `image`).
  final String type;

  /// Original payload size in characters.
  final int chars;

  /// Bounded full text ([requestBlockChars]); empty for images.
  final String text;

  /// Whether [text] was cut at the bound.
  final bool truncated;

  /// `[image WxH]` marker for image blocks (dimensions decoded from the
  /// payload header when possible, `?x?` otherwise).
  final String? imageMarker;

  /// Tool call id for `toolCall` blocks.
  final String? callId;

  /// Tool name for `toolCall` blocks.
  final String? toolName;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'type': type,
    'chars': chars,
    'text': text,
    if (truncated) 'truncated': true,
    if (imageMarker != null) 'imageMarker': imageMarker,
    if (callId != null) 'callId': callId,
    if (toolName != null) 'toolName': toolName,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryRequestMessageBlock.fromJson(Map<String, dynamic> json) =>
      TrajectoryRequestMessageBlock(
        type: json['type'] as String? ?? '',
        chars: json['chars'] as int? ?? 0,
        text: json['text'] as String? ?? '',
        truncated: json['truncated'] as bool? ?? false,
        imageMarker: json['imageMarker'] as String?,
        callId: json['callId'] as String?,
        toolName: json['toolName'] as String?,
      );
}

/// The request-message blocks for one outbound message (F3): block
/// structure in model order with bounded full texts and image markers.
/// [JsonEncoder] `toEncodable` fallback: values JSON cannot represent
/// degrade to a placeholder instead of throwing (issue #385 E3).
Object? _unserializableFallback(Object? value) => '[unserializable]';

/// [jsonEncode] that never throws (cyclic/unserializable values degrade
/// to a placeholder).
String _safeJsonEncode(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '[unserializable]';
  }
}

List<TrajectoryRequestMessageBlock> trajectoryRequestBlocks(
  List<ContentBlock> content,
) => [
  for (final block in content)
    switch (block) {
      TextContent(:final text) => _boundedBlock('text', text),
      ThinkingContent(:final thinking) => _boundedBlock('thinking', thinking),
      ToolCall() => () {
        // Unserializable arguments (cyclic handles, raw objects) degrade to
        // the placeholder instead of crashing the capture (issue #385 E3).
        final args = block.partialArguments ?? _safeJsonEncode(block.arguments);
        final (bounded, truncated) = _bound(args);
        return TrajectoryRequestMessageBlock(
          type: 'toolCall',
          chars: _safeJsonEncode(block.arguments).length,
          text: bounded,
          truncated: truncated,
          callId: block.id,
          toolName: block.name,
        );
      }(),
      ImageContent(:final data, :final mimeType) =>
        TrajectoryRequestMessageBlock(
          type: 'image',
          chars: data.length,
          text: '',
          imageMarker: '[image ${_imageDimensions(data, mimeType)}]',
        ),
    },
];

TrajectoryRequestMessageBlock _boundedBlock(String type, String text) {
  final (bounded, truncated) = _bound(text);
  return TrajectoryRequestMessageBlock(
    type: type,
    chars: text.length,
    text: bounded,
    truncated: truncated,
  );
}

(String, bool) _bound(String text) => text.length <= requestBlockChars
    ? (text, false)
    : ('${text.substring(0, requestBlockChars)}…', true);

/// Decodes image dimensions from the payload header: PNG IHDR and JPEG SOF
/// frames are parsed; anything else reports `?x?` (never a crash).
String _imageDimensions(String base64Data, String mimeType) {
  final Uint8List bytes;
  try {
    bytes = base64.decode(
      base64Data.length > 65536 ? base64Data.substring(0, 65536) : base64Data,
    );
  } on FormatException {
    return '?x?'; // Corrupt capture: the marker degrades, never crashes.
  }
  if (mimeType.contains('png')) return _pngDimensions(bytes);
  if (mimeType.contains('jpeg') || mimeType.contains('jpg')) {
    return _jpegDimensions(bytes);
  }
  return '?x?';
}

/// PNG IHDR width/height (bytes 16..23), or `?x?` when the capture is
/// shorter than the header.
String _pngDimensions(Uint8List bytes) {
  if (bytes.length < 24) return '?x?';
  final width =
      (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
  final height =
      (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
  return '${width}x$height';
}

/// Walks JPEG SOF segment markers for the frame dimensions (E3: a
/// truncated or foreign payload reports `?x?` — never a crash).
String _jpegDimensions(Uint8List bytes) {
  var i = 2;
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xFF) break;
    final marker = bytes[i + 1];
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (_isJpegSofMarker(marker)) {
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      return '${width}x$height';
    }
    i += 2 + length;
  }
  return '?x?';
}

/// SOF0–SOF15 minus the non-frame markers (DHT, JPG, DAC).
bool _isJpegSofMarker(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;
