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
    final isDir = exists.valueOrNull == true &&
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
    for (final (path, size, mtimeMs) in await listSessionFiles(fs, bucketPath)) {
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
    var skipped = 0;
    var skippedBlocks = 0;
    // Pass 1: classify lines — sidechain records are excluded+counted
    // (AC8), message records join the tree, everything else is aux.
    final lines = <({int number, Map<String, dynamic> json})>[];
    final shells = <TreeShell>[];
    await for (final line in scanForeignLines(fs, summary.sourcePath, limits)) {
      if (line.text == null) {
        skipped++;
        continue;
      }
      final json = decodeJsonLine(line.text!);
      if (json == null) {
        skipped++;
        continue;
      }
      final number = line.number;
      lines.add((number: number, json: json));
      if (json['isSidechain'] == true) {
        skipped++;
        continue;
      }
      final uuid = json['uuid'];
      if (uuid is String && uuid.isNotEmpty) {
        shells.add(TreeShell(number, uuid, json['parentUuid'] as String?));
      } else {
        shells.add(TreeShell.aux(number));
      }
    }
    final branch = activeBranchIds(shells);
    skipped += branch.skippedOffPath;
    // Pass 2: emit aux + on-path records in file order.
    final records = <ForeignRecord>[];
    for (final (number: number, :json) in lines) {
      if (json['isSidechain'] == true) continue;
      final uuid = json['uuid'];
      final isTree = uuid is String && uuid.isNotEmpty;
      if (isTree && !branch.pathIds.contains(uuid)) {
        // Off-branch fork — counted skipped by the branch walk above.
        continue;
      }
      final message = json['message'];
      if (isTree &&
          (json['type'] == 'user' || json['type'] == 'assistant') &&
          message is Map<String, dynamic>) {
        final rawContent = message['content'];
        final toolResults = <Map<String, dynamic>>[];
        final parentBlocks = <dynamic>[];
        if (rawContent is List) {
          // Claude pairs tool results as `tool_result` blocks inside the
          // following user message; lift each into its own toolResult
          // record so pairing semantics match the omp shape. Lifted
          // blocks are partitioned OUT of the parent parse —
          // parseForeignContent counts every tool_result it sees as a
          // skip, and a block that survives as its own record is not a
          // dropped one.
          for (final block in rawContent) {
            if (block is Map<String, dynamic> &&
                block['type'] == 'tool_result') {
              toolResults.add(block);
            } else {
              parentBlocks.add(block);
            }
          }
        }
        for (final block in toolResults) {
          records.add(
            ForeignMessage(
              lineNumber: number,
              role: 'toolResult',
              contents: parseForeignContent(
                block['content'],
                () => skippedBlocks++,
              ),
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
              () => skippedBlocks++,
            ),
            rawMessage: message,
            model: message['model'] as String?,
            provider: message['provider'] as String?,
            stopReason: message['stopReason'] as String?,
          ),
        );
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
    return ForeignParseResult(
      records: records,
      skippedRecords: skipped,
      skippedBlocks: skippedBlocks,
    );
  }

  /// The recorded cwd from the file's first lines — claude lines carry it
  /// per record; a bounded prefix read keeps discovery cheap.
  Future<String> _firstCwd(
    FileSystem fs,
    String path, {
    required int maxFileBytes,
  }) async {
    String? prefix;
    if (fs is RangedReadFileSystem) {
      final ranged = fs as RangedReadFileSystem;
      final read = await ranged.readRange(path, 0, 4096);
      prefix = read.isErr
          ? null
          : utf8.decode(read.valueOrNull ?? const [], allowMalformed: true);
    } else {
      // Non-ranged backends have no partial read: consult the size gate
      // BEFORE the whole-file read (mirror of omp _readPrefix) — no
      // backend pulls an oversized file into memory during discovery.
      final info = await fs.fileInfo(path);
      final file = info.valueOrNull;
      if (info.isErr || file == null || file.kind != FileKind.file) {
        return '';
      }
      if (file.size > maxFileBytes) return '';
      final read = await fs.readTextFile(path);
      if (read.isErr) return '';
      final text = read.valueOrNull!;
      prefix = text.length > 4096 ? text.substring(0, 4096) : text;
    }
    if (prefix == null) return '';
    for (final line in const LineSplitter().convert(prefix).take(4)) {
      final cwd = decodeJsonLine(line)?['cwd'];
      if (cwd is String && cwd.isNotEmpty) return cwd;
    }
    return '';
  }
}

/// The claude projects slug for [cwd]: the path with `/` replaced by `-`
/// (GOAL C1; sample-observed `-Users-...-...` shape). Not reversible —
/// discovery only compares it.
String claudeProjectSlug(String cwd) =>
    cwd.replaceAll(RegExp(r'[/\\]+$'), '').replaceAll('/', '-');
