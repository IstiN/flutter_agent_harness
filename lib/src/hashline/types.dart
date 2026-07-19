/// Pure data types shared across the hashline tokenizer, parser, and
/// applier, ported from oh-my-pi `packages/hashline/src/types.ts`. Nothing in
/// this file references a filesystem, agent runtime, or schema library —
/// keep it that way.
library;

/// A line-number anchor (1-indexed).
final class HashlineAnchor {
  /// Creates an anchor on [line] (1-indexed).
  const HashlineAnchor(this.line);

  /// The 1-indexed line number.
  final int line;

  @override
  String toString() => 'HashlineAnchor($line)';
}

/// Where an insert edit should land relative to existing content.
sealed class HashlineCursor {
  const HashlineCursor();
}

/// Insert at the very start of the file (`INS.HEAD:`).
final class HashlineCursorBof extends HashlineCursor {
  const HashlineCursorBof();

  @override
  String toString() => 'bof';
}

/// Insert at the very end of the file (`INS.TAIL:`).
final class HashlineCursorEof extends HashlineCursor {
  const HashlineCursorEof();

  @override
  String toString() => 'eof';
}

/// Insert immediately before [anchor] (`INS.PRE N:`).
final class HashlineCursorBefore extends HashlineCursor {
  const HashlineCursorBefore(this.anchor);

  /// The anchor line the payload lands in front of.
  final HashlineAnchor anchor;

  @override
  String toString() => 'before(${anchor.line})';
}

/// Insert immediately after [anchor] (`INS.POST N:`).
final class HashlineCursorAfter extends HashlineCursor {
  const HashlineCursorAfter(this.anchor);

  /// The anchor line the payload lands behind.
  final HashlineAnchor anchor;

  @override
  String toString() => 'after(${anchor.line})';
}

/// A single low-level edit produced by the parser and consumed by the
/// applier. Multi-line replacements decompose to one insert per replacement
/// line plus one delete per consumed line. Replacement payloads are tagged so
/// the applier can distinguish literal insertion from new content for a
/// deleted line.
sealed class HashlineEdit {
  const HashlineEdit({required this.lineNum, required this.index});

  /// 1-indexed patch line the edit was parsed from (groups one hunk).
  final int lineNum;

  /// Stable parse order, used to sequence edits that share a line.
  final int index;
}

/// Insert [text] at [cursor]. [replacement] marks payload lines lowered from
/// a `SWAP N.=M:` hunk (new content for the deleted range).
final class HashlineInsert extends HashlineEdit {
  const HashlineInsert({
    required this.cursor,
    required this.text,
    this.replacement = false,
    required super.lineNum,
    required super.index,
  });

  /// Where the line should land.
  final HashlineCursor cursor;

  /// The literal line content (without its `+` body-row sigil).
  final String text;

  /// Whether this insert is replacement payload for a `SWAP` hunk.
  final bool replacement;

  @override
  String toString() => 'insert($cursor, ${repr(text)}, repl=$replacement)';
}

/// Delete the line at [anchor].
final class HashlineDelete extends HashlineEdit {
  const HashlineDelete({
    required this.anchor,
    required super.lineNum,
    required super.index,
  });

  /// The line to remove.
  final HashlineAnchor anchor;

  @override
  String toString() => 'delete(${anchor.line})';
}

/// A parsed `[A.=B]` line range (1-indexed, inclusive on both ends).
final class HashlineRange {
  /// Creates a range from [start] to [end].
  const HashlineRange({required this.start, required this.end});

  /// First line of the range.
  final HashlineAnchor start;

  /// Last line of the range (inclusive).
  final HashlineAnchor end;

  @override
  String toString() => '${start.line}.=${end.line}';
}

/// Result of applying a parsed set of edits to a text body.
final class HashlineApplyResult {
  /// Creates a result with the post-edit [text].
  const HashlineApplyResult({
    required this.text,
    this.firstChangedLine,
    this.warnings = const [],
  });

  /// Post-edit text body.
  final String text;

  /// First line number (1-indexed) that changed, or `null` for a no-op
  /// apply.
  final int? firstChangedLine;

  /// Diagnostic warnings collected by the parser or patcher.
  final List<String> warnings;
}

/// Renders [text] with JSON-style quoting for diagnostics.
String repr(String text) => '"$text"';
