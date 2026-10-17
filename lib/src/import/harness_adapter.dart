/// Adapter plumbing for the cross-harness importer (issue #1562): the
/// [HarnessAdapter] contract, the harness registry, and the shared
/// line-scanning / discovery helpers every adapter builds on.
///
/// Adapters are READ-ONLY over foreign stores: every operation here only
/// reads. Writes go through the FA session repo in [runImport] alone.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../env/execution_env.dart';
import 'foreign_session.dart';

/// The single ORDERED import-harness registry (issue #1562 review): every
/// surface derives from this one list — the `--harness` validation set
/// (`importHarnessNames` in cli_args.dart), the implemented-adapter set
/// below, and the TUI picker rows — so they cannot drift when the AC7
/// spike lands a kimi/opencode adapter. Order = picker order.
typedef ImportHarnessSpec = ({String id, String description, bool implemented});

const List<ImportHarnessSpec> importHarnessRegistry = [
  (
    id: 'omp',
    description: '~/.omp/agent/sessions — pinned format',
    implemented: true,
  ),
  (
    id: 'claude',
    description: '~/.claude/projects — partial pin (taxonomy spike open)',
    implemented: true,
  ),
  (
    id: 'opencode',
    description: 'pending format discovery spike',
    implemented: false,
  ),
  (
    id: 'kimi',
    description: 'pending format discovery spike',
    implemented: false,
  ),
];

/// Harnesses with a pinned format and a shipped adapter (kimi/opencode ship
/// only after their discovery spike, GOAL AC7/K1).
final implementedHarnesses = Set.unmodifiable({
  for (final harness in importHarnessRegistry)
    if (harness.implemented) harness.id,
});

/// The expected foreign store root for [harness] under [homeDir] — the path
/// exit 2 names (and the path an unpinned harness's message points at).
String expectedStoreRoot(String harness, String homeDir) => switch (harness) {
  'omp' => '$homeDir/.omp/agent/sessions',
  'kimi' => '$homeDir/.kimi',
  'opencode' => '$homeDir/.local/share/opencode',
  'claude' => '$homeDir/.claude/projects',
  _ => '$homeDir/.$harness',
};

/// One harness's foreign-session adapter: discovery (current folder only)
/// plus a full read of one session's active branch.
abstract interface class HarnessAdapter {
  /// The harness id (`omp`, `claude`).
  String get id;

  /// The store root under [homeDir] (for messages; never written).
  String storeRoot(String homeDir);

  /// The store root when it exists on [fs], else null (exit-2 class).
  Future<String?> existingRoot({
    required FileSystem fs,
    required String homeDir,
  });

  /// Discovers the sessions recorded for [cwd] (and only [cwd]) in this
  /// harness's store, newest first.
  ///
  /// Bucket matching is by slug COMPARE against the store's directory
  /// names — never by decoding a slug (dash-ambiguous, GOAL E12) — and the
  /// header cwd recorded inside each file is the tiebreak.
  Future<List<ForeignSessionSummary>> discover({
    required FileSystem fs,
    required String cwd,
    required String homeDir,
    required String tempDir,
    required ImportLimits limits,
  });

  /// Reads one session fully: the active (leaf-path) branch, root-first.
  Future<ForeignParseResult> read({
    required FileSystem fs,
    required ForeignSessionSummary summary,
    required String homeDir,
    required ImportLimits limits,
  });
}

/// One scanned JSONL line: [text] when decodable and within the line cap;
/// an oversized or malformed line carries null text (skip-with-count).
final class ForeignLine {
  const ForeignLine(this.number, this.text) : byteLength = null;

  /// An oversized line (over [ImportLimits.maxLineBytes]).
  const ForeignLine.overSized(this.number, this.byteLength) : text = null;

  /// An undecodable (non-UTF-8) line.
  const ForeignLine.malformed(this.number) : text = null, byteLength = null;

  /// 1-based line number.
  final int number;

  /// The decoded line, null when oversized/malformed.
  final String? text;

  /// Byte length for oversized lines.
  final int? byteLength;

  /// Whether the line was oversized.
  bool get isOverSized => byteLength != null;

  /// Whether the line could not be decoded as UTF-8.
  bool get isMalformed => text == null && byteLength == null;
}

/// Streams [path]'s lines one at a time, byte-bounded.
///
/// Ranged backends stream in 1 MiB chunks (complete lines only — bytes
/// carry across chunk borders), so memory stays bounded by the longest
/// line; plain backends fall back to a whole-file text read, still gated
/// by [ImportLimits.maxFileBytes].
Stream<ForeignLine> scanForeignLines(
  FileSystem fs,
  String path,
  ImportLimits limits,
) async* {
  final size = await _fileSize(fs, path);
  if (size < 0) throw ForeignFileError('unreadable file: $path');
  if (size > limits.maxFileBytes) {
    throw ForeignFileError(
      'file too large: $size bytes (limit ${limits.maxFileBytes})',
    );
  }
  if (fs is! RangedReadFileSystem) {
    yield* _scanWholeFileLines(fs, path, limits);
    return;
  }
  // The `is!` guard above proved the host is ranged-capable; the explicit
  // bind carries the member (FileSystem itself has no ranged reads).
  yield* _scanRangedLines(fs as RangedReadFileSystem, path, size, limits);
}

/// The non-ranged shape: one whole-file read, then line-split in memory.
Stream<ForeignLine> _scanWholeFileLines(
  FileSystem fs,
  String path,
  ImportLimits limits,
) async* {
  final read = await fs.readTextFile(path);
  if (read.isErr) throw ForeignFileError('unreadable file: $path');
  var number = 0;
  for (final line in const LineSplitter().convert(read.valueOrNull!)) {
    number++;
    final bytes = utf8.encode(line);
    yield bytes.length > limits.maxLineBytes
        ? ForeignLine.overSized(number, bytes.length)
        : ForeignLine(number, line);
  }
}

/// The ranged shape: bounded 1 MiB windows, lines stitched across chunk
/// boundaries via the carry buffer.
Stream<ForeignLine> _scanRangedLines(
  RangedReadFileSystem fs,
  String path,
  int size,
  ImportLimits limits,
) async* {
  const chunkBytes = 1 << 20;
  var position = 0;
  var number = 0;
  var carry = <int>[];
  while (position < size) {
    final end = position + chunkBytes < size ? position + chunkBytes : size;
    final read = await fs.readRange(path, position, end);
    if (read.isErr) throw ForeignFileError('unreadable file: $path');
    position = end;
    final bytes = read.valueOrNull ?? Uint8List(0);
    carry.addAll(bytes);
    var newline = carry.indexOf(0x0A);
    while (newline >= 0) {
      number++;
      yield _lineFromBytes(number, carry.sublist(0, newline), limits);
      carry = carry.sublist(newline + 1);
      newline = carry.indexOf(0x0A);
    }
  }
  if (carry.isNotEmpty) {
    number++;
    yield _lineFromBytes(number, carry, limits);
  }
}

ForeignLine _lineFromBytes(int number, List<int> bytes, ImportLimits limits) {
  if (bytes.isNotEmpty && bytes.last == 0x0D) {
    bytes = bytes.sublist(0, bytes.length - 1);
  }
  if (bytes.length > limits.maxLineBytes) {
    return ForeignLine.overSized(number, bytes.length);
  }
  try {
    return ForeignLine(number, utf8.decode(bytes));
  } on FormatException {
    return ForeignLine.malformed(number);
  }
}

Future<int> _fileSize(FileSystem fs, String path) async {
  final info = await fs.fileInfo(path);
  if (info.isErr || info.valueOrNull!.kind != FileKind.file) return -1;
  return info.valueOrNull!.size;
}

/// Lists the `*.jsonl` session files directly under [dir] (files only;
/// tombstones and sidecar dirs never match the `.jsonl` suffix rule),
/// newest mtime first.
Future<List<(String path, int size, int mtimeMs)>> listSessionFiles(
  FileSystem fs,
  String dir,
) async {
  final listed = await fs.listDir(dir);
  if (listed.isErr) return const [];
  final files = <(String path, int size, int mtimeMs)>[];
  for (final entry in listed.valueOrNull ?? const <FileInfo>[]) {
    if (entry.kind != FileKind.file) continue;
    if (!entry.name.endsWith('.jsonl')) continue;
    files.add((entry.path, entry.size, entry.mtimeMs));
  }
  files.sort((a, b) => b.$3.compareTo(a.$3));
  return files;
}

/// Whether [headerCwd] names [cwd]: trailing-slash-insensitive string
/// equality — the discovery tiebreak (GOAL E12: slugs are dash-ambiguous,
/// so discovery never decodes one).
bool headerCwdMatches(String headerCwd, String cwd) {
  String trimSlash(String path) => path.replaceAll(RegExp(r'[/\\]+$'), '');
  return trimSlash(headerCwd) == trimSlash(cwd) && headerCwd.isNotEmpty;
}

/// First-line preview text, ≤160 chars with an ellipsis (GOAL F11) and
/// newlines flattened.
String previewLine(String text) {
  final flat = text.replaceAll('\n', ' ').trim();
  return flat.length > 160 ? '${flat.substring(0, 160)}…' : flat;
}

/// The tree skeleton of one foreign file: a tree record (with id/parentId)
/// or an always-include line (title slot, header, aux records).
final class TreeShell {
  /// Creates a tree-record shell.
  const TreeShell(this.lineNumber, this.id, this.parentId) : isAux = false;

  /// Creates an always-include (non-tree) line shell.
  const TreeShell.aux(this.lineNumber)
    : id = null,
      parentId = null,
      isAux = true;

  /// 1-based source line number.
  final int lineNumber;

  /// The record id (null for aux lines).
  final String? id;

  /// The parent record id (null for roots and aux lines).
  final String? parentId;

  /// Whether the line is always included (title slot/header/aux records).
  final bool isAux;
}

/// Resolves the active branch the way omp's loader does (last entry is the
/// leaf; walk `parentId` to root, stopping on a repeated id to bound
/// corrupt cycles or a dangling parent): the id set of the leaf path, plus
/// how many tree records sit OFF the path (counted skipped).
({Set<String> pathIds, int skippedOffPath}) activeBranchIds(
  List<TreeShell> shells,
) {
  final byId = _treeById(shells);
  final leaf = _leafShell(shells);
  if (leaf == null) {
    return (pathIds: const <String>{}, skippedOffPath: 0);
  }
  final pathIds = _leafPath(leaf, byId);
  var skippedOffPath = 0;
  for (final shell in shells) {
    if (shell.isAux || shell.id == null) continue;
    if (!pathIds.contains(shell.id)) skippedOffPath++;
  }
  return (pathIds: pathIds, skippedOffPath: skippedOffPath);
}

/// The id → shell index of the tree records (aux lines excluded).
Map<String, TreeShell> _treeById(List<TreeShell> shells) => {
  for (final shell in shells)
    if (!shell.isAux && shell.id != null) shell.id!: shell,
};

/// The last tree line in file order — omp's loader treats it as the leaf.
TreeShell? _leafShell(List<TreeShell> shells) {
  for (final shell in shells.reversed) {
    if (!shell.isAux && shell.id != null) return shell;
  }
  return null;
}

/// The id set of the leaf path, walking [TreeShell.parentId] to root and
/// stopping on a repeated id to bound corrupt cycles or a dangling parent.
Set<String> _leafPath(TreeShell leaf, Map<String, TreeShell> byId) {
  final pathIds = <String>{};
  final visited = <String>{};
  TreeShell? current = leaf;
  while (current != null && !current.isAux && current.id != null) {
    if (!visited.add(current.id!)) break;
    pathIds.add(current.id!);
    final parent = current.parentId;
    current = parent == null ? null : byId[parent];
  }
  return pathIds;
}

/// Decodes one JSONL line into a JSON object, or null when the line is not
/// a JSON object (caller counts the skip).
Map<String, dynamic>? decodeJsonLine(String line) {
  try {
    final decoded = jsonDecode(line);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}
