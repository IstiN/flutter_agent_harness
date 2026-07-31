/// Token-driven state machine that turns a stream of [HashlineToken]s into a
/// flat list of [HashlineEdit]s, ported from oh-my-pi
/// `packages/hashline/src/parser.ts`. Sits between the tokenizer and the
/// applier.
///
/// Divergences from omp: the tree-sitter block ops (`SWAP.BLK`/`DEL.BLK`/
/// `INS.BLK.POST`) and the file-level ops (`REM`/`MV`) are recognized by the
/// tokenizer but rejected here with focused "unsupported" errors — this port
/// covers the line-range subset (`SWAP`/`DEL`/`INS.*`).
library;

import 'format.dart';
import 'messages.dart';
import 'prefixes.dart';
import 'tokenizer.dart';
import 'types.dart';

void _validateRangeOrder(HashlineRange range, int lineNum) {
  if (range.end.line < range.start.line) {
    throw HashlineFormatException(
      'line $lineNum: range ${range.start.line}$hlRangeSep${range.end.line} '
      'ends before it starts.',
    );
  }
}

List<HashlineAnchor> _expandRange(HashlineRange range) {
  return [
    for (var line = range.start.line; line <= range.end.line; line++)
      HashlineAnchor(line),
  ];
}

bool _isSkippableCommentLine(String line) => line.trimLeft().startsWith('#');

/// Stripped remainder of a bare `N: <value>` row that is a lone quoted or
/// numeric literal (optionally comma-terminated) — the shape of a
/// numeric-keyed dict/YAML body rather than read-output paste.
final _bareLiteralValueRe = RegExp(
  r'''^\s*(?:"[^"]*"|'[^']*'|[-+]?\d+(?:\.\d+)?)\s*,?\s*$''',
);

/// Detects apply_patch / unified-diff contamination in a raw line and
/// returns the focused diagnostic, or `null` when the line is clean.
String? _detectContamination(String text) {
  final trimmed = text.trimLeft();
  if (trimmed.isEmpty) return null;
  return _detectApplyPatchSentinel(trimmed) ??
      _detectDiffHunkHeader(trimmed) ??
      _detectVerbMisuse(trimmed);
}

/// The apply_patch file sentinels (`*** Update File:` and friends).
String? _detectApplyPatchSentinel(String trimmed) {
  if (!trimmed.startsWith('*** Update File:') &&
      !trimmed.startsWith('*** Add File:') &&
      !trimmed.startsWith('*** Delete File:') &&
      !trimmed.startsWith('*** Move to:')) {
    return null;
  }
  final preview = trimmed.length > 48
      ? '${trimmed.substring(0, 48)}…'
      : trimmed;
  return 'apply_patch sentinel ${repr(preview)} is not valid in hashline. '
      'File sections start with `[path#HASH]` (no `Update File:` / '
      '`Add File:` keyword). Use `SWAP N${hlRangeSep}M:`, '
      '`DEL N${hlRangeSep}M`, or `INS.PRE|POST|HEAD|TAIL:` ops.';
}

/// Unified-diff hunk headers, both the full `@@ -N,M +N,M @@` form and
/// bare `@@`-bracketed variants.
String? _detectDiffHunkHeader(String trimmed) {
  if (RegExp(r'^@@\s+[-+]?\d+,\d+\s+[-+]?\d+,\d+\s+@@').hasMatch(trimmed)) {
    return 'unified-diff hunk header (`@@ -N,M +N,M @@`) is not valid in '
        'hashline. Use `SWAP N${hlRangeSep}M:`, `DEL N${hlRangeSep}M`, or '
        '`INS.PRE|POST|HEAD|TAIL:` ops.';
  }
  if (!trimmed.startsWith('@@')) return null;
  final preview = trimmed.length > 48
      ? '${trimmed.substring(0, 48)}…'
      : trimmed;
  return '`@@`-bracketed hunk header ${repr(preview)} is not valid in '
      'hashline. Drop the `@@ ... @@` brackets and write a verb header '
      'such as `SWAP N${hlRangeSep}M:`.';
}

/// Verb-less or mis-verbed hunk headers: `DEL N:M:` with a colon, a lone
/// line number, or a bare `N-M` range with no verb.
String? _detectVerbMisuse(String trimmed) {
  if (RegExp(
    r'^DEL\s+[1-9]\d*(?:\s*(?:\.\.|\.=|-|…|\s)\s*[1-9]\d*)?\s*:',
  ).hasMatch(trimmed)) {
    return '`DEL N${hlRangeSep}M` has no colon and no body. Remove the colon '
        'and body rows.';
  }
  if (RegExp(r'^[1-9]\d*\s*$').hasMatch(trimmed)) {
    return 'hunk headers need a verb. Use `SWAP $trimmed$hlRangeSep$trimmed:` '
        'to replace, or `DEL $trimmed` to delete.';
  }
  final bareRange = RegExp(
    r'^([1-9]\d*)\s*[-. …=]+\s*([1-9]\d*)\s*:?$',
  ).firstMatch(trimmed);
  if (bareRange == null) return null;
  return 'bare range hunk header ${repr(trimmed)} is not valid. Hunk '
      'headers need a verb: write '
      '`SWAP ${bareRange[1]}$hlRangeSep${bareRange[2]}:` or '
      '`DEL ${bareRange[1]}$hlRangeSep${bareRange[2]}`.';
}

final class _PendingComment {
  _PendingComment({required this.lineNum, required this.text});
  final int lineNum;
  final String text;
}

final class _PayloadRow {
  _PayloadRow({required this.text, required this.lineNum, this.bare = false});
  String text;
  final int lineNum;

  /// Bare rows came from raw (non-`+`) lines auto-converted to payload; only
  /// those participate in uniform `N:` prefix stripping.
  final bool bare;
}

final class _Pending {
  _Pending({required this.target, required this.lineNum});
  final HashlineTarget target;
  final int lineNum;
  final List<_PayloadRow> payloads = [];

  /// Blank rows seen after the body started. Interior blanks are committed
  /// to the payload when the next non-blank row arrives; trailing blanks
  /// before the next header/op are layout separators and are discarded on
  /// flush.
  final List<_PayloadRow> deferredBlanks = [];
}

/// Result of parsing one section body: the flat edit list plus diagnostics.
final class HashlineParseResult {
  /// Creates a result with [edits] and [warnings].
  const HashlineParseResult({required this.edits, required this.warnings});

  /// The parsed edits in patch order.
  final List<HashlineEdit> edits;

  /// Non-fatal diagnostics (e.g. bare body rows auto-prefixed with `+`).
  final List<String> warnings;
}

/// The parser state machine. Feed tokens with [feed], finish with [end].
final class HashlineParser {
  final List<HashlineEdit> _edits = [];
  final List<String> _warnings = [];
  var _editIndex = 0;
  _Pending? _pending;
  var _terminated = false;
  final List<_PendingComment> _skippableComments = [];

  void _discardPendingSkippableComments() {
    _skippableComments.clear();
  }

  void _consumePendingSkippableComments() {
    if (_skippableComments.isEmpty) return;
    for (final comment in _skippableComments) {
      _handleRaw(comment.text, comment.lineNum);
    }
    _skippableComments.clear();
  }

  /// Feeds one token into the state machine.
  void feed(HashlineToken token) {
    if (_terminated) return;
    switch (token) {
      case HashlineRawToken():
        _feedRawToken(token);
      case HashlineOpToken():
        _discardPendingSkippableComments();
        _handleOp(token.target, token.lineNum);
      case HashlineAbortToken():
        _terminated = true;
      default:
        _feedBodyToken(token);
    }
  }

  /// Raw rows that begin a skippable `#` comment run outside a hunk body are
  /// buffered until a non-comment token decides whether they were noise.
  void _feedRawToken(HashlineRawToken token) {
    if (_pending == null && _isSkippableCommentLine(token.text)) {
      _skippableComments.add(
        _PendingComment(text: token.text, lineNum: token.lineNum),
      );
      return;
    }
    _consumePendingSkippableComments();
    _handleRaw(token.text, token.lineNum);
  }

  /// Envelope, header, blank, and payload tokens all consume any buffered
  /// skippable comments first, then run their own step.
  void _feedBodyToken(HashlineToken token) {
    _consumePendingSkippableComments();
    switch (token) {
      case HashlineEnvelopeEndToken():
        _terminated = true;
      case HashlineHeaderToken():
        _flushPending();
      case HashlineBlankToken():
        _handleBlank('', token.lineNum);
      case HashlinePayloadToken():
        _handleLiteralPayload(token.text, token.lineNum);
      default:
        // EnvelopeBegin: comments consumed above, nothing further.
        break;
    }
  }

  void _handleOp(HashlineTarget target, int lineNum) {
    switch (target) {
      case HashlineTargetReplace(:final range):
      case HashlineTargetDelete(:final range):
        _validateRangeOrder(range, lineNum);
      default:
        _rejectUnsupportedOp(target);
    }
    _flushPending();
    _pending = _Pending(target: target, lineNum: lineNum);
  }

  /// The tree-sitter block ops and the file-level ops are recognized by the
  /// tokenizer but rejected by this port with focused "unsupported" errors.
  void _rejectUnsupportedOp(HashlineTarget target) {
    if (target is HashlineTargetBlock ||
        target is HashlineTargetDeleteBlock ||
        target is HashlineTargetInsertAfterBlock) {
      throw const HashlineFormatException(blockOpsUnavailable);
    }
    if (target is HashlineTargetRem) {
      throw const HashlineFormatException(remUnsupported);
    }
    if (target is HashlineTargetMove) {
      throw const HashlineFormatException(moveUnsupported);
    }
  }

  /// Finishes parsing and returns the edits plus warnings.
  HashlineParseResult end() {
    _consumePendingSkippableComments();
    _flushPending();
    _validateNoOverlappingDeletes();
    return HashlineParseResult(edits: _edits, warnings: _warnings);
  }

  void _validateNoOverlappingDeletes() {
    final sourceLinesByAnchor = <int, List<int>>{};
    for (final edit in _edits) {
      if (edit is! HashlineDelete) continue;
      final sourceLines = sourceLinesByAnchor.putIfAbsent(
        edit.anchor.line,
        () => [],
      );
      if (!sourceLines.contains(edit.lineNum)) sourceLines.add(edit.lineNum);
    }
    for (final entry in sourceLinesByAnchor.entries) {
      final sourceLines = entry.value;
      if (sourceLines.length < 2) continue;
      sourceLines.sort();
      final firstBlock = sourceLines[0];
      final secondBlock = sourceLines[1];
      throw HashlineFormatException(
        'line $secondBlock: anchor line ${entry.key} is already targeted by '
        'another hunk on line $firstBlock. Issue ONE hunk per range; '
        'payload is only the final desired content, never a before/after '
        'pair.',
      );
    }
  }

  void _handleLiteralPayload(String text, int lineNum) {
    final pending = _pending;
    if (pending == null) {
      throw HashlineFormatException(
        'line $lineNum: payload line has no preceding hunk header. Got '
        '${repr('$hlPayloadReplace$text')}.',
      );
    }
    if (pending.target is HashlineTargetDelete) {
      throw const HashlineFormatException(deleteTakesNoBody);
    }
    _commitDeferredBlanks(pending);
    pending.payloads.add(_PayloadRow(text: text, lineNum: lineNum));
  }

  void _handleRaw(String text, int lineNum) {
    final contamination = _detectContamination(text);
    if (contamination != null) {
      throw HashlineFormatException('line $lineNum: $contamination');
    }
    final pending = _pending;
    if (pending != null) {
      _handleRawBodyRow(pending, text, lineNum);
      return;
    }
    if (text.trim().isEmpty) return;
    throw HashlineFormatException(
      'line $lineNum: payload line has no preceding hunk header. Use '
      '`SWAP N${hlRangeSep}M:`, `DEL N${hlRangeSep}M`, or '
      '`INS.PRE|POST|HEAD|TAIL:` above the body. Got ${repr(text)}.',
    );
  }

  /// A raw (non-`+`) row inside a hunk body: auto-converted to a bare
  /// payload row ([bareBodyAutoPipedWarning]).
  void _handleRawBodyRow(_Pending pending, String text, int lineNum) {
    if (text.trim().isEmpty) {
      _handleBlank(text, lineNum);
      return;
    }
    if (pending.target is HashlineTargetDelete) {
      throw const HashlineFormatException(deleteTakesNoBody);
    }
    if (text.trimLeft().codeUnitAt(0) == 45 /* - */ ) {
      throw const HashlineFormatException(minusRowRejected);
    }
    if (!_warnings.contains(bareBodyAutoPipedWarning)) {
      _warnings.add(bareBodyAutoPipedWarning);
    }
    _commitDeferredBlanks(pending);
    // Defer read-output line-number stripping to _flushPending: a bare
    // "N:text" row is only a copy-paste artifact from snapshot output when
    // *every* bare row in the hunk carries that prefix. Stripping a row in
    // isolation would corrupt a genuine body that merely starts with
    // "digits:" (YAML ports "42:hello", timestamps "12:30") when it sits
    // next to an unprefixed sibling.
    pending.payloads.add(_PayloadRow(text: text, lineNum: lineNum, bare: true));
  }

  /// A blank row inside a hunk body is ambiguous: interior blanks are body
  /// content, while blanks before the body starts or trailing into the next
  /// op are layout. Defer them; [_commitDeferredBlanks] folds them in only
  /// when a later non-blank row proves they were interior.
  void _handleBlank(String text, int lineNum) {
    final pending = _pending;
    if (pending == null) return;
    if (pending.target is HashlineTargetDelete) return;
    if (pending.payloads.isEmpty) return;
    pending.deferredBlanks.add(
      _PayloadRow(text: text, lineNum: lineNum, bare: true),
    );
  }

  void _commitDeferredBlanks(_Pending pending) {
    if (pending.deferredBlanks.isEmpty) return;
    if (!_warnings.contains(bareBodyAutoPipedWarning)) {
      _warnings.add(bareBodyAutoPipedWarning);
    }
    pending.payloads.addAll(pending.deferredBlanks);
    pending.deferredBlanks.clear();
  }

  /// Strips a single read-output line-number prefix (`N:`) from every bare
  /// body row, but only when *all* bare rows carry one. A uniform set of
  /// prefixes is the signature of content pasted straight from `read`
  /// output; a mixed set means the `N:` is genuine payload content and must
  /// stay. Rows authored with an explicit `+` are not bare, never stripped.
  void _stripBarePrefixesIfUniform(List<_PayloadRow> payloads) {
    if (!_barePrefixesAreUniform(payloads)) return;
    for (final row in payloads) {
      if (row.bare && row.text.trim().isNotEmpty) {
        row.text = stripOneLeadingHashlinePrefix(row.text);
      }
    }
  }

  /// The stripped remainder of [row]'s text, or null when the row carries no
  /// read-output line-number prefix.
  String? _strippedPrefixRemainder(_PayloadRow row) {
    final stripped = stripOneLeadingHashlinePrefix(row.text);
    if (identical(stripped, row.text) || stripped == row.text) return null;
    return stripped;
  }

  /// Whether every bare row carries a strippable `N:` prefix AND the
  /// stripped remainders are not all lone quoted/numeric literals.
  bool _barePrefixesAreUniform(List<_PayloadRow> payloads) {
    final rows = payloads.where(_isCountableBareRow);
    if (rows.isEmpty) return false;
    final remainders = rows.map(_strippedPrefixRemainder);
    if (remainders.any((remainder) => remainder == null)) return false;
    // A body where every stripped remainder is a lone quoted/numeric literal
    // is the shape of a numeric-keyed dict or YAML mapping (`1: "one",`),
    // not read-output paste; stripping the "N:" keys would mangle every
    // line.
    return remainders.whereType<String>().any(
      (remainder) => !_bareLiteralValueRe.hasMatch(remainder),
    );
  }

  /// Whether [row] counts for the bare-prefix uniformity check: a bare row
  /// with non-blank text.
  bool _isCountableBareRow(_PayloadRow row) =>
      row.bare && row.text.trim().isNotEmpty;

  void _pushInsert(
    HashlineCursor cursor,
    String text,
    int lineNum, {
    bool replacement = false,
  }) {
    _edits.add(
      HashlineInsert(
        cursor: cursor,
        text: text,
        replacement: replacement,
        lineNum: lineNum,
        index: _editIndex++,
      ),
    );
  }

  void _pushDelete(HashlineAnchor anchor, int lineNum) {
    _edits.add(
      HashlineDelete(anchor: anchor, lineNum: lineNum, index: _editIndex++),
    );
  }

  void _flushPending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    final target = pending.target;
    final lineNum = pending.lineNum;
    final payloads = pending.payloads;
    _stripBarePrefixesIfUniform(payloads);

    if (target is HashlineTargetDelete) {
      _pushDeleteRange(target.range, lineNum);
      return;
    }
    if (payloads.isEmpty) {
      _flushEmptyBody(target, lineNum);
      return;
    }
    _flushBody(target, lineNum, payloads);
  }

  void _pushDeleteRange(HashlineRange range, int lineNum) {
    for (final anchor in _expandRange(range)) {
      _pushDelete(anchor, lineNum);
    }
  }

  /// A hunk with no body rows: an empty SWAP body lowers to a pure deletion
  /// of the range (omp semantics: `SWAP N.=M:` with no `+` rows deletes the
  /// lines); every other op requires at least one body row.
  void _flushEmptyBody(HashlineTarget target, int lineNum) {
    if (target is HashlineTargetReplace) {
      _pushDeleteRange(target.range, lineNum);
      return;
    }
    throw const HashlineFormatException(emptyInsert);
  }

  void _flushBody(
    HashlineTarget target,
    int lineNum,
    List<_PayloadRow> payloads,
  ) {
    if (target is HashlineTargetReplace) {
      final cursor = HashlineCursorBefore(target.range.start);
      for (final payload in payloads) {
        _pushInsert(cursor, payload.text, lineNum, replacement: true);
      }
      _pushDeleteRange(target.range, lineNum);
      return;
    }
    final cursor = _insertCursorFor(target);
    for (final payload in payloads) {
      _pushInsert(cursor, payload.text, lineNum);
    }
  }

  /// The cursor a non-replace insert target lowers to.
  HashlineCursor _insertCursorFor(HashlineTarget target) {
    if (target is HashlineTargetInsertBefore) {
      return HashlineCursorBefore(target.anchor);
    }
    if (target is HashlineTargetInsertAfter) {
      return HashlineCursorAfter(target.anchor);
    }
    return target is HashlineTargetBof
        ? const HashlineCursorBof()
        : const HashlineCursorEof();
  }
}

/// Parses one section body ([diff]) into edits plus warnings. The input must
/// NOT contain the `[path#tag]` section header — section splitting happens in
/// `input.dart` (omp's `parsePatch`).
HashlineParseResult parseHashlinePatch(String diff) {
  final parser = HashlineParser();
  for (final token in tokenizeHashline(diff)) {
    parser.feed(token);
  }
  return parser.end();
}
