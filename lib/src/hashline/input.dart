/// Top-level patch parser, ported from oh-my-pi
/// `packages/hashline/src/input.ts`. Splits an authored hashline input into a
/// list of [HashlinePatchSection]s, each rooted at a `[PATH#HASH]` header.
///
/// The splitter is purely lexical — it doesn't know whether a section's path
/// actually exists. That's the patcher's job.
///
/// Divergence from omp: absolute-to-cwd-relative path normalization is not
/// ported (our [ExecutionEnv] resolves paths itself); `MV DEST` normalization
/// is dropped with the rest of the `MV` support.
library;

import 'apply.dart';
import 'format.dart';
import 'messages.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'types.dart';

/// Strips apply_patch-style noise that models reflexively prepend to the
/// path: `Update File:foo.ts`, `Add File:foo.ts`, `***foo.ts`, and variants.
final _applyPatchPathNoiseRe = RegExp(
  r'^\*{0,3}\s*(?:(?:update|add|delete|move)[^A-Za-z0-9]*(?:file|to)?'
  r'[^A-Za-z0-9]*:)?\s*\*{0,3}\s*',
  caseSensitive: false,
);

String _stripApplyPatchPathNoise(String pathText) {
  return pathText.replaceFirst(_applyPatchPathNoiseRe, '');
}

String _normalizeHashlinePath(String rawPath) {
  return _stripApplyPatchPathNoise(unquoteHashlinePath(rawPath.trim()));
}

final class _RawSection {
  _RawSection({required this.path, this.fileHash, required this.diff});
  final String path;
  final String? fileHash;
  final String diff;
}

/// Best-effort recovery for bracketed header lines the strict tokenizer
/// rejects. Strips apply_patch keyword noise (`Update File:`, etc.) and an
/// extra leading `***`, then expects `PATH(#HASH)?`. Returns `null` when no
/// clean path can be salvaged.
_RawSection? _tryParseRecoveryHeader(String line) {
  if (!line.startsWith(hlFilePrefix) || !line.endsWith(hlFileSuffix)) {
    return null;
  }
  final body = _stripApplyPatchPathNoise(
    line.substring(1, line.length - 1).trim(),
  );
  if (body.isEmpty) return null;

  // Trailing `#XXXX` is the tag; everything before it is the path. The path
  // may contain whitespace, so anchor the tag at end-of-body.
  final trailing = RegExp(
    '#([0-9A-Fa-f]{$hlFileHashLength})\\s*\$',
  ).firstMatch(body);
  String pathText;
  String? fileHash;
  if (trailing != null) {
    pathText = body.substring(0, trailing.start);
    fileHash = trailing[1]!.toUpperCase();
  } else {
    pathText = body.replaceAll(RegExp(r'\s+$'), '');
  }

  // Same rule as the strict tokenizer: `#` is the path/tag separator and is
  // not allowed inside filenames.
  if (pathText.contains('#')) return null;

  final path = _normalizeHashlinePath(pathText);
  if (path.isEmpty) return null;
  return _RawSection(path: path, fileHash: fileHash, diff: '');
}

/// Parses a `[PATH]` or `[PATH#hash]` header line. Returns `null` for lines
/// that do not start with `[`. Throws the strict "Input header must be …"
/// error when a bracketed line fails the strict shape.
_RawSection? _parseHashlineHeaderLine(String line) {
  final trimmed = line.trimRight();
  if (!trimmed.startsWith(hlFilePrefix)) return null;

  final token = classifyHashlineLine(trimmed, 0);
  if (token is! HashlineHeaderToken) {
    final recovered = _tryParseRecoveryHeader(trimmed);
    if (recovered != null) return recovered;
    throw HashlineFormatException(
      'Input header must be [PATH] or [PATH${hlFileHashSep}TAG] with a '
      '$hlFileHashLength-hex content-hash tag; got ${repr(trimmed)}.',
    );
  }

  final parsedPath = _normalizeHashlinePath(token.path);
  if (parsedPath.isEmpty) {
    throw const HashlineFormatException(
      'Input header "[]" is empty; provide a file path.',
    );
  }
  return _RawSection(path: parsedPath, fileHash: token.fileHash, diff: '');
}

String _stripLeadingBlankLines(String input) {
  final stripped = input.startsWith('\uFEFF') ? input.substring(1) : input;
  final lines = stripped.split('\n');
  while (lines.isNotEmpty) {
    final head = lines[0].replaceAll(RegExp(r'\r$'), '');
    final token = classifyHashlineLine(head, 0);
    if (head.trim().isEmpty || token is HashlineEnvelopeBeginToken) {
      lines.removeAt(0);
      continue;
    }
    break;
  }
  return lines.join('\n');
}

/// Returns true when the input contains at least one line that the tokenizer
/// recognizes as a hashline op.
bool containsRecognizableHashlineOperations(String input) {
  for (final line in input.split(RegExp(r'\r?\n'))) {
    if (isHashlineOp(line)) return true;
  }
  return false;
}

String _normalizeFallbackInput(String input, String? fallbackPath) {
  final stripped = input.startsWith('\uFEFF') ? input.substring(1) : input;
  final hasExplicitHeader = stripped
      .split(RegExp(r'\r?\n'))
      .any((rawLine) => _parseHashlineHeaderLine(rawLine) != null);
  if (hasExplicitHeader) return input;

  if (fallbackPath == null || !containsRecognizableHashlineOperations(input)) {
    return input;
  }
  final path = _normalizeHashlinePath(fallbackPath);
  if (path.isEmpty) return input;
  return '$hlFilePrefix$path$hlFileSuffix\n$input';
}

List<_RawSection> _splitRawSections(String input, String? fallbackPath) {
  final stripped = _stripLeadingBlankLines(
    _normalizeFallbackInput(input, fallbackPath),
  );
  final lines = stripped.split(RegExp(r'\r?\n'));
  final firstLine = lines.isEmpty ? '' : lines[0];

  if (_parseHashlineHeaderLine(firstLine) == null) {
    // Catch unified-diff hunk-header contamination on the first line so the
    // model sees a focused error.
    final firstTrimmed = firstLine.trimRight();
    if (RegExp(
      r'^@@\s+[-+]?\d+,\d+\s+[-+]?\d+,\d+\s+@@',
    ).hasMatch(firstTrimmed)) {
      throw const HashlineFormatException(
        'unified-diff hunk header (`@@ -N,M +N,M @@`) is not valid in '
        'hashline. File sections start with `[path#HASH]`; use `SWAP`, '
        '`DEL`, or `INS` ops.',
      );
    }
    final previewSource = firstLine.length > 120
        ? firstLine.substring(0, 120)
        : firstLine;
    throw HashlineFormatException(
      'input must begin with "[PATH${hlFileHashSep}HASH]" on the first '
      'non-blank line for anchored edits; got: ${repr(previewSource)}. '
      'Example: "[src/foo.ts$hlFileHashSep${hlFileHashExamples[0]}]" then '
      'edit ops.',
    );
  }

  final sections = <_RawSection>[];
  _RawSection? current;
  var currentLines = <String>[];

  void flush() {
    final section = current;
    if (section == null) return;
    final hasOps = currentLines.any((line) => line.trim().isNotEmpty);
    if (hasOps) {
      sections.add(
        _RawSection(
          path: section.path,
          fileHash: section.fileHash,
          diff: currentLines.join('\n'),
        ),
      );
    }
    currentLines = [];
  }

  for (final line in lines) {
    final trimmed = line.trimRight();
    final token = classifyHashlineLine(line, 0);
    if (token is HashlineEnvelopeEndToken || token is HashlineAbortToken) {
      break;
    }
    if (token is HashlineEnvelopeBeginToken) continue;

    // Route every bracket-prefixed line through _parseHashlineHeaderLine so
    // malformed headers still raise the strict diagnostic (the tokenizer
    // alone would silently classify them as payload).
    if (trimmed.startsWith(hlFilePrefix)) {
      final header = _parseHashlineHeaderLine(line);
      if (header != null) {
        flush();
        current = header;
        currentLines = [];
        continue;
      }
    }
    currentLines.add(line);
  }
  flush();
  return sections;
}

final class _SectionAccumulator {
  _SectionAccumulator(this.fileHash, this.diffs);
  String? fileHash;
  final List<String> diffs;
}

/// Collapses consecutive or interleaved sections targeting the same path
/// into a single section with concatenated diffs. Anchors authored against
/// the same file snapshot must be applied as one batch; otherwise the first
/// sub-edit shifts line numbers out from under the second's anchors and
/// validation fails. Path order is preserved by first occurrence.
List<_RawSection> _mergeSamePathSections(List<_RawSection> sections) {
  final byPath = <String, _SectionAccumulator>{};
  for (final section in sections) {
    final existing = byPath[section.path];
    if (existing != null) {
      if (existing.fileHash != null &&
          section.fileHash != null &&
          existing.fileHash != section.fileHash) {
        throw HashlineFormatException(
          'Conflicting hashline snapshot tags for ${section.path}: '
          '#${existing.fileHash} and #${section.fileHash}. Re-read the file '
          'and retry with one current header.',
        );
      }
      existing.fileHash ??= section.fileHash;
      existing.diffs.add(section.diff);
      continue;
    }
    byPath[section.path] = _SectionAccumulator(section.fileHash, [
      section.diff,
    ]);
  }
  return [
    for (final entry in byPath.entries)
      _RawSection(
        path: entry.key,
        fileHash: entry.value.fileHash,
        diff: entry.value.diffs.join('\n'),
      ),
  ];
}

/// One section of a parsed [HashlinePatch]: a target file plus the
/// lazily-parsed list of edits that should land on it.
final class HashlinePatchSection {
  HashlinePatchSection._({
    required this.path,
    required this.fileHash,
    required this.diff,
  });

  /// Section path as authored.
  final String path;

  /// The 4-hex snapshot tag from the section header, when present.
  final String? fileHash;

  /// The raw section body (ops + payload rows).
  final String diff;

  HashlineParseResult? _parsed;

  /// Parses this section's diff body. Cached: subsequent calls return the
  /// same result object.
  HashlineParseResult parse() => _parsed ??= parseHashlinePatch(diff);

  /// Parsed edits for this section.
  List<HashlineEdit> get edits => parse().edits;

  /// Warnings emitted during parsing of this section.
  List<String> get warnings => parse().warnings;

  /// True when at least one edit anchors to concrete file content. Pure
  /// `INS.HEAD:` / `INS.TAIL:` literal inserts do not count: those are safe
  /// to apply even when the tagged content drifted.
  bool get hasAnchorScopedEdit {
    return edits.any((edit) {
      if (edit is HashlineDelete) return true;
      final cursor = (edit as HashlineInsert).cursor;
      return cursor is HashlineCursorBefore || cursor is HashlineCursorAfter;
    });
  }

  /// Anchor lines touched by this section, sorted ascending and
  /// deduplicated.
  List<int> collectAnchorLines() {
    final lines = <int>{};
    for (final edit in edits) {
      switch (edit) {
        case HashlineDelete(:final anchor):
          lines.add(anchor.line);
        case HashlineInsert(:final cursor):
          switch (cursor) {
            case HashlineCursorBefore(:final anchor):
              lines.add(anchor.line);
            case HashlineCursorAfter(:final anchor):
              lines.add(anchor.line);
            default:
              break;
          }
      }
    }
    return lines.toList()..sort();
  }

  /// Applies this section's edits to [text] and returns the post-edit
  /// result. Pure: does no I/O and does not validate the snapshot tag. The
  /// [HashlinePatcher] owns tag validation; reach for this directly when
  /// you've already validated the file content.
  HashlineApplyResult applyTo(String text) {
    final parsed = parse();
    final result = applyHashlineEdits(text, parsed.edits);
    final merged = [...parsed.warnings, ...result.warnings];
    return HashlineApplyResult(
      text: result.text,
      firstChangedLine: result.firstChangedLine,
      warnings: merged,
    );
  }

  /// A copy of this section rebound to a different target [path],
  /// preserving the snapshot tag, diff body, and any cached parse result.
  /// Used by the patcher's tag-based path recovery.
  HashlinePatchSection withPath(String path) {
    final next = HashlinePatchSection._(
      path: path,
      fileHash: fileHash,
      diff: diff,
    );
    next._parsed = _parsed;
    return next;
  }
}

/// A parsed hashline patch — zero or more [HashlinePatchSection]s, each
/// rooted at a `[PATH#HASH]` header.
final class HashlinePatch {
  HashlinePatch._(this.sections);

  /// The parsed sections in patch order.
  final List<HashlinePatchSection> sections;

  /// Parses [input] into a [HashlinePatch]. [fallbackPath] provides a
  /// section path when the input lacks a header but contains recognizable
  /// hashline ops (omp's `SplitOptions.path`).
  static HashlinePatch parse(String input, {String? fallbackPath}) {
    final raw = _mergeSamePathSections(_splitRawSections(input, fallbackPath));
    return HashlinePatch._([
      for (final section in raw)
        HashlinePatchSection._(
          path: section.path,
          fileHash: section.fileHash,
          diff: section.diff,
        ),
    ]);
  }

  /// Parses [input] and returns only the first section. Throws if the input
  /// has zero sections.
  static HashlinePatchSection parseSingle(
    String input, {
    String? fallbackPath,
  }) {
    final patch = HashlinePatch.parse(input, fallbackPath: fallbackPath);
    if (patch.sections.isEmpty) {
      throw const HashlineFormatException(
        'Patch input did not produce any sections.',
      );
    }
    return patch.sections[0];
  }
}
