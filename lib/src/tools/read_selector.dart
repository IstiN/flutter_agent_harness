/// The read tool's trailing-selector grammar, ported from oh-my-pi
/// `packages/coding-agent/src/tools/path-utils.ts` (`splitPathAndSel`,
/// `parseLineRangeChunk`, `parseLineRanges`) and `read.ts` (`parseSel`).
///
/// A read path may end with a trailing selector:
///
/// - `:N` / `:LN` / `:N-` / `:N..` — start at 1-indexed line N, open-ended.
/// - `:A-B` / `:LA-LB` / `:A..B` — inclusive 1-indexed line range (`..` is a
///   forgiving alias for `-`).
/// - `:A+C` / `:LA+LC` — C lines starting at A (converted to end `A + C - 1`).
/// - `:R1,R2,...` — multiple ranges, sorted and merged (overlapping or
///   adjacent ranges fuse; an open-ended range absorbs everything after it).
/// - `:raw` — verbatim output: no line numbers, no hashline header, no
///   continuation notices.
/// - `:range:raw` / `:raw:range` — line selection with raw output.
///
/// Unrecognized trailing `:...` text is intentionally NOT peeled (it stays
/// part of the path) so archive (`a.zip:inner/file`) and SQLite
/// (`db.sqlite:table`) targets can consume their own colon syntax.
///
/// Deliberate deviations from omp:
///
/// - The `:conflicts` selector (git merge-conflict rendering) is not ported.
/// - Single bounded ranges do NOT gain omp's 1 leading / 3 trailing context
///   lines: selectors exist so the agent reads exactly the lines it needs.
library;

import '../env/execution_env.dart';

/// Inclusive line range described by one selector segment (e.g. `50-100`,
/// `301-`, or `50+10`). A null [endLine] means open-ended ("to EOF").
final class LineRange {
  /// Creates a line range. [endLine] must be `>= startLine` when given.
  const LineRange(this.startLine, [this.endLine]);

  /// First line of the range (1-indexed).
  final int startLine;

  /// Last line of the range (1-indexed, inclusive), or null for open-ended.
  final int? endLine;

  @override
  bool operator ==(Object other) =>
      other is LineRange &&
      other.startLine == startLine &&
      other.endLine == endLine;

  @override
  int get hashCode => Object.hash(startLine, endLine);

  @override
  String toString() => endLine == null ? '$startLine-' : '$startLine-$endLine';
}

// A single line-range chunk: `N`, `N-M`, `N+K`, or open-ended `N-`. `..` is
// accepted everywhere `-` is, as a forgiving alias for Rust/Python-style
// ranges (e.g. `2724..2727` == `2724-2727`, `2724..` == `2724-`); it is
// normalized to `-` in [parseLineRangeChunk]. Keep this fragment and
// [_lineRangeChunkRe] in sync (omp's RANGE_CHUNK_SRC / LINE_RANGE_CHUNK_RE).
const _rangeChunkSrc = r'L?\d+(?:(?:[-+]|\.\.)L?\d+|-|\.\.)?';
const _rangeListSrc = '$_rangeChunkSrc(?:,$_rangeChunkSrc)*';

/// Selector tail recognized by [splitPathAndSel] (omp's FILE_LINE_RANGE_RE,
/// minus `conflicts`).
final _fileLineRangeRe = RegExp(
  '^(?:$_rangeListSrc|raw)\$',
  caseSensitive: false,
);

/// Selector tail that is exactly a range list (omp's FILE_LINE_RANGE_ONLY_RE).
final _fileLineRangeOnlyRe = RegExp('^$_rangeListSrc\$', caseSensitive: false);

/// Selector tail that is exactly `raw` (omp's FILE_RAW_ONLY_RE).
final _fileRawOnlyRe = RegExp(r'^raw$', caseSensitive: false);

final _lineRangeChunkRe = RegExp(
  r'^L?(\d+)(?:(\.\.|[-+])L?(\d+)?)?$',
  caseSensitive: false,
);

/// Parses a single `N`, `N-M`, `N-`, `N+K`, or `..`-aliased (`N..M`, `N..`)
/// chunk. Returns null when [sel] is not range-shaped; throws [StateError]
/// on invalid bounds (omp's ToolError messages, verbatim).
LineRange? parseLineRangeChunk(String sel) {
  final match = _lineRangeChunkRe.firstMatch(sel);
  if (match == null) return null;
  final rawStart = int.parse(match.group(1)!);
  if (rawStart < 1) {
    throw StateError(
      'Line selector 0 is invalid; lines are 1-indexed. Use :1.',
    );
  }
  // `..` is a forgiving alias for `-` (e.g. `2724..2727` == `2724-2727`).
  final sep = match.group(2) == '..' ? '-' : match.group(2);
  final rhsText = match.group(3);
  final rhs = rhsText != null ? int.parse(rhsText) : null;
  int? rawEnd;
  if (sep == '+') {
    if (rhs == null || rhs < 1) {
      throw StateError(
        'Invalid range $rawStart+${rhs ?? 0}: count must be >= 1.',
      );
    }
    rawEnd = rawStart + rhs - 1;
  } else if (sep == '-') {
    // `301-` is shorthand for "from 301 onward" — equivalent to bare `301`.
    if (rhs != null) {
      if (rhs < rawStart) {
        throw StateError('Invalid range $rawStart-$rhs: end must be >= start.');
      }
      rawEnd = rhs;
    }
  }
  return LineRange(rawStart, rawEnd);
}

/// Parses a comma-separated list of line ranges (e.g. `5-16,960-973`).
/// Returns the ranges in ascending order with overlapping/adjacent ranges
/// merged so downstream consumers can stream the file in a single forward
/// pass per range. Returns null when any chunk is not range-shaped.
List<LineRange>? parseLineRanges(String sel) {
  final chunks = sel.split(',');
  final parsed = <LineRange>[];
  for (final chunk in chunks) {
    final range = parseLineRangeChunk(chunk);
    if (range == null) return null;
    parsed.add(range);
  }
  if (parsed.isEmpty) return null;
  parsed.sort((a, b) => a.startLine.compareTo(b.startLine));

  final merged = <LineRange>[parsed[0]];
  for (var i = 1; i < parsed.length; i++) {
    final current = parsed[i];
    final last = merged.last;
    // Open-ended (endLine null) means "to EOF" — any later range is absorbed.
    if (last.endLine == null) continue;
    // Merge when current starts within (or immediately after) the last range.
    if (current.startLine <= last.endLine! + 1) {
      final currentEnd = current.endLine;
      if (currentEnd == null || currentEnd > last.endLine!) {
        merged[merged.length - 1] = LineRange(last.startLine, currentEnd);
      }
      continue;
    }
    merged.add(current);
  }
  return merged;
}

/// Result of splitting a read path into its filesystem path and an optional
/// trailing selector string (omp's `{ path, sel? }`).
final class SplitReadPath {
  /// Creates a split result.
  const SplitReadPath(this.path, [this.sel]);

  /// The path with any selector peeled off.
  final String path;

  /// The trailing selector (without the colon), or null when none peeled.
  final String? sel;
}

/// Splits a trailing `:sel` off [rawPath] when the tail matches the selector
/// grammar (a range list or `raw`, optionally one of each in either order —
/// `path:1-50:raw` / `path:raw:1-50`). Anything else stays part of the path
/// so archive and SQLite targets keep their colon syntax.
SplitReadPath splitPathAndSel(String rawPath) {
  final colon = rawPath.lastIndexOf(':');
  if (colon <= 0) return SplitReadPath(rawPath);

  final candidate = rawPath.substring(colon + 1);
  if (!_fileLineRangeRe.hasMatch(candidate)) return SplitReadPath(rawPath);

  var basePath = rawPath.substring(0, colon);
  var sel = candidate;

  // Allow a compound trailing selector: `path:1-50:raw` or `path:raw:1-50`.
  // The two chunks must be one line-range plus one `raw`, in either order.
  final innerColon = basePath.lastIndexOf(':');
  if (innerColon > 0) {
    final innerCandidate = basePath.substring(innerColon + 1);
    final innerIsRaw = _fileRawOnlyRe.hasMatch(innerCandidate);
    final outerIsRaw = _fileRawOnlyRe.hasMatch(candidate);
    final innerIsRange = _fileLineRangeOnlyRe.hasMatch(innerCandidate);
    final outerIsRange = _fileLineRangeOnlyRe.hasMatch(candidate);
    if ((innerIsRaw && outerIsRange) || (innerIsRange && outerIsRaw)) {
      sel = '$innerCandidate:$candidate';
      basePath = basePath.substring(0, innerColon);
    }
  }

  return SplitReadPath(basePath, sel);
}

/// Async sibling of [splitPathAndSel] that prefers a literal filesystem path
/// over selector interpretation (omp's `splitPathAndSelPreferringLiteral`,
/// issue #4618): filenames whose tail matches the selector grammar (e.g.
/// `test:1-2`, `log:raw`) are legal on POSIX; without this the strict
/// splitter peels the tail and `read` refuses to open the real file. The
/// literal wins whenever [env] reports the raw path exists — and also when
/// the existence check itself fails — so an unreachable literal is never
/// silently reinterpreted as `path + selector`.
Future<SplitReadPath> splitPathAndSelPreferringLiteral(
  String rawPath,
  FileSystem env,
) async {
  final strict = splitPathAndSel(rawPath);
  if (strict.sel == null) return strict;
  final probe = await env.exists(rawPath);
  // Ok(true)  → the literal file exists; keep it.
  // Err       → ambiguous backend failure; keep the literal (fail-safe).
  // Ok(false) → definitive miss; fall back to the strict split.
  final literalExists = probe.valueOrNull ?? true;
  return literalExists ? SplitReadPath(rawPath) : strict;
}

/// The parsed trailing selector of a read path (omp's `ParsedSelector`).
sealed class ReadSelector {
  const ReadSelector();
}

/// No selector (or an unrecognized one left for archive/SQLite/URL readers).
final class ReadSelectorNone extends ReadSelector {
  /// Creates the empty selector.
  const ReadSelectorNone();
}

/// `:raw` alone — verbatim whole-resource output.
final class ReadSelectorRaw extends ReadSelector {
  /// Creates the raw selector.
  const ReadSelectorRaw();
}

/// One or more (sorted, merged) line ranges, optionally with raw output
/// (`:range:raw` / `:raw:range`).
final class ReadSelectorLines extends ReadSelector {
  /// Creates a line-range selector.
  const ReadSelectorLines(this.ranges, {this.raw = false});

  /// Ranges in ascending order, overlapping/adjacent ranges merged.
  final List<LineRange> ranges;

  /// Whether raw (verbatim) output was requested alongside the ranges.
  final bool raw;
}

bool _selectorChunkLooksReadLike(String chunk) {
  final lower = chunk.toLowerCase();
  return lower == 'raw' ||
      RegExp(r'^-\d+(?:[-+]\d+)?$').hasMatch(chunk) ||
      parseLineRanges(chunk) != null;
}

StateError _invalidSelector(String sel) {
  return StateError(
    "Invalid selector ':$sel'. Use :N, :N-M, :N+K, :N- (open-ended), a "
    'comma-separated list of ranges, :raw, or a range combined with raw '
    '(e.g. :raw:50-100).',
  );
}

/// Parses a selector string (as returned by [SplitReadPath.sel]) into a
/// [ReadSelector]. Unrecognized selectors fall through to
/// [ReadSelectorNone] — archive/SQLite readers consume their own colon
/// syntax — but compounds that LOOK read-like yet are malformed throw
/// (omp's `invalidSelector`), so a mistyped selector never silently widens
/// into a whole-file read.
ReadSelector parseSel(String? sel) {
  if (sel == null || sel.isEmpty) return const ReadSelectorNone();

  // Compound selector: `1-50:raw` or `raw:1-50`. Split into chunks and accept
  // exactly one line range (possibly multi) plus the literal `raw`.
  if (sel.contains(':')) {
    final chunks = sel.split(':');
    if (chunks.length == 2) {
      final a = chunks[0];
      final b = chunks[1];
      final aIsRaw = a.toLowerCase() == 'raw';
      final bIsRaw = b.toLowerCase() == 'raw';
      final rangeChunk = aIsRaw ? b : (bIsRaw ? a : null);
      if (rangeChunk != null) {
        final ranges = parseLineRanges(rangeChunk);
        if (ranges != null) {
          return ReadSelectorLines(ranges, raw: true);
        }
      }
    }
    if (chunks.every(_selectorChunkLooksReadLike)) throw _invalidSelector(sel);
    // Unrecognized compound — fall through (sqlite/archive consume their own
    // colon syntax).
    return const ReadSelectorNone();
  }

  if (sel.toLowerCase() == 'raw') return const ReadSelectorRaw();
  final ranges = parseLineRanges(sel);
  if (ranges != null) {
    return ReadSelectorLines(ranges);
  }
  // Unrecognized selectors fall through; sqlite/archive readers consume
  // their own colon syntax.
  return const ReadSelectorNone();
}

/// Whether the selector requested verbatim/raw output (alone or combined
/// with a range) — omp's `isRawSelector`.
bool isRawSelector(ReadSelector parsed) {
  return parsed is ReadSelectorRaw ||
      (parsed is ReadSelectorLines && parsed.raw);
}
