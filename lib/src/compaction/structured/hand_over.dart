/// The hand-over reply protocol of the merged compaction call (GOAL
/// #2394): the instruction renderer, the reply parser and the hide-label
/// sanitizer. Pure functions over text — no IO, no provider.
///
/// One call reads the last main request as sent (S0 — every record tagged
/// `m<N>`) plus ONE appended instruction ([renderHandOverInstruction]);
/// the reply is a hide list followed by `-` and the hand-over text
/// ([parseHandOverReply]). The model PROPOSES — the engine disposes (see
/// `hand_over_dispose.dart`); every label the model writes passes
/// [sanitizeHideLabel] before it can reach a marker.
library;

import '../record_tag.dart' show stripRecordTags;
import '../summary_sanitizer.dart';

/// One hide proposal: the inclusive alias range `from`..`to` on the S0
/// epoch plus the model's raw label text (unsanitized).
final class HandOverHidePick {
  /// Creates a pick.
  const HandOverHidePick({
    required this.from,
    required this.to,
    required this.rawLabel,
  });

  /// The first alias of the range.
  final int from;

  /// The last alias of the range (equal to [from] for a single record).
  final int to;

  /// The label exactly as the model wrote it (empty when none).
  final String rawLabel;
}

/// A parsed hand-over reply.
final class HandOverReply {
  /// Creates a reply.
  const HandOverReply({
    required this.picks,
    required this.transfer,
    required this.ignoredLines,
  });

  /// The hide proposals in reply order, deduplicated.
  final List<HandOverHidePick> picks;

  /// The hand-over text after the `-` separator; `null` when the reply
  /// carried no text (hide-only, E5) or was empty.
  final String? transfer;

  /// Reply lines inside the hide prefix that named no usable alias
  /// (garbage or inverted ranges) — a count for the run log, never
  /// content.
  final int ignoredLines;

  /// Whether the reply proposed a hide-only run (no transfer text).
  bool get hideOnly => picks.isNotEmpty && transfer == null;
}

final RegExp _thinkBlocks = RegExp(
  r'<think>.*?</think>',
  dotAll: true,
  caseSensitive: false,
);
final RegExp _thinkOpenEnded = RegExp(
  r'<think>.*$',
  dotAll: true,
  caseSensitive: false,
);
final RegExp _zeroWidth = RegExp(r'[\u200B\u200C\u200D\u2060\uFEFF]');

/// Normalizes a reply's encoding noise (E1): BOM, zero-width characters
/// and CRLF line endings never reach the parser.
String normalizeReplyText(String text) => text
    .replaceAll(_zeroWidth, '')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n');

/// Removes `<think>…</think>` blocks — and an unclosed `<think>` through
/// the end of the text — BEFORE parsing or persisting (E3): reasoning that
/// leaked into the text channel is never a hide id, never a transfer.
String stripThinkBlocks(String text) =>
    text.replaceAll(_thinkBlocks, '').replaceAll(_thinkOpenEnded, '');

// `(?![0-9])` binds the alias: an over-long digit run is not an alias.
final RegExp _rangeLine = RegExp(
  r'^\s*m?(\d{1,9})(?![0-9])\s*-\s*(\d{1,9})(?![0-9])(?:\s+-\s*|\s+)?(.*?)\s*$',
);
final RegExp _singleLine = RegExp(
  r'^\s*m?(\d{1,9})(?![0-9])(?:\s+-\s*|\s+)?(.*?)\s*$',
);
final RegExp _separatorLine = RegExp(r'^-{2,}$');

/// A hide-list range wider than this is a degenerate echo (the judge
/// parser's bound) and names nothing.
const int _maxRangeSpan = 10000;

/// Parses the model's hand-over reply (AC5).
///
/// The hide list is the MAXIMAL PREFIX of lines of the shape `N`, `N-M`
/// (inclusive range) plus an optional ` - ` / whitespace and a label:
/// - an inverted or over-long range is ignored (counted in
///   [HandOverReply.ignoredLines]); duplicates collapse (E2);
/// - a line of dashes (`-`, `---`) ends the list; the separator is
///   OPTIONAL — the first non-id, non-blank line after the list starts
///   the transfer (blank lines never end it);
/// - a FIRST line that is not an id and not the separator means NO hides
///   and the whole text is the transfer (the skeleton example `NN-NN`
///   returned verbatim lands here — E29);
/// - no text after the list → [HandOverReply.transfer] is `null`
///   (hide-only, E5).
HandOverReply parseHandOverReply(String text) {
  final normalized = stripThinkBlocks(normalizeReplyText(text)).trim();
  if (normalized.isEmpty) {
    return const HandOverReply(picks: [], transfer: null, ignoredLines: 0);
  }
  final lines = normalized.split('\n');
  final picks = <HandOverHidePick>[];
  final seen = <String>{};
  var ignored = 0;
  var index = 0;
  // Blank lines never end the list (a model often pads before the `-`);
  // the first non-blank line that names no alias does.
  while (index < lines.length) {
    final parsed = _hideListLine(lines[index], seen);
    picks.addAll([?parsed.pick]);
    if (parsed.ignored) {
      ignored++;
    }
    if (parsed.consumed) {
      index++;
    }
    if (parsed.ends) {
      break;
    }
  }
  if (index == 0) {
    // Not an id line and not a separator: no hides, whole text = transfer.
    return HandOverReply(
      picks: const [],
      transfer: normalized,
      ignoredLines: 0,
    );
  }
  final transfer = lines.sublist(index).join('\n').trim();
  return HandOverReply(
    picks: picks,
    transfer: transfer.isEmpty ? null : transfer,
    ignoredLines: ignored,
  );
}

/// One hide-list line: [pick] names an alias (deduplicated through
/// [seen]), [ignored] is an id line naming nothing usable, [ends] stops
/// the list (the separator, or a line that is no id at all), and
/// [consumed] says whether the line belongs to the list (a non-id line
/// starts the transfer itself).
({HandOverHidePick? pick, bool ignored, bool ends, bool consumed})
_hideListLine(String line, Set<String> seen) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) {
    return (pick: null, ignored: false, ends: false, consumed: true);
  }
  if (trimmed == '-' || _separatorLine.hasMatch(trimmed)) {
    return (pick: null, ignored: false, ends: true, consumed: true);
  }
  final range = _rangeLine.firstMatch(line);
  final single = range == null ? _singleLine.firstMatch(line) : null;
  if (range == null && single == null) {
    return (pick: null, ignored: false, ends: true, consumed: false);
  }
  final parsed = _aliasLine(range ?? single!, isRange: range != null);
  final key = parsed.pick == null
      ? ''
      : '${parsed.pick!.from}-${parsed.pick!.to}';
  if (parsed.pick != null && !seen.add(key)) {
    return (pick: null, ignored: false, ends: false, consumed: true);
  }
  return (
    pick: parsed.pick,
    ignored: parsed.ignored,
    ends: false,
    consumed: true,
  );
}

/// An id line's pick: an inverted or over-long range is [ignored]
/// (counted, never content).
({HandOverHidePick? pick, bool ignored}) _aliasLine(
  RegExpMatch match, {
  required bool isRange,
}) {
  final from = int.parse(match.group(1)!);
  final to = isRange ? int.parse(match.group(2)!) : from;
  if (from <= 0 || to < from || to - from >= _maxRangeSpan) {
    return (pick: null, ignored: true);
  }
  return (
    pick: HandOverHidePick(
      from: from,
      to: to,
      rawLabel: (match.group(isRange ? 3 : 2) ?? '').trim(),
    ),
    ignored: false,
  );
}

final RegExp _labelLead = RegExp(r'^[-–—:]+\s*');
final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _brackets = RegExp(r'[\[\]]');
final RegExp _numericEcho = RegExp(r'^m?\d+(?:-\d+)?(?:\s+m?\d+(?:-\d+)?)*$');

// Word boundaries that understand Cyrillic too: `\b` is ASCII-only.
const String _notWord = r'(?<![A-Za-z0-9А-Яа-яЁё])';
const String _notWordAfter = r'(?![A-Za-z0-9А-Яа-яЁё])';
final RegExp _secondPersonLabel = RegExp(
  '$_notWord(?:you|your|yours|yourself|u|ur|ты|тебя|твой|вы|вас|ваш|ваша|ваше|ваши|вам)'
  '$_notWordAfter',
  caseSensitive: false,
);
final RegExp _imperativeLabel = RegExp(
  '$_notWord(?:must|should|do not|don\'t|always|never|required|'
  r'обязательно|нужно|должен|должна|должно|запрещено|всегда|никогда)'
  '$_notWordAfter',
  caseSensitive: false,
);

/// The label budget (D3): one line, at most this many characters…
const int hideLabelMaxChars = 48;

/// …and at most this many words.
const int hideLabelMaxWords = 6;

/// Sanitizes a model-written hide label (D3/E35) into text safe to render
/// in every later request, or `null` (the marker then carries no label):
/// one whitespace-collapsed line without `[]`, ≤ [hideLabelMaxChars]
/// characters and ≤ [hideLabelMaxWords] words, no second person, no
/// imperative/imperative-shaped markers, no digits-only range echo — and
/// unchanged through the summary sanitizer's ephemeral arm (a label the
/// sanitizer would rewrite is not a label). NEVER stored as a message.
String? sanitizeHideLabel(String raw) {
  var label = raw
      .trim()
      .replaceFirst(_labelLead, '')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  if (label.isEmpty || label == '-') return null;
  if (_brackets.hasMatch(label)) return null;
  if (label.length > hideLabelMaxChars) return null;
  if (label.split(' ').length > hideLabelMaxWords) return null;
  if (_numericEcho.hasMatch(label)) return null;
  if (_secondPersonLabel.hasMatch(label)) return null;
  if (_imperativeLabel.hasMatch(label)) return null;
  if (sanitizeSummary(label).text != label) return null;
  return label;
}

final RegExp _placeholder = RegExp(r'\{\{(\w+)\}\}');

/// Renders the hand-over instruction from the prompt template (D13 —
/// `prompts.g.dart` carries no templating, the `{{…}}` tokens are
/// substituted here, at the call site). Deterministic: same inputs, same
/// text; an unknown token is left verbatim so a prompt edit naming a new
/// placeholder surfaces in the output instead of vanishing.
String renderHandOverInstruction({
  required String template,
  required int contextTokens,
  required int windowTokens,
  required int foldFrom,
  required int foldTo,
  List<String> openUserRequests = const [],
  String? pinnedOperative,
  String? foldedCheckpoints,
}) {
  final values = <String, String>{
    'context_tokens': '$contextTokens',
    'window_tokens': '$windowTokens',
    'fold_from': '$foldFrom',
    'fold_to': '$foldTo',
    'open_user_requests': openUserRequests.isEmpty
        ? 'none'
        : openUserRequests.join('\n'),
    'pinned_operative': pinnedOperative ?? '',
    'folded_checkpoints': foldedCheckpoints ?? '',
  };
  return template
      .replaceAllMapped(_placeholder, (match) => values[match[1]] ?? match[0]!)
      .trimRight();
}

final RegExp _userIntentHeading = RegExp(
  // MANDATORY whitespace after the `#`s (`\s+`) — the belt's exact
  // heading shape (`summary_sanitizer.dart`): a run-together `##Open
  // User Requests` passes no sanitizer belt, so the gate must fail it
  // too or the gh-2103 laundering path reopens (gh-2407 review thread 2).
  r'^(?:#{1,6}\s+)?(?:open user requests\b|open asks\b\s*:)',
  multiLine: true,
  caseSensitive: false,
);
final RegExp _askPointer = RegExp(r'^\s*-\s*\[[^\]]*\]\s*');

/// The verdict of the mechanical open-asks check (D2/#81).
typedef OpenUserRequestsVerdict = ({
  /// Whether the transfer carries the mandatory `## Open User Requests`
  /// (or `open asks:`) heading — without it the sanitizer belt cannot
  /// run, so the run FAILS.
  bool heading,

  /// Every `<open-user-requests>` line whose text (after the pointer,
  /// whitespace-flattened) is not present VERBATIM in the transfer.
  List<String> missing,
});

/// Verifies the hand-over text against the engine's mechanical
/// `<open-user-requests>` block (AC6): the heading must be present and
/// every ask line must survive verbatim; otherwise the run fails and
/// nothing is appended (E36).
///
/// BOTH sides normalize identically (gh-2407 review thread 4): the reply
/// went through [normalizeReplyText] (zero-width noise) and the engine's
/// [stripRecordTags] (persist-side echo hygiene), so a raw mechanical
/// ask carrying a literal `m<N> ` quote or a zero-width character must
/// be reduced the same way before the containment check — comparing
/// normalized against raw would fail every run of a session whose asks
/// carry such text (a permanent fail-closed fold stall, loud but
/// unfixable without editing history).
OpenUserRequestsVerdict verifyOpenUserRequests(
  String transfer,
  List<String> askLines,
) {
  final flat = transfer.replaceAll(_whitespaceRun, ' ');
  final missing = <String>[];
  for (final line in askLines) {
    final text = stripRecordTags(
      normalizeReplyText(line.replaceFirst(_askPointer, '')),
    ).replaceAll(_whitespaceRun, ' ').trim();
    if (text.isEmpty) continue;
    if (!flat.contains(text)) {
      missing.add(text);
    }
  }
  return (heading: _userIntentHeading.hasMatch(transfer), missing: missing);
}
