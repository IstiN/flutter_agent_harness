/// Centralized error/warning text for the hashline tokenizer, parser, and
/// patcher, ported from oh-my-pi `packages/hashline/src/messages.ts`.
library;

import 'format.dart';

/// Error thrown for malformed hashline patch input (parse-time), distinct
/// from [HashlineMismatchError]-style apply-time rejections.
final class HashlineFormatException implements Exception {
  /// Creates an exception with [message].
  const HashlineFormatException(this.message);

  /// The diagnostic text.
  final String message;

  @override
  String toString() => message;
}

/// Lines of context shown either side of a hash mismatch.
const mismatchContextLines = 2;

/// Numbered `LINE:TEXT` rows around [anchorLines] (±[mismatchContextLines]),
/// `*`-marking anchors, `...` between non-adjacent runs. Out-of-range anchors
/// contribute no rows.
List<String> formatAnchoredContext(
  List<int> anchorLines,
  List<String> fileLines,
) {
  final displayLines = <int>{};
  for (final line in anchorLines) {
    if (line < 1 || line > fileLines.length) continue;
    final lo = line - mismatchContextLines < 1
        ? 1
        : line - mismatchContextLines;
    final hi = line + mismatchContextLines > fileLines.length
        ? fileLines.length
        : line + mismatchContextLines;
    for (var lineNum = lo; lineNum <= hi; lineNum++) {
      displayLines.add(lineNum);
    }
  }
  final anchorSet = anchorLines.toSet();
  final rows = <String>[];
  var previous = -1;
  final sorted = displayLines.toList()..sort();
  for (final lineNum in sorted) {
    if (previous != -1 && lineNum > previous + 1) rows.add('...');
    previous = lineNum;
    final marker = anchorSet.contains(lineNum) ? '*' : ' ';
    rows.add('$marker${formatNumberedLine(lineNum, fileLines[lineNum - 1])}');
  }
  return rows;
}

/// Optional patch envelope start marker; silently consumed.
const beginPatchMarker = '*** Begin Patch';

/// Optional patch envelope end marker; terminates parsing.
const endPatchMarker = '*** End Patch';

/// Truncation sentinel emitted by an agent loop mid-call. Ends parsing like
/// [endPatchMarker], without a warning.
const abortPatchMarker = '*** Abort';

/// Bare body rows auto-converted to literal `+` rows.
const bareBodyAutoPipedWarning =
    'Auto-prefixed bare body row(s) with `+`. Body rows must be `+TEXT` '
    'literal lines.';

/// Unified-diff-style `-` row in a hunk body.
const minusRowRejected =
    '`-` rows are not valid; the range already names the lines being '
    'changed. For Markdown bullets or other literal `-` lines, prefix the '
    'literal row with `+`: `+- item`.';

/// Replace hunk with no body. (An empty `SWAP` lowers to a deletion, omp
/// semantics; this text is kept for the delete-with-body confusion.)
const emptyReplace =
    '`SWAP N${hlRangeSep}M:` needs at least one `+TEXT` body row. To delete '
    'lines, use `DEL N${hlRangeSep}M`.';

/// Delete hunk received a body row.
const deleteTakesNoBody =
    '`DEL N${hlRangeSep}M` does not take body rows. Remove the body, or use '
    '`SWAP N${hlRangeSep}M:`.';

/// Insert hunk with no body.
const emptyInsert = '`INS` needs at least one `+TEXT` body row.';

/// `REM` / `MV` / `*.BLK` ops parsed but not supported by this port.
const blockOpsUnavailable =
    '`SWAP.BLK`/`DEL.BLK`/`INS.BLK.POST` are not available here (no block '
    'resolver configured). Use a concrete line range.';

/// `REM` (whole-file delete) is recognized but not supported by this port.
const remUnsupported =
    '`REM` (whole-file delete) is not supported by this hashline port; use '
    'line ops (`SWAP`/`DEL`/`INS`) or the bash tool.';

/// `MV` (move/rename) is recognized but not supported by this port.
const moveUnsupported =
    '`MV` (move/rename) is not supported by this hashline port; use line ops '
    '(`SWAP`/`DEL`/`INS`) or the bash tool.';

/// `INS.HEAD:`/`INS.TAIL:` applied despite a stale snapshot tag.
const headTailDriftWarning =
    'Applied the `INS.HEAD:`/`INS.TAIL:` edit despite a stale snapshot tag '
    '(file changed since your read) — head/tail position is '
    'content-independent. Re-read if the drift was unexpected.';

/// Section omitted the mandatory snapshot tag.
String missingSnapshotTagMessage(String sectionPath) {
  return 'Missing hashline snapshot tag for $sectionPath; use '
      '`$hlFilePrefix$sectionPath${hlFileHashSep}tag$hlFileSuffix` from your '
      'latest hashline read output. To create a new file, use the write '
      'tool.';
}

/// A section named a path that does not exist, but its filename and snapshot
/// tag together match exactly one file read earlier this session. The edit
/// was rebound to that file's full path.
String pathRecoveredFromTagMessage(
  String authoredPath,
  String resolvedPath,
  String tag,
) {
  return 'Path "$authoredPath" does not exist; matched its filename and '
      'snapshot tag $hlFileHashSep$tag to $resolvedPath (read earlier this '
      'session). Anchor future edits on '
      '$hlFilePrefix$resolvedPath${hlFileHashSep}TAG$hlFileSuffix.';
}

/// Compresses a line list into a sorted `1-4, 7, 10-12` range string.
String formatLineRanges(List<int> lines) {
  final sorted = lines.toSet().toList()..sort();
  if (sorted.isEmpty) return '';
  final parts = <String>[];
  var start = sorted[0];
  var prev = sorted[0];
  for (var i = 1; i <= sorted.length; i++) {
    final current = i < sorted.length ? sorted[i] : null;
    if (current != null && current == prev + 1) {
      prev = current;
      continue;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    if (current == null) break;
    start = current;
    prev = current;
  }
  return parts.join(', ');
}

/// One anchored line whose actual content is surfaced in an error message.
typedef RevealedLine = ({int line, String text});

/// Content preview handed to [unseenLinesMessage].
typedef UnseenLinesReveal = ({List<RevealedLine> lines, bool truncated});

/// An anchored edit referenced lines the read that minted the cited tag
/// never displayed. Editing lines you have not read is the off-by-memory
/// failure that mangles files, so the edit is rejected with the actual
/// content inline (omp's `unseenLinesMessage`).
String unseenLinesMessage(
  String sectionPath,
  List<int> unseenLines,
  String tag,
  UnseenLinesReveal reveal,
) {
  final ranges = formatLineRanges(unseenLines);
  final header =
      'This edit anchors to lines $ranges of $sectionPath that '
      '$hlFilePrefix$sectionPath$hlFileHashSep$tag$hlFileSuffix never '
      'displayed (it showed a partial range or a truncated prefix).';
  if (reveal.lines.isEmpty) {
    return '$header Re-read those lines first with `read` (use offset/limit '
        'for the range) to mint a fresh tag, then re-issue the edit.';
  }
  final preview = reveal.lines
      .map((line) => '  ${formatNumberedLine(line.line, line.text)}')
      .join('\n');
  if (reveal.truncated) {
    return '$header Preview of the actual file content at the first '
        '${reveal.lines.length} unseen line(s):\n$preview\n'
        'The range exceeds the inline preview cap — re-read the remainder '
        'with `read` (offset/limit) before re-issuing the edit.';
  }
  return '$header Actual file content at those lines:\n$preview\n'
      'Verify the content matches what you intend to touch, then re-issue '
      'the edit with the same '
      '$hlFilePrefix${'path'}$hlFileHashSep${'tag'}$hlFileSuffix header — a '
      'straight retry now succeeds without a re-read. If the content does '
      'NOT match, fix your line numbers.';
}

/// The patch parsed and applied cleanly but produced no change — the
/// `+literal` body rows matched the file content at the targeted lines
/// byte-for-byte (omp's `noChangeDiagnostic`).
String noChangeDiagnostic(String path) {
  return 'Edits to $path parsed and applied cleanly, but produced no '
      'change: your body row(s) are byte-identical to the file at the '
      'targeted lines. The bug is somewhere else — re-read the file before '
      'issuing another edit. Do NOT widen the payload or add lines; verify '
      'the anchor first.';
}
