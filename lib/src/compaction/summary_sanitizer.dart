/// Time-scoped claim sanitizer for compaction summaries (issue #1131).
///
/// A compaction summary is a durable fact sheet re-rendered into the model
/// context on every later turn. An ephemeral observation written at fold
/// time — "your LAST tool call's RESULT was dropped from context" — therefore
/// re-renders forever as a current fact: the claim was true once (a harness
/// context note about a real one-shot drop) but persists as standing prose
/// the model re-verifies every turn. The summarizer prompts forbid such
/// claims (see `prompts/compaction/*.md`); this sanitizer is the belt next
/// to that suspender — ephemeral sentences are stripped before a summary is
/// persisted or projected into context, so pre-existing poisoned summaries
/// heal on read too (session JSONL stays untouched).
///
/// The pattern is deliberately narrow — a bracketed `[context note …]` /
/// `[CONTEXT NOTE — …]` block, or a sentence addressing the reader in the
/// second person WHILE claiming recency or a drop — so durable uses of
/// temporal words survive: "the last release was v1.0.492", "the current
/// maintainer is X", and quoted history like "the user asked you to re-run
/// the tests" all stay verbatim.
library;

/// A summary after sanitization: the cleaned [text] plus the [stripped]
/// ephemeral sentences (persist sites log them, e.g. in the compaction
/// record's `details`).
typedef SanitizedSummary = ({String text, List<String> stripped});

final RegExp _contextNoteOpen = RegExp(
  r'\[?\s*context notes?\s*[—–\-:]',
  caseSensitive: false,
);

final RegExp _secondPerson = RegExp(
  r'\b(?:you|your|yours|yourself)\b',
  caseSensitive: false,
);

final RegExp _recencyOrDrop = RegExp(
  r'\b(?:dropped?|dropping|just|currently|about to|last|previous|prior)\b',
  caseSensitive: false,
);

/// Strips ephemeral, time-scoped claims from a compaction [summary].
///
/// Whole `[context note …]` blocks go first (the harness delivers drop notes
/// itself, once, at the turn where they happen — a copy inside a summary is
/// always the stale-re-render class). Then any sentence that both addresses
/// the reader in the second person and claims recency or a drop is removed.
/// Everything else survives byte-identical.
SanitizedSummary sanitizeSummary(String summary) {
  if (summary.isEmpty) return (text: summary, stripped: const []);
  final stripped = <String>[];
  final text = _stripContextNotes(summary, stripped);
  final keptLines = <String>[];
  for (final line in text.split('\n')) {
    final keptLine = _sanitizeLine(line, stripped);
    if (keptLine != null) keptLines.add(keptLine);
  }
  return (text: keptLines.join('\n'), stripped: stripped);
}

/// Removes every `[context note …]` block (to its closing `]`, or to the end
/// of the text when unterminated), recording the removed spans as stripped.
String _stripContextNotes(String text, List<String> stripped) {
  final out = StringBuffer();
  var start = 0;
  for (final match in _contextNoteOpen.allMatches(text)) {
    if (match.start < start) continue; // opener inside a removed block
    out.write(text.substring(start, match.start));
    final close = text.indexOf(']', match.end);
    final end = close < 0 ? text.length : close + 1;
    final removed = text.substring(match.start, end);
    if (removed.trim().isNotEmpty) stripped.add(removed.trim());
    if (close < 0) return out.toString();
    start = end;
  }
  out.write(text.substring(start));
  return out.toString();
}

/// Strips ephemeral sentences from one [line]; `null` when nothing survives
/// (the line carried only ephemeral content and is dropped whole).
String? _sanitizeLine(String line, List<String> stripped) {
  final sentences = line.split(RegExp(r'(?<=[.!?])\s+'));
  final kept = <String>[];
  for (final sentence in sentences) {
    if (_secondPerson.hasMatch(sentence) && _recencyOrDrop.hasMatch(sentence)) {
      if (sentence.trim().isNotEmpty) stripped.add(sentence.trim());
      continue;
    }
    kept.add(sentence);
  }
  if (kept.length == sentences.length) return line;
  if (kept.isEmpty) return null;
  final text = kept.join(' ');
  // A partially stripped bullet keeps its marker so the list stays valid.
  final bullet = RegExp(r'^(\s*(?:[-*+]|\d+\.)\s+)');
  if (bullet.hasMatch(line) && !bullet.hasMatch(text)) {
    return bullet.firstMatch(line)!.group(1)! + text.trimLeft();
  }
  return text;
}
