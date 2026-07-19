/// Line-oriented classifier for hashline diff text, ported from oh-my-pi
/// `packages/hashline/src/tokenizer.ts`.
///
/// Format shape:
/// ```
/// [path/to/file.ts#1A2B]
/// SWAP 5.=7:
/// +literal new line
/// ```
library;

import 'format.dart';
import 'messages.dart';
import 'types.dart';

const _charLineFeed = 10;
const _charCarriageReturn = 13;
const _charZero = 48;
const _charNine = 57;
const _charHash = 35;
const _charTab = 9;
const _charSpace = 32;
const _charDot = 46;
const _charComma = 44;
const _charHyphen = 45;
const _charEllipsis = 0x2026;
const _charEquals = 61;

const _charUpperA = 65;
const _charUpperF = 70;
const _charLowerA = 97;
const _charLowerF = 102;

final int _charColon = hlHeaderColon.codeUnitAt(0);

bool _isDigitCode(int code) => code >= _charZero && code <= _charNine;

bool _isNonZeroDigitCode(int code) => code > _charZero && code <= _charNine;

bool _isHexDigitCode(int code) =>
    _isDigitCode(code) ||
    (code >= _charUpperA && code <= _charUpperF) ||
    (code >= _charLowerA && code <= _charLowerF);

bool _isWhitespaceCode(int code) =>
    code == _charSpace || (code >= _charTab && code <= _charCarriageReturn);

int _skipWhitespace(String line, int index, [int? end]) {
  final limit = end ?? line.length;
  while (index < limit && _isWhitespaceCode(line.codeUnitAt(index))) {
    index++;
  }
  return index;
}

int _trimEndIndex(String line) {
  var end = line.length;
  while (end > 0 && _isWhitespaceCode(line.codeUnitAt(end - 1))) {
    end--;
  }
  return end;
}

bool _markerLineEquals(String line, String marker) {
  final end = _trimEndIndex(line);
  return end == marker.length && line.startsWith(marker);
}

/// Splits [text] into lines on LF, dropping a single trailing CR per line
/// (omp's `splitHashlineLines`).
List<String> splitHashlineLines(String text) {
  if (text.isEmpty) return [''];
  final lines = <String>[];
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    if (text.codeUnitAt(index) != _charLineFeed) continue;
    var end = index;
    if (end > start && text.codeUnitAt(end - 1) == _charCarriageReturn) {
      end--;
    }
    lines.add(text.substring(start, end));
    start = index + 1;
  }
  if (start < text.length) {
    var end = text.length;
    if (end > start && text.codeUnitAt(end - 1) == _charCarriageReturn) {
      end--;
    }
    lines.add(text.substring(start, end));
  }
  return lines;
}

/// Scans a bare positive line number at [index]; `null` when absent.
({int line, int nextIndex})? _scanLineNumber(String line, int index, int end) {
  if (index >= end || !_isNonZeroDigitCode(line.codeUnitAt(index))) {
    return null;
  }
  var lineNumber = 0;
  var nextIndex = index;
  while (nextIndex < end) {
    final code = line.codeUnitAt(nextIndex);
    if (!_isDigitCode(code)) break;
    lineNumber = lineNumber * 10 + (code - _charZero);
    nextIndex++;
  }
  return (line: lineNumber, nextIndex: nextIndex);
}

/// Parses a bare line-number anchor. Throws on malformed input.
HashlineAnchor parseLid(String raw, int lineNum) {
  final end = _trimEndIndex(raw);
  final numberStart = _skipWhitespace(raw, 0, end);
  final number = _scanLineNumber(raw, numberStart, end);
  if (number == null || _skipWhitespace(raw, number.nextIndex, end) != end) {
    throw HashlineFormatException(
      'line $lineNum: expected a line number such as '
      '${describeAnchorExamples('119')}; got ${repr(raw)}. Use '
      '[PATH#hash] from your latest read for file-version binding.',
    );
  }
  return HashlineAnchor(number.line);
}

/// Consumes the lenient range separators omp accepts between two line
/// numbers: whitespace, `,`, `-`, `…`, `..`, or `.=`. Returns the index of
/// the second number, or `null`.
int? _scanRangeSeparator(String line, int index, int end) {
  var cursor = index;
  var consumedSeparator = false;
  while (cursor < end) {
    final code = line.codeUnitAt(cursor);
    if (_isWhitespaceCode(code)) {
      cursor++;
      consumedSeparator = true;
      continue;
    }
    if (code == _charComma || code == _charHyphen || code == _charEllipsis) {
      cursor++;
      consumedSeparator = true;
      continue;
    }
    if (code == _charDot &&
        cursor + 1 < end &&
        (line.codeUnitAt(cursor + 1) == _charDot ||
            line.codeUnitAt(cursor + 1) == _charEquals)) {
      cursor += 2;
      consumedSeparator = true;
      continue;
    }
    break;
  }
  if (!consumedSeparator) return null;
  if (cursor >= end || !_isNonZeroDigitCode(line.codeUnitAt(cursor))) {
    return null;
  }
  return cursor;
}

/// Scans an `A.=B` header range (or a bare `A` when [allowSingle]).
({HashlineRange range, int nextIndex})? _scanHeaderRange(
  String line, [
  int index = 0,
  int? end,
  bool allowSingle = false,
]) {
  final limit = end ?? _trimEndIndex(line);
  final numberStart = _skipWhitespace(line, index, limit);
  final start = _scanLineNumber(line, numberStart, limit);
  if (start == null) return null;
  final afterFirst = _scanRangeSeparator(line, start.nextIndex, limit);
  if (afterFirst == null) {
    if (!allowSingle) return null;
    return (
      range: HashlineRange(
        start: HashlineAnchor(start.line),
        end: HashlineAnchor(start.line),
      ),
      nextIndex: _skipWhitespace(line, start.nextIndex, limit),
    );
  }
  final endNumber = _scanLineNumber(line, afterFirst, limit);
  if (endNumber == null) return null;
  return (
    range: HashlineRange(
      start: HashlineAnchor(start.line),
      end: HashlineAnchor(endNumber.line),
    ),
    nextIndex: _skipWhitespace(line, endNumber.nextIndex, limit),
  );
}

/// The edit target parsed from a hunk-header line.
sealed class HashlineTarget {
  const HashlineTarget();
}

/// `SWAP A.=B:` — replace the inclusive range with the body rows.
final class HashlineTargetReplace extends HashlineTarget {
  const HashlineTargetReplace(this.range);

  /// The inclusive original-line range being replaced.
  final HashlineRange range;
}

/// `SWAP.BLK N:` — tree-sitter block replace (recognized, unsupported).
final class HashlineTargetBlock extends HashlineTarget {
  const HashlineTargetBlock(this.anchor);

  /// The line the block must begin on.
  final HashlineAnchor anchor;
}

/// `DEL A.=B` — delete the inclusive range (no body).
final class HashlineTargetDelete extends HashlineTarget {
  const HashlineTargetDelete(this.range);

  /// The inclusive original-line range being deleted.
  final HashlineRange range;
}

/// `DEL.BLK N` — tree-sitter block delete (recognized, unsupported).
final class HashlineTargetDeleteBlock extends HashlineTarget {
  const HashlineTargetDeleteBlock(this.anchor);

  /// The line the block must begin on.
  final HashlineAnchor anchor;
}

/// `INS.PRE N:` — insert the body rows before line N.
final class HashlineTargetInsertBefore extends HashlineTarget {
  const HashlineTargetInsertBefore(this.anchor);

  /// The anchor line.
  final HashlineAnchor anchor;
}

/// `INS.POST N:` — insert the body rows after line N.
final class HashlineTargetInsertAfter extends HashlineTarget {
  const HashlineTargetInsertAfter(this.anchor);

  /// The anchor line.
  final HashlineAnchor anchor;
}

/// `INS.BLK.POST N:` — insert after a tree-sitter block (recognized,
/// unsupported).
final class HashlineTargetInsertAfterBlock extends HashlineTarget {
  const HashlineTargetInsertAfterBlock(this.anchor);

  /// The line the block must begin on.
  final HashlineAnchor anchor;
}

/// `REM` — whole-file delete (recognized, unsupported).
final class HashlineTargetRem extends HashlineTarget {
  const HashlineTargetRem();
}

/// `MV DEST` — file move/rename (recognized, unsupported).
final class HashlineTargetMove extends HashlineTarget {
  const HashlineTargetMove(this.dest);

  /// The destination path.
  final String dest;
}

/// `INS.HEAD:` — insert at the very start of the file.
final class HashlineTargetBof extends HashlineTarget {
  const HashlineTargetBof();
}

/// `INS.TAIL:` — insert at the very end of the file.
final class HashlineTargetEof extends HashlineTarget {
  const HashlineTargetEof();
}

/// Returns the index just past [keyword] when [line] starts with it at
/// [index] and the next character is whitespace, `:` or `.` (or the line
/// ends); `null` otherwise.
int? _scanKeyword(String line, int index, int end, String keyword) {
  if (!line.startsWith(keyword, index)) return null;
  final next = index + keyword.length;
  if (next < end) {
    final code = line.codeUnitAt(next);
    if (!_isWhitespaceCode(code) && code != _charColon && code != _charDot) {
      return null;
    }
  }
  return next;
}

/// GLM 5.2 inserts a stray `.` between the line number/range and the trailing
/// `:` (e.g. `SWAP 2.=3.:`, `INS.POST 2.:`). A `.` is never valid syntax at
/// this position, so skip it when it precedes an optional `:` or end-of-line.
int _skipStrayDot(String line, int index, int end) {
  if (index < end && line.codeUnitAt(index) == _charDot) {
    final after = _skipWhitespace(line, index + 1, end);
    if (after == end || line.codeUnitAt(after) == _charColon) return after;
  }
  return index;
}

int _consumeOptionalColon(String line, int index, int end) {
  var cursor = _skipWhitespace(line, index, end);
  cursor = _skipStrayDot(line, cursor, end);
  return cursor < end && line.codeUnitAt(cursor) == _charColon
      ? _skipWhitespace(line, cursor + 1, end)
      : cursor;
}

/// Recovers local-model replace trailers that permute `:` and `=` as `:=:` or
/// `=:`. The range has already been parsed, so these suffixes are
/// unambiguous.
int _consumeReplaceColon(String line, int index, int end) {
  final canonical = _consumeOptionalColon(line, index, end);
  if (canonical >= end || line.codeUnitAt(canonical) != _charEquals) {
    return canonical;
  }
  final afterEquals = _skipWhitespace(line, canonical + 1, end);
  if (afterEquals >= end || line.codeUnitAt(afterEquals) != _charColon) {
    return canonical;
  }
  return _skipWhitespace(line, afterEquals + 1, end);
}

/// Scans the `.PRE N` / `.POST N` / `.HEAD` / `.TAIL` suffix of an `INS`
/// hunk header.
({HashlineTarget target, int nextIndex})? _scanInsertTarget(
  String line,
  int index,
  int end,
) {
  if (index >= end || line.codeUnitAt(index) != _charDot) return null;
  final cursor = _skipWhitespace(line, index + 1, end);
  final beforeEnd = _scanKeyword(line, cursor, end, hlInsertBefore);
  if (beforeEnd != null) {
    final anchor = _scanLineNumber(
      line,
      _skipWhitespace(line, beforeEnd, end),
      end,
    );
    if (anchor == null) return null;
    final nextIndex = _consumeOptionalColon(line, anchor.nextIndex, end);
    return (
      target: HashlineTargetInsertBefore(HashlineAnchor(anchor.line)),
      nextIndex: nextIndex,
    );
  }
  final afterEnd = _scanKeyword(line, cursor, end, hlInsertAfter);
  if (afterEnd != null) {
    final anchor = _scanLineNumber(
      line,
      _skipWhitespace(line, afterEnd, end),
      end,
    );
    if (anchor == null) return null;
    final nextIndex = _consumeOptionalColon(line, anchor.nextIndex, end);
    return (
      target: HashlineTargetInsertAfter(HashlineAnchor(anchor.line)),
      nextIndex: nextIndex,
    );
  }
  final headEnd = _scanKeyword(line, cursor, end, hlInsertHead);
  if (headEnd != null) {
    return (
      target: const HashlineTargetBof(),
      nextIndex: _consumeOptionalColon(line, headEnd, end),
    );
  }
  final tailEnd = _scanKeyword(line, cursor, end, hlInsertTail);
  if (tailEnd != null) {
    return (
      target: const HashlineTargetEof(),
      nextIndex: _consumeOptionalColon(line, tailEnd, end),
    );
  }
  return null;
}

/// Removes matching surrounding single or double quotes from [pathText]
/// (omp's `unquotePath`, shared by the tokenizer and the section splitter).
String unquoteHashlinePath(String pathText) {
  if (pathText.length < 2) return pathText;
  final first = pathText[0];
  final last = pathText[pathText.length - 1];
  if ((first == '"' || first == "'") && first == last) {
    return pathText.substring(1, pathText.length - 1);
  }
  return pathText;
}

/// Scans a (possibly quoted) `MV` destination path.
String? _scanMoveDest(String line, int index, int end) {
  final cursor = _skipWhitespace(line, index, end);
  if (cursor >= end) return null;
  final first = line.codeUnitAt(cursor);
  if (first == 34 /* " */ || first == 39 /* ' */ ) {
    final quote = line[cursor];
    var next = cursor + 1;
    while (next < end) {
      final ch = line[next];
      if (ch == r'\' && next + 1 < end) {
        next += 2;
        continue;
      }
      if (ch == quote) {
        final after = _skipWhitespace(line, next + 1, end);
        return after == end
            ? unquoteHashlinePath(line.substring(cursor, next + 1))
            : null;
      }
      next++;
    }
    return null;
  }
  return unquoteHashlinePath(line.substring(cursor, end).trim());
}

/// Scans any hunk-header target at [start].
({HashlineTarget target, int nextIndex})? _scanHunkAnchor(
  String line,
  int start,
  int end,
) {
  final cursor = _skipWhitespace(line, start, end);

  final remEnd = _scanKeyword(line, cursor, end, hlRemKeyword);
  if (remEnd != null) {
    final next = _skipWhitespace(line, remEnd, end);
    if (next != end) return null;
    return (target: const HashlineTargetRem(), nextIndex: next);
  }
  final moveEnd = _scanKeyword(line, cursor, end, hlMoveKeyword);
  if (moveEnd != null) {
    final dest = _scanMoveDest(line, moveEnd, end);
    if (dest == null || dest.isEmpty) return null;
    return (target: HashlineTargetMove(dest), nextIndex: end);
  }

  // `SWAP.BLK N:` — resolve N to a tree-sitter block range at apply time.
  final replaceBlockEnd = _scanKeyword(
    line,
    cursor,
    end,
    hlReplaceBlockKeyword,
  );
  if (replaceBlockEnd != null) {
    final anchor = _scanLineNumber(
      line,
      _skipWhitespace(line, replaceBlockEnd, end),
      end,
    );
    if (anchor == null) return null;
    return (
      target: HashlineTargetBlock(HashlineAnchor(anchor.line)),
      nextIndex: _consumeOptionalColon(line, anchor.nextIndex, end),
    );
  }
  final replaceEnd = _scanKeyword(line, cursor, end, hlReplaceKeyword);
  if (replaceEnd != null) {
    final range = _scanHeaderRange(line, replaceEnd, end, true);
    if (range == null) return null;
    return (
      target: HashlineTargetReplace(range.range),
      nextIndex: _consumeReplaceColon(line, range.nextIndex, end),
    );
  }
  // `DEL.BLK N` — like `DEL N.=M`, takes no body and no trailing colon.
  final deleteBlockEnd = _scanKeyword(line, cursor, end, hlDeleteBlockKeyword);
  if (deleteBlockEnd != null) {
    final anchor = _scanLineNumber(
      line,
      _skipWhitespace(line, deleteBlockEnd, end),
      end,
    );
    if (anchor == null) return null;
    var next = _skipWhitespace(line, anchor.nextIndex, end);
    next = _skipStrayDot(line, next, end);
    if (next < end && line.codeUnitAt(next) == _charColon) return null;
    return (
      target: HashlineTargetDeleteBlock(HashlineAnchor(anchor.line)),
      nextIndex: next,
    );
  }
  // `DEL N.=M` — takes no body and no trailing colon; a colon here falls
  // through to contamination detection.
  final deleteEnd = _scanKeyword(line, cursor, end, hlDeleteKeyword);
  if (deleteEnd != null) {
    final range = _scanHeaderRange(line, deleteEnd, end, true);
    if (range == null) return null;
    final next = _skipStrayDot(line, range.nextIndex, end);
    if (next < end && line.codeUnitAt(next) == _charColon) return null;
    return (target: HashlineTargetDelete(range.range), nextIndex: next);
  }
  // `INS.BLK.POST N:` — insert after the last line of the block at N.
  final insertAfterBlockEnd = _scanKeyword(
    line,
    cursor,
    end,
    hlInsertAfterBlockKeyword,
  );
  if (insertAfterBlockEnd != null) {
    final anchor = _scanLineNumber(
      line,
      _skipWhitespace(line, insertAfterBlockEnd, end),
      end,
    );
    if (anchor == null) return null;
    return (
      target: HashlineTargetInsertAfterBlock(HashlineAnchor(anchor.line)),
      nextIndex: _consumeOptionalColon(line, anchor.nextIndex, end),
    );
  }
  final insertEnd = _scanKeyword(line, cursor, end, hlInsertKeyword);
  if (insertEnd != null) return _scanInsertTarget(line, insertEnd, end);
  return null;
}

/// Parses a full hunk-header line; `null` when the line is not exactly one
/// hunk header.
HashlineTarget? tryParseHunkHeader(String line) {
  final end = _trimEndIndex(line);
  final start = _skipWhitespace(line, 0, end);
  if (start >= end) return null;
  final scan = _scanHunkAnchor(line, start, end);
  if (scan == null) return null;
  if (scan.nextIndex != end) return null;
  return scan.target;
}

/// Parses a `[PATH]` / `[PATH#TAG]` header line; `null` when malformed.
({String path, String? fileHash})? tryParseHeader(String line) {
  if (!line.startsWith(hlFilePrefix)) return null;
  final end = _trimEndIndex(line);
  if (hlFilePrefix.length + hlFileSuffix.length >= end) return null;
  if (line.codeUnitAt(end - 1) != hlFileSuffix.codeUnitAt(0)) return null;
  final bodyEnd = end - hlFileSuffix.length;
  if (hlFilePrefix.length >= bodyEnd) return null;

  // The snapshot tag, when present, is the trailing `#XXXX` block inside the
  // bracketed header. We detect it from the suffix so the path may
  // legitimately contain whitespace.
  var pathEnd = bodyEnd;
  String? fileHash;
  final trailingHashStart = bodyEnd - hlFileHashLength - 1;
  if (trailingHashStart >= hlFilePrefix.length &&
      line.codeUnitAt(trailingHashStart) == _charHash) {
    var allHex = true;
    for (var probe = trailingHashStart + 1; probe < bodyEnd; probe++) {
      if (!_isHexDigitCode(line.codeUnitAt(probe))) {
        allHex = false;
        break;
      }
    }
    if (allHex) {
      pathEnd = trailingHashStart;
      fileHash = line.substring(trailingHashStart + 1, bodyEnd).toUpperCase();
    }
  }

  // The header grammar uses `#` as the path/tag separator and does not allow
  // `#` inside filenames. Anything `#` left in the path body — short tags,
  // non-hex tags, over-long tags, stale-tag copy-paste — means the header is
  // malformed.
  for (var i = hlFilePrefix.length; i < pathEnd; i++) {
    if (line.codeUnitAt(i) == _charHash) return null;
  }

  if (pathEnd == hlFilePrefix.length) return null;
  final path = line.substring(hlFilePrefix.length, pathEnd);
  return (path: path, fileHash: fileHash);
}

/// One classified input line.
sealed class HashlineToken {
  const HashlineToken({required this.lineNum});

  /// 1-indexed input line number this token came from.
  final int lineNum;
}

/// An empty line.
final class HashlineBlankToken extends HashlineToken {
  const HashlineBlankToken({required super.lineNum});
}

/// `*** Begin Patch` envelope marker.
final class HashlineEnvelopeBeginToken extends HashlineToken {
  const HashlineEnvelopeBeginToken({required super.lineNum});
}

/// `*** End Patch` envelope marker; terminates parsing.
final class HashlineEnvelopeEndToken extends HashlineToken {
  const HashlineEnvelopeEndToken({required super.lineNum});
}

/// `*** Abort` truncation sentinel; terminates parsing.
final class HashlineAbortToken extends HashlineToken {
  const HashlineAbortToken({required super.lineNum});
}

/// A `[PATH]` or `[PATH#TAG]` section header.
final class HashlineHeaderToken extends HashlineToken {
  const HashlineHeaderToken({
    required this.path,
    this.fileHash,
    required super.lineNum,
  });

  /// The section path as authored.
  final String path;

  /// The 4-hex snapshot tag, when present.
  final String? fileHash;
}

/// A hunk-header line (`SWAP`, `DEL`, `INS.*`, `REM`, `MV`, `*.BLK`).
final class HashlineOpToken extends HashlineToken {
  const HashlineOpToken({required this.target, required super.lineNum});

  /// The parsed hunk target.
  final HashlineTarget target;
}

/// A `+TEXT` literal body row (text excludes the sigil).
final class HashlinePayloadToken extends HashlineToken {
  const HashlinePayloadToken({required this.text, required super.lineNum});

  /// The literal row content after the leading `+`.
  final String text;
}

/// Any other line.
final class HashlineRawToken extends HashlineToken {
  const HashlineRawToken({required this.text, required super.lineNum});

  /// The line text, verbatim.
  final String text;
}

/// Classifies one input line (omp's `classifyLine`).
HashlineToken classifyHashlineLine(String line, int lineNum) {
  if (line.isEmpty) return HashlineBlankToken(lineNum: lineNum);
  if (_markerLineEquals(line, beginPatchMarker)) {
    return HashlineEnvelopeBeginToken(lineNum: lineNum);
  }
  if (_markerLineEquals(line, endPatchMarker)) {
    return HashlineEnvelopeEndToken(lineNum: lineNum);
  }
  if (_markerLineEquals(line, abortPatchMarker)) {
    return HashlineAbortToken(lineNum: lineNum);
  }
  final firstCode = line.codeUnitAt(0);
  if (line.startsWith(hlFilePrefix)) {
    final header = tryParseHeader(line);
    if (header != null) {
      return HashlineHeaderToken(
        lineNum: lineNum,
        path: header.path,
        fileHash: header.fileHash,
      );
    }
  }
  final lead = _skipWhitespace(line, 0);
  final isHunkLead =
      line.startsWith(hlReplaceKeyword, lead) ||
      line.startsWith(hlDeleteKeyword, lead) ||
      line.startsWith(hlInsertKeyword, lead) ||
      line.startsWith(hlRemKeyword, lead) ||
      line.startsWith(hlMoveKeyword, lead);
  if (isHunkLead) {
    final hunk = tryParseHunkHeader(line);
    if (hunk != null) {
      return HashlineOpToken(lineNum: lineNum, target: hunk);
    }
  }
  if (firstCode == hlPayloadReplace.codeUnitAt(0)) {
    return HashlinePayloadToken(lineNum: lineNum, text: line.substring(1));
  }
  return HashlineRawToken(lineNum: lineNum, text: line);
}

/// Tokenizes a complete patch input (no streaming; omp's
/// `Tokenizer.tokenizeAll` equivalent).
List<HashlineToken> tokenizeHashline(String text) {
  final lines = splitHashlineLines(text);
  return [
    for (var i = 0; i < lines.length; i++)
      classifyHashlineLine(lines[i], i + 1),
  ];
}

/// Whether [line] parses as a hunk-header line.
bool isHashlineOp(String line) => tryParseHunkHeader(line) != null;

/// Whether [line] parses as a `[PATH]` / `[PATH#TAG]` header.
bool isHashlineHeader(String line) => tryParseHeader(line) != null;

/// Whether [line] is a patch envelope marker (`*** Begin/End Patch`,
/// `*** Abort`).
bool isHashlineEnvelopeMarker(String line) =>
    _markerLineEquals(line, beginPatchMarker) ||
    _markerLineEquals(line, endPatchMarker) ||
    _markerLineEquals(line, abortPatchMarker);
