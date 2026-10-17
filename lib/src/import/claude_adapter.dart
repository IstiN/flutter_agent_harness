/// The claude harness adapter (issue #1562, GOAL C1-C2): discovery over
/// `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` and a leaf-path read
/// of one session's main message chain.
///
/// Sample-level pins (chief-fixed, GOAL format matrix): the cwd slug is the
/// path with `/`→`-`; one JSON object per line; observed types include
/// `last-prompt`, `permission-mode`, and message records carrying
/// `uuid`/`parentUuid`/`isSidechain`/`sessionId`. Main-chain records
/// (`isSidechain=false`, connected via `parentUuid`) import; sidechains are
/// excluded and counted (AC8/E13); everything unmapped lands as inert
/// custom data (AC6). The full taxonomy stays open for the AC7 spike.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import 'foreign_session.dart';
import 'harness_adapter.dart';

/// Reads sessions from the claude store, read-only.
final class ClaudeAdapter implements HarnessAdapter {
  @override
  String get id => 'claude';

  @override
  String storeRoot(String homeDir) => '$homeDir/.claude/projects';

  @override
  Future<String?> existingRoot({
    required FileSystem fs,
    required String homeDir,
  }) async {
    final root = storeRoot(homeDir);
    final exists = await fs.exists(root);
    final isDir =
        exists.valueOrNull == true &&
        (await fs.fileInfo(root)).valueOrNull?.kind == FileKind.directory;
    return isDir ? root : null;
  }

  @override
  Future<List<ForeignSessionSummary>> discover({
    required FileSystem fs,
    required String cwd,
    required String homeDir,
    required String tempDir,
    required ImportLimits limits,
  }) async {
    final root = await existingRoot(fs: fs, homeDir: homeDir);
    if (root == null) throw ForeignStoreAbsent(storeRoot(homeDir));
    final slug = claudeProjectSlug(cwd);
    final bucketPath = '$root/$slug';
    final bucket = await fs.listDir(bucketPath);
    if (bucket.isErr) return const [];
    final summaries = <ForeignSessionSummary>[];
    for (final (path, size, mtimeMs) in await listSessionFiles(
      fs,
      bucketPath,
    )) {
      final headerCwd = await _firstCwd(
        fs,
        path,
        maxFileBytes: limits.maxFileBytes,
      );
      // The slug is dash-ambiguous — discovery compares the recorded cwd
      // too and never decodes the slug (GOAL C1 negative test / E12).
      // An over-cap file yields no cwd on backends without partial reads
      // (the _firstCwd size gate); it still becomes a summary — cwd
      // unverified — so scanForeignLines' read-time refusal produces the
      // counted `file too large` warning, the same flow the ranged
      // prefix read already gives (GOAL E11 reporting parity).
      final overCap = headerCwd.isEmpty && size > limits.maxFileBytes;
      if (headerCwd.isEmpty && !overCap) continue;
      if (headerCwd.isNotEmpty && !headerCwdMatches(headerCwd, cwd)) continue;
      final stem = path.split('/').last;
      summaries.add(
        ForeignSessionSummary(
          harness: id,
          sourceId: stem.endsWith('.jsonl')
              ? stem.substring(0, stem.length - '.jsonl'.length)
              : stem,
          sourcePath: path,
          sizeBytes: size,
          headerCwd: headerCwd,
          title: '',
          titleSource: '',
          firstPreview: '-',
          lastPreview: '-',
          searchText: '',
          mtimeMs: mtimeMs,
        ),
      );
    }
    return summaries;
  }

  @override
  Future<ForeignParseResult> read({
    required FileSystem fs,
    required ForeignSessionSummary summary,
    required String homeDir,
    required ImportLimits limits,
  }) async {
    final counters = _ParseCounters();
    // Pass 1: classify lines — sidechain records are excluded+counted
    // (AC8), message records join the tree, everything else is aux.
    final (lines, shells) = await _classifyLines(
      fs,
      summary.sourcePath,
      limits,
      counters,
    );
    final branch = activeBranchIds(shells);
    counters.skippedRecords += branch.skippedOffPath;
    // Pass 2: emit aux + on-path records in file order.
    final records = _emitRecords(lines, branch.pathIds, counters);
    return ForeignParseResult(
      records: records,
      skippedRecords: counters.skippedRecords,
      skippedBlocks: counters.skippedBlocks,
    );
  }

  /// Streams the session file once, keeping every decodable line with its
  /// 1-based number and building the tree-shell list the branch walk
  /// consumes. Undecodable/oversized lines and sidechain entries are
  /// counted skipped on [counters].
  Future<(List<({int number, Map<String, dynamic> json})>, List<TreeShell>)>
  _classifyLines(
    FileSystem fs,
    String path,
    ImportLimits limits,
    _ParseCounters counters,
  ) async {
    final lines = <({int number, Map<String, dynamic> json})>[];
    final shells = <TreeShell>[];
    await for (final line in scanForeignLines(fs, path, limits)) {
      final json = line.text == null ? null : decodeJsonLine(line.text!);
      if (json == null) {
        counters.skippedRecords++;
        continue;
      }
      lines.add((number: line.number, json: json));
      if (json['isSidechain'] == true) {
        counters.skippedRecords++;
        continue;
      }
      final uuid = json['uuid'];
      if (uuid is String && uuid.isNotEmpty) {
        shells.add(TreeShell(line.number, uuid, json['parentUuid'] as String?));
      } else {
        shells.add(TreeShell.aux(line.number));
      }
    }
    return (lines, shells);
  }

  /// Emits aux + on-path records in file order; off-branch forks and
  /// sidechain entries were already counted skipped upstream.
  List<ForeignRecord> _emitRecords(
    List<({int number, Map<String, dynamic> json})> lines,
    Set<String> pathIds,
    _ParseCounters counters,
  ) {
    final records = <ForeignRecord>[];
    for (final (number: number, :json) in lines) {
      if (json['isSidechain'] == true) continue;
      final uuid = json['uuid'];
      final isTree = uuid is String && uuid.isNotEmpty;
      if (isTree && !pathIds.contains(uuid)) continue;
      if (_isMessageRecord(json, isTree)) {
        _emitMessageRecords(records, number, json, counters);
        continue;
      }
      // Unmodeled types (`last-prompt`, `permission-mode`, hook
      // attachments, ...) ride as inert custom data (GOAL C2).
      records.add(
        ForeignUnhandled(
          lineNumber: number,
          type: json['type'] as String? ?? 'unknown',
          raw: json,
        ),
      );
    }
    return records;
  }

  /// Whether the record is an on-path user/assistant message with a
  /// structured payload — the shape that becomes [ForeignMessage] records.
  static bool _isMessageRecord(Map<String, dynamic> json, bool isTree) =>
      isTree &&
      (json['type'] == 'user' || json['type'] == 'assistant') &&
      json['message'] is Map<String, dynamic>;

  /// Emits one message record, lifting paired `tool_result` blocks into
  /// their own toolResult records first (omp pairing parity).
  void _emitMessageRecords(
    List<ForeignRecord> records,
    int number,
    Map<String, dynamic> json,
    _ParseCounters counters,
  ) {
    final message = json['message'] as Map<String, dynamic>;
    final rawContent = message['content'];
    final (toolResults, parentBlocks) = _partitionToolResults(rawContent);
    for (final block in toolResults) {
      records.add(
        ForeignMessage(
          lineNumber: number,
          role: 'toolResult',
          contents: parseForeignContent(block['content'], counters.countBlock),
          rawMessage: block,
          toolCallId: block['tool_use_id'] as String?,
        ),
      );
    }
    records.add(
      ForeignMessage(
        lineNumber: number,
        role: message['role'] as String? ?? json['type'] as String? ?? '',
        contents: parseForeignContent(
          rawContent is List ? parentBlocks : rawContent,
          counters.countBlock,
        ),
        rawMessage: message,
        model: message['model'] as String?,
        provider: message['provider'] as String?,
        stopReason: message['stopReason'] as String?,
      ),
    );
  }

  /// Claude pairs tool results as `tool_result` blocks inside the
  /// following user message; each is lifted into its own toolResult
  /// record so pairing semantics match the omp shape. Lifted blocks are
  /// partitioned OUT of the parent parse — parseForeignContent counts
  /// every tool_result it sees as a skip, and a block that survives as
  /// its own record is not a dropped one.
  static (List<Map<String, dynamic>>, List<dynamic>) _partitionToolResults(
    Object? rawContent,
  ) {
    final toolResults = <Map<String, dynamic>>[];
    final parentBlocks = <dynamic>[];
    if (rawContent is List) {
      for (final block in rawContent) {
        if (block is Map<String, dynamic> && block['type'] == 'tool_result') {
          toolResults.add(block);
        } else {
          parentBlocks.add(block);
        }
      }
    }
    return (toolResults, parentBlocks);
  }

  /// The recorded cwd from the file's first lines — claude lines carry it
  /// per record; a bounded prefix read keeps discovery cheap.
  Future<String> _firstCwd(
    FileSystem fs,
    String path, {
    required int maxFileBytes,
  }) async {
    final prefix = await _readPrefix(fs, path, maxFileBytes: maxFileBytes);
    for (final line in const LineSplitter().convert(prefix).take(4)) {
      final cwd = decodeJsonLine(line)?['cwd'];
      if (cwd is String && cwd.isNotEmpty) return cwd;
    }
    return '';
  }

  /// The bounded 4 KiB prefix, '' when unreadable or oversized — no
  /// backend pulls an oversized file into memory during discovery
  /// (non-ranged backends consult the size gate BEFORE the whole-file
  /// read, the omp `_readPrefix` mirror).
  Future<String> _readPrefix(
    FileSystem fs,
    String path, {
    required int maxFileBytes,
  }) {
    if (fs is RangedReadFileSystem) {
      return _readRangedPrefix(fs as RangedReadFileSystem, path);
    }
    return _readWholeFilePrefix(fs, path, maxFileBytes: maxFileBytes);
  }

  /// The ranged partial-read shape: one 4 KiB window, decode errors
  /// tolerated, read failures become ''.
  Future<String> _readRangedPrefix(RangedReadFileSystem fs, String path) async {
    final read = await fs.readRange(path, 0, 4096);
    return read.isErr
        ? ''
        : utf8.decode(read.valueOrNull ?? const [], allowMalformed: true);
  }

  /// The whole-file shape with the size gate ahead of the read.
  Future<String> _readWholeFilePrefix(
    FileSystem fs,
    String path, {
    required int maxFileBytes,
  }) async {
    final info = await fs.fileInfo(path);
    final file = info.valueOrNull;
    if (info.isErr || file == null || file.kind != FileKind.file) {
      return '';
    }
    if (file.size > maxFileBytes) return '';
    final read = await fs.readTextFile(path);
    if (read.isErr) return '';
    final text = read.valueOrNull!;
    return text.length > 4096 ? text.substring(0, 4096) : text;
  }
}

/// The claude projects slug for [cwd]: the path with `/` replaced by `-`
/// (GOAL C1; sample-observed `-Users-...-...` shape). Not reversible —
/// discovery only compares it.
String claudeProjectSlug(String cwd) =>
    cwd.replaceAll(RegExp(r'[/\\]+$'), '').replaceAll('/', '-');

/// Mutable skip counters threaded through the [ClaudeAdapter.read] pass
/// helpers — one parse, two tallies: whole records dropped and content
/// blocks placeholder-ed inside mapped records.
class _ParseCounters {
  /// Whole records dropped while parsing (oversized/undecodable lines,
  /// off-branch records, sidechain entries).
  int skippedRecords = 0;

  /// Content blocks dropped inside mapped records (placeholder-ed).
  int skippedBlocks = 0;

  /// The [parseForeignContent] `onSkip` callback.
  void countBlock() {
    skippedBlocks++;
  }
}
