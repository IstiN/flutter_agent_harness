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
  r'\[\s*context notes?\s*[—–\-:]',
  caseSensitive: false,
);

final RegExp _secondPerson = RegExp(
  r'\b(?:you|your|yours|yourself)\b',
  caseSensitive: false,
);

/// The ephemeral constructions themselves — adjacency, not co-occurrence.
/// A bare second-person pronoun plus a bare temporal word anywhere in a
/// sentence strips durable prose ("the user asked you to re-run the full
/// suite after the previous fix lands"); only these claim shapes fire.
///
/// - The possessive arm additionally demands a loss/trim verb in the same
///   sentence: "rebase your previous commits" is a constraint, not a drop
///   claim; "your last tool call's result was dropped" is the claim.
/// - The `you`-arm covers contracted and interpolated forms ("you've
///   just", "you're about to", "you were (just) about to"). A bare "you
///   just" additionally demands a following PAST-TENSE verb form:
///   regular verbs ending in -ed (minus present-tense verbs that merely
///   end in -ed) or a common irregular. English irregular pasts are a
///   finite closed set, so the irregular alternation is exhaustive for
///   the verbs summaries use - except the homographs whose past spelling
///   equals their present (hit, cut, set, put, read): matching those
///   would also strip present-tense habituals, so they are the
///   deliberate floor. "you just merged the PR" is a recency claim,
///   while "you just need to re-run make", "if you just look at the
///   failing test", and reported speech ("you just said" / "you
///   just told me") are durable and survive.
final RegExp _ephemeralClaim = RegExp(
  r"\byour\s+(?:last|previous|prior)\b"
  r"(?=[^.]*\b(?:dropped|trimmed|removed|lost)\b)"
  r"|\byou(?:'ve\s+just|'re\s+about to|\s+(?:were\s+)?(?:just\s+)?about to"
  r"|\s+just(?=\s+(?:(?!(?:need|seed|embed|speed|proceed|exceed|succeed)\b)\w+ed"
  r"|(?:ran|did|went|got|saw|wrote|made|found|broke|sent|took|left|came|gave"
  r"|built|lost|kept|held|felt|spent|brought|heard|met|paid|won"
  r"|began|forgot|sold|fell|rose|flew|grew|threw|drove|spoke|chose|stood))\b))\b"
  r'|\b(?:was|were)\s+dropped\b',
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

/// Removes every `[context note …]` block — opened by a real bracket and
/// closed by a `]` within the same line or the two lines after it (LLM
/// summaries reflow notes at ~80 columns); an unterminated or far-closed
/// opener is prose that merely mentions a context note and is left
/// untouched. Removed spans are recorded as stripped.
String _stripContextNotes(String text, List<String> stripped) {
  final out = StringBuffer();
  var start = 0;
  for (final match in _contextNoteOpen.allMatches(text)) {
    if (match.start < start) continue; // opener inside a removed block
    final close = text.indexOf(']', match.end);
    final searchEnd = close < 0 ? text.length : close;
    final newlines =
        '\n'.allMatches(text.substring(match.end, searchEnd)).length;
    if (close < 0 || newlines > 2) continue;
    out.write(text.substring(start, match.start));
    var end = close + 1;
    // A note occupying a whole line takes its line break with it, so the
    // strip does not leave a blank line behind.
    if (end < text.length &&
        text[end] == '\n' &&
        (match.start == 0 || text[match.start - 1] == '\n')) {
      end++;
    }
    final removed = text.substring(match.start, end);
    if (removed.trim().isNotEmpty) stripped.add(removed.trim());
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
    if (_secondPerson.hasMatch(sentence) && _ephemeralClaim.hasMatch(sentence)) {
      if (sentence.trim().isNotEmpty) stripped.add(sentence.trim());
      continue;
    }
    kept.add(sentence);
  }
  if (kept.length == sentences.length) return line;
  if (kept.isEmpty) return null;
  final text = kept.join(' ');
  // A surviving bare list marker ("2." after its content was stripped)
  // is noise, and re-attaching the original marker would duplicate it.
  if (RegExp(r'^\s*(?:[-*+]|\d+\.)$').hasMatch(text)) return null;
  // A partially stripped bullet keeps its marker so the list stays valid.
  final bullet = RegExp(r'^(\s*(?:[-*+]|\d+\.)\s+)');
  if (bullet.hasMatch(line) && !bullet.hasMatch(text)) {
    return bullet.firstMatch(line)!.group(1)! + text.trimLeft();
  }
  return text;
}
