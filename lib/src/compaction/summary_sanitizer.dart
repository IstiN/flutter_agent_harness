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
///
/// gh-2103 adds the provenance belt over the same chokepoints: digest text
/// must not launder tool-controlled content into trusted memory. Within the
/// user-intent sections of a digest (`## Open User Requests`, `## Original
/// Request`, `open asks:`), machine-origin lines (the [isSyntheticUserText]
/// classes — the same lines the request-candidate scan refuses to feed the
/// summarizer) are stripped, and a line quoting tool text verbatim carries
/// a `[from toolResult]` origin mark. The mark arm grades against
/// [SummaryOriginEvidence] — the transcript the fold consumed — so it is
/// wired at persist sites; heal-on-read sites pass no evidence and only the
/// synthetic arm fires.
library;

import '../context.dart' show ToolResultMessage, UserMessage;
import '../types.dart' show Message, TextContent;
import '../user_text.dart' show isSyntheticUserText, userMessageText;
import 'structured/markers.dart' show pinBlockCloseTag, pinBlockOpenTag;

/// A summary after sanitization: the cleaned [text] plus the [stripped]
/// ephemeral/laundered spans (persist sites log them, e.g. in the compaction
/// record's `details`) and the [marked] lines that gained a `[from
/// toolResult]` origin mark (gh-2103, logged alongside the strips).
typedef SanitizedSummary = ({
  String text,
  List<String> stripped,
  List<String> marked,
});

/// Flattened transcript-origin evidence for the provenance belt (gh-2103).
///
/// Built at persist sites from the same [messages] the summarizer consumed:
/// the whitespace-flattened text of every user message and every tool
/// result of the summarized span. A digest line in a user-intent section
/// that verbatim-quotes one of the tool texts (and no user text) is a
/// laundered quote — the belt origin-marks it; a line contained in (or
/// containing) a user text is user-sourced and stays untouched.
final class SummaryOriginEvidence {
  /// Collects the origin evidence of one summarized span.
  SummaryOriginEvidence(Iterable<Message> messages)
    : userTexts = [
        for (final message in messages)
          if (message is UserMessage)
            if (_flattenText(userMessageText(message.content)).isNotEmpty)
              _flattenText(userMessageText(message.content)),
      ],
      toolTexts = [
        for (final message in messages)
          if (message is ToolResultMessage)
            if (_flattenText(
              message.content
                  .whereType<TextContent>()
                  .map((block) => block.text)
                  .join('\n'),
            ).isNotEmpty)
              _flattenText(
                message.content
                    .whereType<TextContent>()
                    .map((block) => block.text)
                    .join('\n'),
              ),
      ];

  /// Flattened user-message texts of the span.
  final List<String> userTexts;

  /// Flattened tool-result texts of the span.
  final List<String> toolTexts;
}

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

/// Strips ephemeral, time-scoped claims from a compaction [summary], and —
/// gh-2103 — belts the user-intent sections against laundering when the
/// fold's transcript [origins] is given (a `null` [origins], the heal-on-read
/// shape, still strips machine-origin lines; it just cannot grade quotes).
///
/// Whole `[context note …]` blocks go first (the harness delivers drop notes
/// itself, once, at the turn where they happen — a copy inside a summary is
/// always the stale-re-render class). Then any sentence that both addresses
/// the reader in the second person and claims recency or a drop is removed.
/// Everything else survives byte-identical.
///
/// gh-1409 pin exemption (AC4/F6): a sentence containing any of
/// [protectedLines] verbatim is never stripped or rewritten — these are
/// compaction-pinned skill directives riding the summary, and the
/// sanitizer must not mangle them while stripping ephemeral claims around
/// them. Lines inside a `<pinned-skill-directives>` envelope are
/// structurally exempt too (the pin block framing is harness-generated),
/// which protects pins in summaries healed on the projection path, where
/// the pin set is not known.
SanitizedSummary sanitizeSummary(
  String summary, {
  Set<String> protectedLines = const {},
  SummaryOriginEvidence? origins,
}) {
  if (summary.isEmpty) {
    return (text: summary, stripped: const [], marked: const []);
  }
  final stripped = <String>[];
  final marked = <String>[];
  final text = _stripContextNotes(summary, stripped);
  // gh-2103: user-intent sections never carry machine-origin asks, and
  // tool-verbatim quotes there carry an origin mark. Runs before the
  // ephemeral-claim walk so the per-line strips see the belted text.
  final belted = _beltUserIntentSections(
    text,
    stripped,
    marked,
    origins,
    protectedLines,
  );
  final keptLines = <String>[];
  var insidePinEnvelope = false;
  var envelopeLines = 0;
  for (final line in belted.split('\n')) {
    // Standalone-line equality only (review gh-1409 round 2): the harness
    // renders the tags as whole lines, so a tag quoted mid-prose — a pin
    // line copied into a sentence, or a hostile `operative:` line
    // smuggling the marker — must not flip the exemption.
    final trimmed = line.trim();
    if (trimmed == pinEnvelopeOpenTag) {
      insidePinEnvelope = true;
      envelopeLines = 0;
    }
    // The exemption is BOUNDED: a legit pin block is budget-capped
    // ([defaultPinBudgetChars] ⇒ ≤ ~273 rendered lines), so an unclosed
    // envelope (truncated checkpoint, hostile open without close) re-arms
    // sanitization after [_maxPinEnvelopeLines] lines instead of staying
    // exempt for the rest of the summary.
    final keptLine = insidePinEnvelope && envelopeLines < _maxPinEnvelopeLines
        ? line
        : _sanitizeLine(line, stripped, protectedLines);
    if (keptLine != null) keptLines.add(keptLine);
    if (insidePinEnvelope) envelopeLines++;
    if (trimmed == pinEnvelopeCloseTag) insidePinEnvelope = false;
  }
  return (text: keptLines.join('\n'), stripped: stripped, marked: marked);
}

// ---------------------------------------------------------------------------
// The provenance belt (gh-2103) — no laundering through user-intent sections
// ---------------------------------------------------------------------------

/// Headings whose digest sections claim USER INTENT: the classic
/// checkpoint's `## Open User Requests`, the split-turn prefix's
/// `## Original Request`, and the structured checkpoint's bare
/// `open asks:` heading. Only inside these sections can text pose AS the
/// user; everywhere else tool-derived quotes are legitimate context.
final RegExp _userIntentHeading = RegExp(
  r'^(?:#{1,6}\s+)?(?:open user requests\b|original request\b|open asks\b\s*:)',
  caseSensitive: false,
  multiLine: true,
);

final RegExp _mdHeading = RegExp(r'^#{1,6}\s');

final RegExp _bulletMarker = RegExp(r'^\s*(?:[-*+]\s|\d+\.\s)');

/// List marker plus optional task checkbox, stripped when the belt reads a
/// bullet's content.
final RegExp _bulletContentPrefix = RegExp(
  r'^\s*(?:[-*+]\s|\d+\.\s)\s*(?:\[[ xX]\]\s*)?',
);

final RegExp _coversLine = RegExp(r'^covers\b\s*:', caseSensitive: false);

/// Minimum verbatim-quote length the mark arm requires: shorter strings
/// ("error: file not found", a command name) collide too easily between a
/// real ask and incidental tool output, so they never fire the arm.
const _minQuoteChars = 24;

final RegExp _sentenceSplit = RegExp(r'(?<=[.!?])\s+');

/// Leading candidate-pointer bracket groups (`[r7 · 2026-11-14] `) the belt
/// strips before retrying a sentence against the tool bodies.
final RegExp _leadingBrackets = RegExp(r'^(?:\[[^\]]*\]\s*)+');

final RegExp _whitespaceRun = RegExp(r'\s+');

/// Leading whitespace test for the belt walk's continuation/bare-prose
/// classification (`_bulletBlockEnd`, `_endsBareHeadingSection`).
final RegExp _leadingWhitespace = RegExp(r'\s');

String _flattenText(String text) => text.replaceAll(_whitespaceRun, ' ').trim();

/// The gh-2103 belt over the user-intent sections of [text].
///
/// Within a section (from a [_userIntentHeading] line to the next markdown
/// heading, a `covers:` line, or — for the bare `open asks:` shape — the
/// first unindented prose line):
///
/// - a line (bullet block, or a prose line under a `#`-headed section)
///   whose flattened content is machine-origin by construction
///   ([isSyntheticUserText] — the same predicate the request-candidate scan
///   applies at the source) is STRIPPED and logged in [stripped];
/// - when [origins] is present and the content is user-sourced by neither
///   whole-content nor per-sentence verbatim containment, but a ≥
///   [_minQuoteChars]-char sentence IS verbatim inside a tool result, the
///   line is annotated with ` [from toolResult]` and logged in [marked].
///
/// Everything else — real asks above all — survives byte-identical. Pinned
/// directives ([protectedLines]) and the `<pinned-skill-directives>`
/// envelope are exempt, exactly as for the ephemeral-claim strips.
///
/// The walk is split so each decision stays under the CRAP ratchet: this
/// walker only dispatches whole sections to [_beltSectionBody] (pin
/// envelope lines via [_BeltPinEnvelope]); the section body grades bullet
/// blocks and prose lines and reports where the section ended.
String _beltUserIntentSections(
  String text,
  List<String> stripped,
  List<String> marked,
  SummaryOriginEvidence? origins,
  Set<String> protectedLines,
) {
  if (!_userIntentHeading.hasMatch(text)) return text;
  final lines = text.split('\n');
  final out = <String>[];
  final pin = _BeltPinEnvelope();
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (pin.entersKept(trimmed)) {
      out.add(line);
      pin.completeKept(trimmed);
      i++;
      continue;
    }
    if (!_userIntentHeading.hasMatch(trimmed)) {
      out.add(line);
      i++;
      continue;
    }
    out.add(line);
    final (belted, end) = _beltSectionBody(
      lines,
      start: i + 1,
      sectionHeaded: _mdHeading.hasMatch(line),
      origins: origins,
      protectedLines: protectedLines,
      stripped: stripped,
      marked: marked,
      pin: pin,
    );
    out.addAll(belted);
    i = end;
  }
  return out.join('\n');
}

/// The belt walk's pin-envelope exemption state (the gh-1409 envelope
/// semantics, bound to the belt's line walk): an open envelope keeps its
/// lines verbatim until the close tag or the bounded re-arm (defense in
/// depth against a hostile unclosed open), exactly mirroring the
/// `sanitizeSummary` line loop's counter placement — the open decision
/// precedes the kept test on every line, and the counter/close bookkeeping
/// rides ONLY the kept (pasthrough) branch, never the graded path.
final class _BeltPinEnvelope {
  bool _open = false;
  int _count = 0;

  /// Opens the envelope on an open tag, then tests the exemption.
  bool entersKept(String trimmed) {
    if (trimmed == pinEnvelopeOpenTag) {
      _open = true;
      _count = 0;
    }
    return _open && _count < _maxPinEnvelopeLines;
  }

  /// Pasthrough-path bookkeeping only: the line counter and the close tag
  /// are processed for kept lines. A graded or boundary line inside a
  /// re-armed envelope can neither extend nor close the exemption — the
  /// same sequencing as the `sanitizeSummary` loop.
  void completeKept(String trimmed) {
    if (_open) _count++;
    if (trimmed == pinEnvelopeCloseTag) _open = false;
  }
}

/// Consumes one user-intent section body — every line after its heading
/// until the section ends (a markdown heading or `covers:` line, or body
/// prose after a bare `open asks:` heading) or the transcript ends — and
/// returns the belted lines plus the index the caller must resume at (the
/// boundary line itself, so it is reprocessed from the outside state).
/// Pin-envelope lines ([_BeltPinEnvelope.entersKept]) are kept verbatim;
/// an envelope open when the heading arrives keeps the heading in the
/// walker's pasthrough branch, so no section opens and nothing is graded
/// until the envelope closes or re-arms.
(List<String>, int) _beltSectionBody(
  List<String> lines, {
  required int start,
  required bool sectionHeaded,
  required SummaryOriginEvidence? origins,
  required Set<String> protectedLines,
  required List<String> stripped,
  required List<String> marked,
  required _BeltPinEnvelope pin,
}) {
  final out = <String>[];
  var i = start;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (pin.entersKept(trimmed)) {
      out.add(line);
      pin.completeKept(trimmed);
      i++;
      continue;
    }
    if (_isSectionEnd(line, trimmed)) break;
    if (trimmed.isEmpty) {
      out.add(line);
      i++;
      continue;
    }
    final bullet = _bulletMarker.hasMatch(line);
    if (!bullet && _endsBareHeadingSection(line, sectionHeaded)) break;
    final end = bullet ? _bulletBlockEnd(lines, i) : i + 1;
    final block = lines.sublist(i, end);
    final verdict = _beltVerdict(block, origins, protectedLines, stripped);
    out.addAll(_applyBeltVerdict(verdict, block, marked));
    i = end;
  }
  return (out, i);
}

/// Whether [line] ends the section it is walking inside: any markdown
/// heading, or a `covers:` line (the next fold's coverage marker).
bool _isSectionEnd(String line, String trimmed) =>
    _mdHeading.hasMatch(line) || _coversLine.hasMatch(trimmed);

/// Whether a non-bullet [line] ends a bare `open asks:` section: body prose
/// at column 0 under an unmarked heading — the checkpoint's post-asks
/// narrative — is outside the asks list.
bool _endsBareHeadingSection(String line, bool sectionHeaded) =>
    !sectionHeaded && !line.startsWith(_leadingWhitespace);

/// Where a bullet block starting at [start] ends: the bullet plus its
/// indented, non-empty, non-bullet continuation lines ride one verdict.
int _bulletBlockEnd(List<String> lines, int start) {
  var end = start + 1;
  while (end < lines.length &&
      lines[end].trim().isNotEmpty &&
      lines[end].startsWith(_leadingWhitespace) &&
      !_bulletMarker.hasMatch(lines[end])) {
    end++;
  }
  return end;
}

/// Belt verdicts for one content block.
enum _BeltVerdict {
  /// No laundering signal — the block survives byte-identical.
  keep,

  /// Machine-origin content in a user-intent section — the block drops.
  strip,

  /// Tool-verbatim quote posing as user intent — the block gains an
  /// origin mark.
  mark,
}

/// Grades one bullet block (or prose line) of a user-intent section.
_BeltVerdict _beltVerdict(
  List<String> block,
  SummaryOriginEvidence? origins,
  Set<String> protectedLines,
  List<String> stripped,
) {
  for (final line in block) {
    for (final protected in protectedLines) {
      if (protected.isNotEmpty && line.contains(protected)) {
        return _BeltVerdict.keep; // gh-1409: pins are never rewritten.
      }
    }
  }
  var content = block.join(' ').replaceFirst(_bulletContentPrefix, '');
  final flat = _flattenText(content);
  if (flat.isEmpty) return _BeltVerdict.keep;
  // Arm 1 — machine-origin BY CONSTRUCTION: the request-candidate scan
  // already refuses these classes at the source, so their presence in a
  // user-intent section is laundering whatever phrasing wraps them.
  if (isSyntheticUserText(flat)) {
    stripped.add(flat);
    return _BeltVerdict.strip;
  }
  // Arm 2 — tool-verbatim quote (needs the fold's transcript evidence).
  if (origins != null && _quotesToolText(flat, origins)) {
    return _BeltVerdict.mark;
  }
  return _BeltVerdict.keep;
}

/// Whether [flatContent] in a user-intent section verbatim-quotes a tool
/// result without quoting the user: the whole content is user-sourced
/// (either containment direction — digests append scaffolding like
/// `(asked <date>, id)` around verbatim asks), or it carries a
/// [_minQuoteChars]-char sentence found inside a tool text and inside no
/// user text. The sentence grading lives in [_launderedQuoteSentence].
bool _quotesToolText(String flatContent, SummaryOriginEvidence origins) {
  if (flatContent.length < _minQuoteChars) return false;
  if (_containedInAny(origins.userTexts, flatContent, alsoContains: true)) {
    return false;
  }
  return flatContent
      .split(_sentenceSplit)
      .any((sentence) => _launderedQuoteSentence(sentence, origins));
}

/// Whether one sentence of a user-intent line is a laundering quote: long
/// enough to be distinctive, verbatim inside a tool result, and inside no
/// user text. Digest scaffolding rides the line — a candidate pointer
/// (`[r7 · …]`) prefixed to a verbatim quote must not hide the quote — so
/// the sentence is retried without its leading bracket groups.
bool _launderedQuoteSentence(String sentence, SummaryOriginEvidence origins) {
  if (sentence.length < _minQuoteChars) return false;
  if (_containedInAny(origins.userTexts, sentence)) return false;
  if (_containedInAny(origins.toolTexts, sentence)) return true;
  final bare = sentence.replaceFirst(_leadingBrackets, '');
  if (bare.length < _minQuoteChars || bare == sentence) return false;
  return _containedInAny(origins.toolTexts, bare);
}

/// Whether [needle] occurs verbatim inside any of [texts]; [alsoContains]
/// adds the reverse containment (the needle contains the text) — the
/// digest-scaffolding case where a real ask line wraps its own user text.
bool _containedInAny(
  List<String> texts,
  String needle, {
  bool alsoContains = false,
}) {
  for (final text in texts) {
    if (text.contains(needle) || (alsoContains && needle.contains(text))) {
      return true;
    }
  }
  return false;
}

/// Applies a [_BeltVerdict]: `keep` returns the block unchanged, `strip`
/// drops it (the fires were already logged by [_beltVerdict]), `mark`
/// appends the origin mark to the block's first line and logs the annotated
/// line in [marked].
List<String> _applyBeltVerdict(
  _BeltVerdict verdict,
  List<String> block,
  List<String> marked,
) {
  switch (verdict) {
    case _BeltVerdict.keep:
      return block;
    case _BeltVerdict.strip:
      return const [];
    case _BeltVerdict.mark:
      final annotated = '${block.first} [from toolResult]';
      marked.add(annotated);
      return [annotated, ...block.skip(1)];
  }
}

/// The pin-envelope exemption's line bound (defense in depth): a
/// budget-capped legit pin block is ≤ ~273 rendered lines at
/// [defaultPinBudgetChars] (8192 chars over the ~30-char minimal
/// rendering), so 512 is provably above any legit block while a hostile
/// unclosed open cannot latch the exemption over the whole summary.
const _maxPinEnvelopeLines = 512;

/// Aliases of the renderer's envelope tags — single source of truth in
/// `structured/markers.dart` ([pinBlockOpenTag]/[pinBlockCloseTag]);
/// compile-time linked, so a renderer rename cannot silently orphan the
/// exemption (review gh-1409 round 2, suggestion 5).
const pinEnvelopeOpenTag = pinBlockOpenTag;
const pinEnvelopeCloseTag = pinBlockCloseTag;

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
    final newlines = '\n'
        .allMatches(text.substring(match.end, searchEnd))
        .length;
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
/// (the line carried only ephemeral content and is dropped whole). A line
/// containing any of [protectedLines] verbatim (gh-1409 AC4: pinned skill
/// directives) is returned unchanged.
String? _sanitizeLine(
  String line,
  List<String> stripped,
  Set<String> protectedLines,
) {
  final pinKept = _pinProtectedLine(line, protectedLines);
  if (pinKept != null) return pinKept;
  final sentences = line.split(RegExp(r'(?<=[.!?])\s+'));
  final kept = _stripEphemeralSentences(sentences, stripped);
  if (kept == null) return line; // nothing stripped → byte-identical.
  if (kept.isEmpty) return null; // the line carried only ephemeral text.
  return _reassembleStrippedLine(line, kept.join(' '));
}

/// The gh-1409 AC4 guard: [line] survives verbatim when it contains any of
/// [protectedLines] (a pin carrying the summary must not be mangled by the
/// ephemeral-claim strips around it). `null` → not protected.
String? _pinProtectedLine(String line, Set<String> protectedLines) {
  for (final protected in protectedLines) {
    if (protected.isNotEmpty && line.contains(protected)) return line;
  }
  return null;
}

/// Drops the ephemeral-claim sentences ([_secondPerson] + [_ephemeralClaim])
/// from [sentences], recording each in [stripped]. `null` → nothing was
/// ephemeral (the caller keeps the line byte-identical).
List<String>? _stripEphemeralSentences(
  List<String> sentences,
  List<String> stripped,
) {
  final kept = <String>[];
  var removed = 0;
  for (final sentence in sentences) {
    if (_secondPerson.hasMatch(sentence) &&
        _ephemeralClaim.hasMatch(sentence)) {
      if (sentence.trim().isNotEmpty) stripped.add(sentence.trim());
      removed++;
      continue;
    }
    kept.add(sentence);
  }
  if (removed == 0) return null;
  return kept;
}

/// Reassembles a line whose ephemeral sentences were stripped: a bare
/// surviving list marker ("2." after its content was stripped) is noise
/// (`null` — the line drops), and a partially stripped bullet keeps its
/// marker so the list stays valid.
String? _reassembleStrippedLine(String line, String text) {
  if (RegExp(r'^\s*(?:[-*+]|\d+\.)$').hasMatch(text)) return null;
  final bullet = RegExp(r'^(\s*(?:[-*+]|\d+\.)\s+)');
  if (bullet.hasMatch(line) && !bullet.hasMatch(text)) {
    return bullet.firstMatch(line)!.group(1)! + text.trimLeft();
  }
  return text;
}
