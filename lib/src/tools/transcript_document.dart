/// The timestamped transcript document (schema v1) returned by
/// `transcribe_audio` in verbose mode — issue #1886.
///
/// A transcript is a document, not a prose blob: segments carry
/// start/end times in **seconds (double, finite, ≥ 0)**, and where the
/// endpoint supports it, per-word timings. Every structural invariant is
/// guaranteed by [buildTranscriptDocument] — callers never hand-assemble
/// segments, and no timestamp is ever synthesized: a timestamp in the
/// document either came from the provider payload or does not exist.
///
/// Invariants (all test-enforced, see `test/tools/transcript_document_test.dart`):
/// - segment and word starts are non-decreasing (violating entries are
///   dropped with a warning, never reordered);
/// - `start ≤ end` everywhere (violating entries are dropped);
/// - word ranges lie inside their segment's range (out-of-range words are
///   clamped and reported via a warning, never silently);
/// - concatenating segment text reproduces `text` up to whitespace;
/// - parsing is deterministic: identical payload bytes produce identical
///   documents (no clocks, no randomness).
library;

import 'dart:convert';

/// Machine-readable warning codes prepended to [TranscriptDocument.warnings]
/// entries.
const warningWordTimingsUnsupported = 'word-timings-unsupported';
const warningVerboseJsonUnsupported = 'verbose-json-unsupported';
const warningWordClamped = 'word-clamped';
const warningInvalidTimestampDropped = 'invalid-timestamp-dropped';
const warningTextMismatchRejoined = 'text-mismatch-rejoined';
const warningDurationOmitted = 'duration-invalid-omitted';

/// Schema version of [TranscriptDocument].
const transcriptSchemaVersion = 1;

/// Where a transcript came from. Carries no key material — only the host
/// name of the configured endpoint.
final class TranscriptSource {
  /// Creates a source record.
  const TranscriptSource({
    required this.providerKind,
    required this.modelId,
    required this.baseUrlHost,
  });

  /// Provider family label: `openai`, `groq`, or `custom`.
  final String providerKind;

  /// Transcription model id, e.g. `whisper-1`.
  final String modelId;

  /// Host name (no scheme, path, port credentials) of the endpoint.
  final String baseUrlHost;

  Map<String, dynamic> toMap() => {
    'providerKind': providerKind,
    'modelId': modelId,
    'baseUrlHost': baseUrlHost,
  };
}

/// One word timing inside a segment (or at document level when the endpoint
/// reports words without segments).
final class TranscriptWord {
  /// Creates a word. Callers go through [buildTranscriptDocument]; the
  /// constructor is public for deserialization only.
  const TranscriptWord({
    required this.word,
    required this.start,
    required this.end,
    this.confidence,
  });

  final String word;
  final double start;
  final double end;
  final double? confidence;

  Map<String, dynamic> toMap() => {
    'word': word,
    'start': start,
    'end': end,
    if (confidence != null) 'confidence': confidence,
  };
}

/// One timed segment of the transcript.
final class TranscriptSegment {
  /// Creates a segment. Callers go through [buildTranscriptDocument].
  const TranscriptSegment({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
    this.words,
  });

  final int id;
  final double start;
  final double end;
  final String text;

  /// Words lying inside `[start, end]`, or null when the endpoint provided
  /// none.
  final List<TranscriptWord>? words;

  Map<String, dynamic> toMap() => {
    'id': id,
    'start': start,
    'end': end,
    'text': text,
    if (words != null) 'words': [for (final w in words!) w.toMap()],
  };
}

/// The structured transcript (schema v1). Immutable; built only through
/// [buildTranscriptDocument] so every invariant holds by construction.
final class TranscriptDocument {
  /// Creates a document. Prefer [buildTranscriptDocument] — it validates the
  /// provider payload and guarantees the schema invariants.
  const TranscriptDocument({
    this.schemaVersion = transcriptSchemaVersion,
    required this.text,
    this.language,
    this.durationSeconds,
    required this.segments,
    this.words,
    required this.source,
    required this.warnings,
  });

  final int schemaVersion;
  final String text;
  final String? language;
  final double? durationSeconds;
  final List<TranscriptSegment> segments;

  /// Document-level words when the endpoint reported words but no segments.
  final List<TranscriptWord>? words;
  final TranscriptSource source;
  final List<String> warnings;

  /// Deterministic JSON serialization (schema v1 field order).
  Map<String, dynamic> toMap() => {
    'schemaVersion': schemaVersion,
    'text': text,
    if (language != null) 'language': language,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    'segments': [for (final s in segments) s.toMap()],
    if (words != null) 'words': [for (final w in words!) w.toMap()],
    'source': source.toMap(),
    'warnings': List.of(warnings),
  };

  /// Deterministic one-line JSON for inline tool results and sidecar files.
  String toJson() => jsonEncode(toMap());

  /// Whitespace-normalized form used by the text-fidelity invariant.
  static String normalizeWhitespace(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// True when [start]/[end] form a usable timestamp range: both numeric,
/// finite, non-negative, and ordered. The single validity predicate shared
/// by segment and word parsing (each condition carries a test).
bool _isValidRange(Object? start, Object? end) {
  if (start is! num || end is! num) return false;
  if (!start.isFinite || !end.isFinite) return false;
  if (start.isNegative || end.isNegative) return false;
  return start <= end;
}

/// Validates one raw provider segment (`{id?, start, end, text?}`).
/// Returns null (with a warning appended) when the entry is unusable.
TranscriptSegment? _parseSegment(
  Object? raw,
  int fallbackId,
  List<String> warnings,
) {
  if (raw is! Map<String, dynamic>) {
    warnings.add('$warningInvalidTimestampDropped: non-object segment entry');
    return null;
  }
  if (!_isValidRange(raw['start'], raw['end'])) {
    warnings.add(
      '$warningInvalidTimestampDropped: segment ${raw['id'] ?? fallbackId} '
      'has non-numeric/negative/NaN/reversed bounds',
    );
    return null;
  }
  return TranscriptSegment(
    id: raw['id'] is int ? raw['id'] as int : fallbackId,
    start: (raw['start'] as num).toDouble(),
    end: (raw['end'] as num).toDouble(),
    text: raw['text'] is String ? raw['text'] as String : '',
  );
}

/// Validates one raw provider word (`{word, start, end, confidence?}`).
TranscriptWord? _parseWord(Object? raw, List<String> warnings) {
  if (raw is! Map<String, dynamic>) {
    warnings.add('$warningInvalidTimestampDropped: non-object word entry');
    return null;
  }
  final text = raw['word'];
  if (text is! String || !_isValidRange(raw['start'], raw['end'])) {
    warnings.add(
      '$warningInvalidTimestampDropped: word entry with missing/invalid '
      'text or bounds',
    );
    return null;
  }
  final confidence = raw['confidence'];
  return TranscriptWord(
    word: text,
    start: (raw['start'] as num).toDouble(),
    end: (raw['end'] as num).toDouble(),
    confidence: confidence is num && confidence.isFinite
        ? confidence.toDouble()
        : null,
  );
}

/// Validates the raw provider segments and enforces the ordering
/// invariant: starts non-decreasing, offenders DROPPED (never sorted —
/// reordering would fabricate an ordering the provider did not report).
List<TranscriptSegment> _validatedSegments(
  List<Object?>? rawSegments,
  List<String> warnings,
) {
  final segments = <TranscriptSegment>[];
  var lastStart = -1.0;
  var nextId = 0;
  for (final raw in rawSegments ?? const <Object?>[]) {
    final segment = _parseSegment(raw, nextId, warnings);
    if (segment == null) continue;
    nextId++;
    if (lastStart >= 0 && segment.start < lastStart) {
      warnings.add(
        '$warningInvalidTimestampDropped: segment ${segment.id} starts '
        '(${segment.start}) before the previous segment ($lastStart)',
      );
      continue;
    }
    lastStart = segment.start;
    segments.add(segment);
  }
  return segments;
}

/// Validates the raw provider words against the ordering invariant (same
/// drop-don't-sort rule as the segments).
List<TranscriptWord> _validatedWords(
  List<Object?>? rawWords,
  List<String> warnings,
) {
  final words = <TranscriptWord>[];
  var lastWordStart = -1.0;
  for (final raw in rawWords ?? const <Object?>[]) {
    final word = _parseWord(raw, warnings);
    if (word == null) continue;
    if (lastWordStart >= 0 && word.start < lastWordStart) {
      warnings.add(
        '$warningInvalidTimestampDropped: word "${word.word}" starts '
        '(${word.start}) before the previous word ($lastWordStart)',
      );
      continue;
    }
    lastWordStart = word.start;
    words.add(word);
  }
  return words;
}

/// The nesting result: segments with their words attached, plus any words
/// that stay at document level (when the endpoint reported no segments,
/// E4).
final class _NestedTimings {
  _NestedTimings(this.segments, this.documentWords);
  final List<TranscriptSegment> segments;
  final List<TranscriptWord>? documentWords;
}

/// Nests validated words under the segments containing their start; a word
/// outside its segment's range is clamped with an explicit warning, never
/// silently (E4 keeps segment-less words at document level).
_NestedTimings _nestWords(
  List<TranscriptSegment> segments,
  List<TranscriptWord> words,
  List<String> warnings,
) {
  final wordsBySegment = <TranscriptSegment, List<TranscriptWord>>{};
  List<TranscriptWord>? documentWords;
  for (final word in words) {
    if (segments.isEmpty) {
      (documentWords ??= []).add(word);
      continue;
    }
    final host = _hostSegmentFor(segments, word.start);
    final clampedStart = word.start.clamp(host.start, host.end).toDouble();
    final clampedEnd = word.end.clamp(host.start, host.end).toDouble();
    if (clampedStart != word.start || clampedEnd != word.end) {
      warnings.add(
        '$warningWordClamped: word "${word.word}" '
        '[${word.start}, ${word.end}] outside segment ${host.id} '
        '[${host.start}, ${host.end}] — clamped',
      );
    }
    (wordsBySegment[host] ??= []).add(
      TranscriptWord(
        word: word.word,
        start: clampedStart,
        end: clampedEnd,
        confidence: word.confidence,
      ),
    );
  }
  return _NestedTimings(<TranscriptSegment>[
    for (final segment in segments)
      TranscriptSegment(
        id: segment.id,
        start: segment.start,
        end: segment.end,
        text: segment.text,
        words: wordsBySegment[segment],
      ),
  ], documentWords);
}

/// The text-fidelity invariant: segments must reproduce `text` up to
/// whitespace. A mismatch (possible after drops or from an inconsistent
/// endpoint) is repaired toward the invariant with an explicit warning —
/// the joined text is still provider data, nothing is synthesized.
String _resolvedText(
  String text,
  List<TranscriptSegment> segments,
  List<String> warnings,
) {
  final trimmed = text.trim();
  if (segments.isEmpty) return trimmed;
  final joined = TranscriptDocument.normalizeWhitespace(
    segments.map((s) => s.text).join(' '),
  );
  if (joined == TranscriptDocument.normalizeWhitespace(trimmed)) {
    return trimmed;
  }
  warnings.add(
    '$warningTextMismatchRejoined: provider text and segment '
    'concatenation disagreed up to whitespace; the segment concatenation '
    'is authoritative',
  );
  return segments.map((s) => s.text).join(' ');
}

/// Validates the payload duration: usable numbers pass, anything else is
/// omitted with a warning (missing duration is simply absent).
double? _resolvedDuration(Object? durationSeconds, List<String> warnings) {
  if (durationSeconds == null) return null;
  if (durationSeconds is! num || !durationSeconds.isFinite) {
    warnings.add('$warningDurationOmitted: non-finite duration');
    return null;
  }
  if (durationSeconds.isNegative) {
    warnings.add('$warningDurationOmitted: negative duration');
    return null;
  }
  return durationSeconds.toDouble();
}

/// Builds a validated [TranscriptDocument] from a verbose provider payload.
///
/// Malformed entries (non-finite/negative/`start > end` timestamps, missing
/// text) are dropped with machine-readable warnings — never reordered into
/// plausible-looking output, never fabricated. Words are nested under the
/// segment containing their start; a word outside its segment's range is
/// clamped with a [warningWordClamped] warning. When segment text does not
/// reproduce [text] up to whitespace, the document text becomes the segment
/// concatenation and a [warningTextMismatchRejoined] warning records it.
TranscriptDocument buildTranscriptDocument({
  required String text,
  required TranscriptSource source,
  String? language,
  Object? durationSeconds,
  List<Object?>? rawSegments,
  List<Object?>? rawWords,
  List<String> warnings = const [],
}) {
  final allWarnings = List.of(warnings);
  final segments = _validatedSegments(rawSegments, allWarnings);
  final words = _validatedWords(rawWords, allWarnings);
  final nested = _nestWords(segments, words, allWarnings);
  return TranscriptDocument(
    text: _resolvedText(text, nested.segments, allWarnings),
    language: language,
    durationSeconds: _resolvedDuration(durationSeconds, allWarnings),
    segments: nested.segments,
    words: nested.documentWords,
    source: source,
    warnings: allWarnings,
  );
}

/// The segment whose range contains [start]; the nearest one before it,
/// else the first segment. Deterministic; the caller clamps into the host.
/// Half-open containment wins first, so a word starting exactly at a
/// segment boundary nests under the LATER segment, not the earlier one.
TranscriptSegment _hostSegmentFor(
  List<TranscriptSegment> segments,
  double start,
) {
  for (final segment in segments) {
    if (start >= segment.start && start < segment.end) return segment;
  }
  for (final segment in segments) {
    if (start >= segment.start && start <= segment.end) return segment;
  }
  TranscriptSegment? nearest;
  for (final segment in segments) {
    if (segment.start <= start) nearest = segment;
  }
  return nearest ?? segments.first;
}

/// Parses an OpenAI-family `verbose_json` payload into a document. The
/// strict parse for the OpenAI/Groq adapter family: known fields, typed
/// validation through [buildTranscriptDocument]; unknown fields are
/// ignored, unknown SHAPES (non-map payloads) are the caller's error.
TranscriptDocument parseVerboseTranscriptionPayload({
  required Map<String, dynamic> payload,
  required TranscriptSource source,
  List<String> warnings = const [],
}) {
  return buildTranscriptDocument(
    text: payload['text'] is String ? payload['text'] as String : '',
    language: payload['language'] is String
        ? payload['language'] as String
        : null,
    durationSeconds: payload['duration'],
    rawSegments: payload['segments'] as List<Object?>?,
    rawWords: payload['words'] as List<Object?>?,
    warnings: warnings,
    source: source,
  );
}
