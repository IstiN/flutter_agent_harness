// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of sandbox_builtins.dart: unified-diff computation and patch (unified
// diff) parsing helpers backing the diff/patch builtins. Same library, private
// members resolve.

part of 'sandbox_builtins.dart';

// ---------------------------------------------------------------------------
// diff/patch helpers
// ---------------------------------------------------------------------------

/// A text file viewed as lines: the line contents (without terminators),
/// whether the file ends with a newline, and the comparison tokens that make
/// a missing trailing newline visible to the diff.
final class _LineDoc {
  _LineDoc(String content)
    : trailingNewline = content.isEmpty || content.endsWith('\n'),
      lines = _splitLines(content) {
    tokens = trailingNewline || lines.isEmpty
        ? lines
        : [...lines.sublist(0, lines.length - 1), '${lines.last}\x00'];
  }

  static List<String> _splitLines(String content) {
    if (content.isEmpty) return const [];
    final lines = content.split('\n');
    if (content.endsWith('\n')) lines.removeLast();
    return lines;
  }

  /// Line contents without line terminators.
  final List<String> lines;

  /// Whether the file ends with a newline.
  final bool trailingNewline;

  /// Line tokens for comparison; the `\x00` sentinel suffix marks a last
  /// line without a trailing newline so it differs from its terminated twin.
  late final List<String> tokens;
}

/// One line operation in a computed diff: [context] lines are present in
/// both files, [delete] lines only in the old file, [insert] lines only in
/// the new file.
enum _DiffOpKind { context, delete, insert }

/// A single line operation with its position in both files.
final class _DiffOp {
  const _DiffOp({
    required this.kind,
    required this.oldIndex,
    required this.newIndex,
    required this.oldBefore,
    required this.newBefore,
  });

  final _DiffOpKind kind;

  /// Index into the old/new token list ([oldIndex] is -1 for inserts,
  /// [newIndex] is -1 for deletes).
  final int oldIndex;
  final int newIndex;

  /// Number of old/new lines consumed before this op; used in hunk headers.
  final int oldBefore;
  final int newBefore;
}

/// Computes the line op sequence transforming [oldTokens] into [newTokens]
/// with the Myers algorithm from `package:diffutil_dart`. The package emits
/// RecyclerView-style updates; replaying them over a list of old line
/// indices yields the old→new line mapping.
List<_DiffOp> _diffOps(List<String> oldTokens, List<String> newTokens) {
  final result = diffutil.calculateListDiff<String>(
    oldTokens,
    newTokens,
    detectMoves: false,
  );
  // Replay the updates. Tokens hold the old line index, or -1 for inserted
  // lines. With string line equality and no move detection only Insert and
  // Remove updates are ever produced.
  final replay = [for (var i = 0; i < oldTokens.length; i++) i];
  for (final update in result.getUpdates(batch: false)) {
    switch (update) {
      case diffutil.Insert(:final position, :final count):
        replay.insertAll(position, List.filled(count, -1));
      case diffutil.Remove(:final position, :final count):
        for (var k = 0; k < count; k++) {
          replay.removeAt(position);
        }
      case diffutil.Change() || diffutil.Move():
        throw StateError('unexpected diff update: $update');
    }
  }
  final oldToNew = List.filled(oldTokens.length, -1);
  final newToOld = List.filled(newTokens.length, -1);
  for (var j = 0; j < replay.length; j++) {
    final oldIndex = replay[j];
    if (oldIndex >= 0) {
      oldToNew[oldIndex] = j;
      newToOld[j] = oldIndex;
    }
  }
  final ops = <_DiffOp>[];
  var i = 0;
  var j = 0;
  while (i < oldTokens.length || j < newTokens.length) {
    if (i < oldTokens.length && oldToNew[i] == -1) {
      ops.add(
        _DiffOp(
          kind: _DiffOpKind.delete,
          oldIndex: i,
          newIndex: -1,
          oldBefore: i,
          newBefore: j,
        ),
      );
      i++;
    } else if (j < newTokens.length && newToOld[j] == -1) {
      ops.add(
        _DiffOp(
          kind: _DiffOpKind.insert,
          oldIndex: -1,
          newIndex: j,
          oldBefore: i,
          newBefore: j,
        ),
      );
      j++;
    } else {
      ops.add(
        _DiffOp(
          kind: _DiffOpKind.context,
          oldIndex: i,
          newIndex: j,
          oldBefore: i,
          newBefore: j,
        ),
      );
      i++;
      j++;
    }
  }
  return ops;
}

/// Finds the extent of the next unified-diff hunk starting at or after
/// [start]: skips leading context, then extends while changes are
/// separated by at most 2*context context lines (a larger gap starts a
/// new hunk). Returns (hunkStart, hunkEnd) with hunkEnd exclusive, or
/// null when no changes remain.
(int, int)? _nextHunkExtent(List<_DiffOp> ops, int start, int context) {
  var change = start;
  while (change < ops.length && ops[change].kind == _DiffOpKind.context) {
    change++;
  }
  if (change == ops.length) return null;
  final hunkStart = change - context > 0 ? change - context : 0;
  var lastChange = change;
  var j = change + 1;
  while (j < ops.length) {
    if (ops[j].kind != _DiffOpKind.context) {
      lastChange = j;
      j++;
    } else if (j - lastChange > 2 * context) {
      break;
    } else {
      j++;
    }
  }
  var hunkEnd = lastChange + context + 1;
  if (hunkEnd > ops.length) hunkEnd = ops.length;
  return (hunkStart, hunkEnd);
}

/// Renders [ops] as a unified diff with `---`/`+++` file headers and
/// `@@ -a,b +c,d @@` hunks with [context] lines of context, mirroring
/// `diff -u` (including `\ No newline at end of file` markers).
String _formatUnified(
  List<_DiffOp> ops,
  List<String> oldTokens,
  List<String> newTokens, {
  required String oldLabel,
  required String newLabel,
  required int context,
}) {
  final out = StringBuffer()
    ..writeln('--- $oldLabel')
    ..writeln('+++ $newLabel');
  var i = 0;
  while (true) {
    final extent = _nextHunkExtent(ops, i, context);
    if (extent == null) break;
    final (hunkStart, hunkEnd) = extent;

    var oldCount = 0;
    var newCount = 0;
    for (var k = hunkStart; k < hunkEnd; k++) {
      if (ops[k].kind != _DiffOpKind.insert) oldCount++;
      if (ops[k].kind != _DiffOpKind.delete) newCount++;
    }
    final first = ops[hunkStart];
    final oldStart = oldCount == 0 ? first.oldBefore : first.oldBefore + 1;
    final newStart = newCount == 0 ? first.newBefore : first.newBefore + 1;
    out.writeln(
      '@@ -${_hunkRange(oldStart, oldCount)} '
      '+${_hunkRange(newStart, newCount)} @@',
    );
    for (var k = hunkStart; k < hunkEnd; k++) {
      final op = ops[k];
      final token = op.kind == _DiffOpKind.insert
          ? newTokens[op.newIndex]
          : oldTokens[op.oldIndex];
      final noNewline = token.endsWith('\x00');
      final text = noNewline ? token.substring(0, token.length - 1) : token;
      final prefix = switch (op.kind) {
        _DiffOpKind.context => ' ',
        _DiffOpKind.delete => '-',
        _DiffOpKind.insert => '+',
      };
      out.writeln('$prefix$text');
      if (noNewline) out.writeln('\\ No newline at end of file');
    }
    i = hunkEnd;
  }
  return out.toString();
}

/// Formats one hunk range; a single-line range omits the count like GNU diff.
String _hunkRange(int start, int count) {
  return count == 1 ? '$start' : '$start,$count';
}

/// One file section of a parsed unified diff.
final class _PatchFile {
  const _PatchFile({
    required this.oldName,
    required this.newName,
    required this.hunks,
  });

  final String oldName;
  final String newName;
  final List<_PatchHunk> hunks;

  /// The file to patch: the new name, unless the patch deletes the file.
  String get targetName => newName == '/dev/null' ? oldName : newName;

  /// Whether the patch creates the file (old name is `/dev/null`).
  bool get createsFile => oldName == '/dev/null';

  /// Whether the patch deletes the file (new name is `/dev/null`).
  bool get deletesFile => newName == '/dev/null';
}

/// One parsed `@@` hunk: header coordinates plus the raw body lines
/// (including `\ No newline at end of file` markers).
final class _PatchHunk {
  const _PatchHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.body,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> body;
}
/// Reads one hunk body of [oldCount]/[newCount] lines from [lines]
/// starting at [i] (hunk-header already consumed). Returns the body lines
/// (including `\ No newline` markers) and the index after the body, or
/// null on structural malformation.
(List<String>, int)? _parseHunkBody(
  List<String> lines,
  int i,
  int oldCount,
  int newCount,
) {
  final body = <String>[];
  var oldSeen = 0;
  var newSeen = 0;
  while (oldSeen < oldCount || newSeen < newCount) {
    if (i >= lines.length) return null;
    final line = lines[i];
    final kind = line.isEmpty ? ' ' : line[0];
    if (kind == '\\') {
      body.add(line);
      i++;
      continue;
    }
    if (kind != ' ' && kind != '-' && kind != '+') return null;
    body.add(line);
    if (kind != '+') oldSeen++;
    if (kind != '-') newSeen++;
    i++;
  }
  // A `\ No newline at end of file` marker can follow the last counted
  // body line.
  while (i < lines.length && lines[i].startsWith('\\')) {
    body.add(lines[i]);
    i++;
  }
  return (body, i);
}

final _hunkHeaderPattern = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

/// Parses unified-diff [text] into per-file sections. Preamble lines (such
/// as `diff --git` or `index` lines from git) are skipped; hunk bodies are
/// read by line count, so surrounding garbage cannot corrupt a hunk.
/// Returns null when the input is structurally malformed.
List<_PatchFile>? _parsePatch(String text) {
  final lines = text.split('\n');
  final files = <_PatchFile>[];
  var i = 0;
  while (i < lines.length) {
    if (!lines[i].startsWith('--- ')) {
      i++;
      continue;
    }
    final oldName = _patchFileName(lines[i].substring(4));
    i++;
    if (i >= lines.length || !lines[i].startsWith('+++ ')) return null;
    final newName = _patchFileName(lines[i].substring(4));
    i++;
    final hunks = <_PatchHunk>[];
    while (i < lines.length && lines[i].startsWith('@@ ')) {
      final match = _hunkHeaderPattern.firstMatch(lines[i]);
      if (match == null) return null;
      final oldStart = int.parse(match[1]!);
      final oldCount = match[2] != null ? int.parse(match[2]!) : 1;
      final newStart = int.parse(match[3]!);
      final newCount = match[4] != null ? int.parse(match[4]!) : 1;
      final parsed = _parseHunkBody(lines, i + 1, oldCount, newCount);
      if (parsed == null) return null;
      final (body, next) = parsed;
      i = next;
      hunks.add(
        _PatchHunk(
          oldStart: oldStart,
          oldCount: oldCount,
          newStart: newStart,
          newCount: newCount,
          body: body,
        ),
      );
    }
    files.add(_PatchFile(oldName: oldName, newName: newName, hunks: hunks));
  }
  return files;
}

/// Extracts the file name from a `---`/`+++` header line, dropping a
/// tab-separated timestamp when present.
String _patchFileName(String header) {
  final tab = header.indexOf('\t');
  return (tab >= 0 ? header.substring(0, tab) : header).trim();
}

/// Applies the `-p` strip level to [name]: removes [strip] leading path
/// components while preserving an absolute-path leading slash.
String _stripPath(String name, int strip) {
  final absolute = name.startsWith('/');
  final segments = name
      .split('/')
      .where((s) => s.isNotEmpty && s != '.')
      .toList();
  if (segments.length <= strip) return '';
  final stripped = segments.sublist(strip).join('/');
  return absolute ? '/$stripped' : stripped;
}

/// Splits one hunk's body into its old-side lines, new-side lines, and
/// the no-newline markers: a `\ No newline` marker after `-` applies to
/// the old file, after `+` to the new file, after ` ` (or an empty
/// previous context) to both.
({
  List<String> oldPart,
  List<String> newPart,
  bool markerOld,
  bool markerNew,
})
_hunkParts(List<String> body) {
  final oldPart = <String>[];
  final newPart = <String>[];
  var markerOld = false;
  var markerNew = false;
  String? previousKind;
  for (final bodyLine in body) {
    final kind = bodyLine.isEmpty ? ' ' : bodyLine[0];
    if (kind == '\\') {
      if (previousKind == '-') {
        markerOld = true;
      } else if (previousKind == '+') {
        markerNew = true;
      } else if (previousKind == ' ') {
        markerOld = true;
        markerNew = true;
      }
      continue;
    }
    final text = bodyLine.isEmpty ? '' : bodyLine.substring(1);
    if (kind != '+') oldPart.add(text);
    if (kind != '-') newPart.add(text);
    previousKind = kind;
  }
  return (
    oldPart: oldPart,
    newPart: newPart,
    markerOld: markerOld,
    markerNew: markerNew,
  );
}

/// Applies [hunks] to [doc], searching for each hunk's position with a
/// growing offset from the header position (no fuzz). Failed hunks are
/// skipped and reported by 1-based number; the file content is left
/// partially patched in that case, and the caller decides not to write it.
({List<String> lines, bool trailingNewline, List<int> failures}) _applyHunks(
  _LineDoc doc,
  List<_PatchHunk> hunks,
) {
  final lines = [...doc.lines];
  var trailingNewline = doc.trailingNewline;
  final failures = <int>[];
  var shift = 0;
  for (var h = 0; h < hunks.length; h++) {
    final hunk = hunks[h];
    final (:oldPart, :newPart, :markerOld, :markerNew) = _hunkParts(hunk.body);
    final start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1;
    final position = _findHunkPosition(lines, oldPart, start + shift);
    if (position == null) {
      failures.add(h + 1);
      continue;
    }
    lines.replaceRange(position, position + oldPart.length, newPart);
    // Track the drift between original and current coordinates so later
    // hunk positions stay meaningful after inserts/deletes and offsets.
    shift = position + newPart.length - (start + hunk.oldCount);
    if (markerNew) trailingNewline = false;
    if (markerOld && !markerNew) trailingNewline = true;
  }
  return (lines: lines, trailingNewline: trailingNewline, failures: failures);
}

/// Finds the position where [oldPart] matches [lines], trying [expected]
/// first and then growing offsets in both directions (like GNU patch,
/// without fuzz). Returns null when the hunk applies nowhere.
int? _findHunkPosition(List<String> lines, List<String> oldPart, int expected) {
  bool matches(int position) {
    if (position < 0 || position + oldPart.length > lines.length) {
      return false;
    }
    for (var k = 0; k < oldPart.length; k++) {
      if (lines[position + k] != oldPart[k]) return false;
    }
    return true;
  }

  final limit = lines.length + expected.abs() + 1;
  for (var distance = 0; distance <= limit; distance++) {
    if (matches(expected + distance)) return expected + distance;
    if (distance > 0 && matches(expected - distance)) {
      return expected - distance;
    }
  }
  return null;
}

/// Joins [lines] back into file content, honoring [trailingNewline].
String _joinLines(List<String> lines, bool trailingNewline) {
  if (lines.isEmpty) return '';
  final joined = lines.map((line) => '$line\n').join();
  return trailingNewline ? joined : joined.substring(0, joined.length - 1);
}
