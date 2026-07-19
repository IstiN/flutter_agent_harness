/// Hashline format primitives: sigils, separators, regex fragments, and
/// display helpers, ported from oh-my-pi `packages/hashline/src/format.ts`.
/// These are the single source of truth for the parser, the patcher, and the
/// tool prompts.
library;

import 'dart:convert';

import 'xxhash32.dart';

/// File-section header delimiters: `[path#hash]`.
const hlFilePrefix = '[';
const hlFileSuffix = ']';

/// Payload sigil for literal body rows.
const hlPayloadReplace = '+';

/// Hunk-header keyword for concrete line replacement.
const hlReplaceKeyword = 'SWAP';

/// Hunk-header keyword for concrete line deletion.
const hlDeleteKeyword = 'DEL';

/// Hunk-header keyword for insertion operations.
const hlInsertKeyword = 'INS';

/// Insert position keyword for inserting before a concrete line.
const hlInsertBefore = 'PRE';

/// Insert position keyword for inserting after a concrete line.
const hlInsertAfter = 'POST';

/// Insert position keyword for inserting at the start of the file.
const hlInsertHead = 'HEAD';

/// Insert position keyword for inserting at the end of the file.
const hlInsertTail = 'TAIL';

/// Hunk-header keyword: `SWAP.BLK N:` (tree-sitter block replace; recognized
/// by the parser but rejected as unsupported by this port).
const hlReplaceBlockKeyword = 'SWAP.BLK';

/// Hunk-header keyword: `DEL.BLK N` (tree-sitter block delete; unsupported).
const hlDeleteBlockKeyword = 'DEL.BLK';

/// Hunk-header keyword: `INS.BLK.POST N:` (insert after a tree-sitter block;
/// unsupported).
const hlInsertAfterBlockKeyword = 'INS.BLK.POST';

/// File-level keyword: `REM` deletes the whole file (unsupported).
const hlRemKeyword = 'REM';

/// File-level keyword: `MV DEST` moves the file (unsupported).
const hlMoveKeyword = 'MV';

/// Colon terminating a hunk header that takes a body.
const hlHeaderColon = ':';

/// Separator between a hashline file path and its snapshot tag.
const hlFileHashSep = '#';

/// Separator between two line numbers in a range, e.g. `5.=10`.
const hlRangeSep = '.=';

/// Separator between a line number and displayed line content in hashline
/// mode.
const hlLineBodySep = ':';

/// Number of hex characters in a content-derived file-hash tag.
const hlFileHashLength = 4;

/// Canonical uppercase hexadecimal content-hash tag carried by a hashline
/// section header.
const hlFileHashReRaw = '[0-9A-F]{$hlFileHashLength}';

/// Representative file-hash tags for use in user-facing error messages and
/// prompt examples.
const hlFileHashExamples = ['1A2B', '3C4D', '9F3E'];

/// Trailing `[ \t\r]` run at end-of-line, used to normalize text before
/// hashing so CRLF endings and display-trimmed lines do not invalidate a tag.
final _trailingWhitespaceRe = RegExp(r'[ \t\r]+(?=\n|$)');

/// Computes the content-derived hash tag carried by a hashline section
/// header: the low 16 bits of xxHash32 (seed 0) over the UTF-8 bytes of the
/// normalized text, as 4 uppercase hex characters.
///
/// Ported from omp's `computeFileHash`: any read of byte-identical content
/// mints the same tag, and a follow-up edit anchored at any line validates
/// whenever the live file still hashes to it. Normalization trims trailing
/// `[ \t\r]` from every line in a single pass.
String computeFileHash(String text) {
  final normalized = text.replaceAll(_trailingWhitespaceRe, '');
  final low16 = xxHash32(utf8.encode(normalized)) & 0xFFFF;
  return low16.toRadixString(16).padLeft(hlFileHashLength, '0').toUpperCase();
}

/// Formats a comma-separated list of example anchors with an optional
/// line-number prefix, quoted for inclusion in error messages:
/// `"160", "42", "7"`.
String describeAnchorExamples([String linePrefix = '']) {
  final stem = linePrefix.length > 1
      ? linePrefix.substring(0, linePrefix.length - 1)
      : '4';
  final examples = linePrefix.isNotEmpty
      ? [linePrefix, '${stem}2', '7']
      : ['160', '42', '7'];
  return examples.map((e) => '"$e"').join(', ');
}

/// Formats a hashline section header for a file path and snapshot tag.
String formatHashlineHeader(String filePath, String fileHash) {
  return '$hlFilePrefix$filePath$hlFileHashSep$fileHash$hlFileSuffix';
}

/// Formats a single numbered line as `LINE:TEXT`.
String formatNumberedLine(int lineNumber, String line) {
  return '$lineNumber$hlLineBodySep$line';
}

/// Formats file text with hashline-mode line-number prefixes for display.
String formatNumberedLines(String text, [int startLine = 1]) {
  final lines = text.split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      formatNumberedLine(startLine + i, lines[i]),
  ].join('\n');
}
