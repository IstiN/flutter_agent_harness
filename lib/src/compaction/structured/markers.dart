/// Placeholder markers for the compaction engines (issues #148, #195).
///
/// Hidden/compacted segments render as one-line plain-text markers inline
/// at their original position (`[3:hidden·tool_result·4.2k]`,
/// `[2-6:ckpt·38k→40tok·covers:3,5]`). Markers are provider-agnostic
/// plain text — no new wire features.
///
/// Owner pin (D2): the marker's ADDRESSING part (id + kind + size +
/// framing) MUST cost ≤ ~12 tokens all-in so addressing never becomes the
/// new bloat; `UT-marker-budget` enforces it with the production chars/4
/// heuristic. Issue #266 F4 adds a bounded one-line content preview after
/// the size — decision support so the agent expands on purpose, not on
/// spec — capped at [markerPreviewChars] by [markerPreview].
library;

import '../token_estimation.dart' show estimatedImageChars;

/// Formats a token count for a marker: plain below a thousand, one decimal
/// below ten thousand, integer thousands above (`812`, `4.2k`, `38k`).
String formatMarkerTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 10000) {
    final k = (tokens / 1000).toStringAsFixed(1);
    return '${k.endsWith('.0') ? k.substring(0, k.length - 2) : k}k';
  }
  return '${(tokens / 1000).round()}k';
}

/// Maximum characters of a marker's content preview (issue #266 F4).
const markerPreviewChars = 80;

final RegExp _whitespaceRuns = RegExp(r'\s+');

/// Bounded one-line preview of a record's content (issue #266 F4): first
/// line only, whitespace-collapsed, capped at [markerPreviewChars] with a
/// trailing `…` when cut — the same slice-collapse-cap pipeline as
/// `trajectoryPreviewText`, sized for a marker.
///
/// A cut never lands inside a `[REDACTED:…]` token (E4): when the cap
/// would split one, the preview backs off to before the token instead.
String markerPreview(String content) {
  final line = content
      .split('\n')
      .first
      .replaceAll(_whitespaceRuns, ' ')
      .trim();
  if (line.length <= markerPreviewChars) return line;
  var cut = line.substring(0, markerPreviewChars);
  final redacted = cut.indexOf('[REDACTED:');
  if (redacted >= 0 && !cut.contains(']', redacted)) {
    cut = line.substring(0, redacted);
  }
  return '${cut.trimRight()}…';
}

/// Kind-named placeholder for image content (E3): the mime plus the
/// chars/4 estimate — never the base64 payload.
String imagePreview(String mimeType) =>
    '$mimeType, ${estimatedImageChars ~/ 4} tokens est.';

/// The kind labels shown in hidden markers.
const markerKinds = (
  user: 'user',
  notice: 'notice',
  assistant: 'assistant',
  toolResult: 'tool_result',
  checkpoint: 'ckpt',
  legacyCheckpoint: 'legacy-ckpt',
  branchSummary: 'branch-summary',
);

/// The marker for one hidden record: `[3:hidden·tool_result·4.2k]`, plus
/// the bounded content preview when one is known (issue #266 F4):
/// `[3:hidden·tool_result·4.2k·"first line…"]`.
String hiddenMarker({
  required int seq,
  required String kind,
  required int tokens,
  String? preview,
}) {
  final tail = preview == null || preview.isEmpty ? '' : '·"$preview"';
  return '[$seq:hidden·$kind·${formatMarkerTokens(tokens)}$tail]';
}

/// The marker header for a compact checkpoint:
/// `[2-6:ckpt·38k→40tok·covers:3,5]` — the expand id IS the range, `38k`
/// is what the range used to cost, `40tok` what the checkpoint text
/// costs now.
String checkpointMarkerHeader({
  required int startSeq,
  required int endSeq,
  required int coveredTokens,
  required int textTokens,
  required String coversRanges,
}) {
  final range = startSeq == endSeq ? '$startSeq' : '$startSeq-$endSeq';
  return '[$range:ckpt·${formatMarkerTokens(coveredTokens)}→'
      '${formatMarkerTokens(textTokens)}tok·covers:$coversRanges]';
}

/// Compacts sorted numeric ids into range notation: `3,5,7-8,12`.
String idsToRanges(Iterable<int> ids) {
  final sorted = [...ids]..sort();
  final parts = <String>[];
  var start = -1;
  var prev = -1;
  void flush() {
    if (start < 0) return;
    parts.add(start == prev ? '$start' : '$start-$prev');
    start = -1;
  }

  for (final value in sorted) {
    if (start >= 0 && value == prev + 1) {
      prev = value;
    } else {
      flush();
      start = value;
      prev = value;
    }
  }
  flush();
  return parts.join(',');
}

/// The opener of the local trim valve's marker (issue #171/#195): the
/// in-memory valve prepends this note when it drops older messages
/// without a summarizer (see `AutoCompactor._localTrimFallback`).
const localTrimMarkerPrefix = '[context trimmed locally:';

final RegExp _markerTextPattern = RegExp(r'^\[\d+(?:-\d+)?:(?:hidden|ckpt)·');

/// Whether [text] opens like a projected hidden/checkpoint marker line —
/// `[3:hidden·user·12]` or `[2-6:ckpt·38k→40tok·covers:3,5]`.
///
/// The image registry uses this to detect that the window was renumbered
/// at some point (issue #195 F2): hidden history may have carried images
/// whose first-seen indexes the surviving citations still name.
bool isCompactionMarkerText(String text) => _markerTextPattern.hasMatch(text);
