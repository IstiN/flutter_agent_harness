/// The omp harness adapter (issue #1562, GOAL O1-O7): discovery over
/// `~/.omp/agent/sessions/<encoded-cwd>/` buckets and a two-pass leaf-path
/// read of one session file.
///
/// Format pins (omp `session.md`): optional 256-byte `type:"title"` slot,
/// then the v3 session header (legacy files carry the title inline), then
/// `SessionEntry` records forming a `parentId` tree with a runtime leaf
/// pointer — the last entry is the leaf. camelCase message roles; tool
/// results are top-level messages paired by `toolCallId`; images
/// externalize to `~/.omp/agent/blobs/<sha256>` as `blob:sha256:<hash>`.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import 'foreign_session.dart';
import 'harness_adapter.dart';

/// Reads sessions from the omp store, read-only.
final class OmpAdapter implements HarnessAdapter {
  @override
  String get id => 'omp';

  @override
  String storeRoot(String homeDir) => '$homeDir/.omp/agent/sessions';

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
    final candidates = ompBucketSlugs(cwd, homeDir, tempDir);
    final summaries = <ForeignSessionSummary>[];
    final listed = await fs.listDir(root);
    if (listed.isErr) return const [];
    for (final entry in listed.valueOrNull ?? const <FileInfo>[]) {
      if (entry.kind != FileKind.directory || !candidates.contains(entry.name)) {
        continue;
      }
      for (final (path, size, mtimeMs)
          in await listSessionFiles(fs, entry.path)) {
        final header = await _readHeader(
          fs,
          path,
          maxFileBytes: limits.maxFileBytes,
        );
        // A file over the size cap yields no header on backends without
        // partial reads (the _readPrefix size gate); it still becomes a
        // summary — id fallback: the file stem, cwd unverified — so
        // scanForeignLines' read-time refusal produces the counted
        // `file too large` warning, the same flow the ranged prefix read
        // already gives (GOAL E11 reporting parity).
        final overCap = header == null && size > limits.maxFileBytes;
        if (header == null && !overCap) continue;
        if (header != null && !headerCwdMatches(header.cwd, cwd)) continue;
        final stem = path.split('/').last;
        summaries.add(
          ForeignSessionSummary(
            harness: id,
            sourceId: header?.id ??
                (stem.endsWith('.jsonl')
                    ? stem.substring(0, stem.length - '.jsonl'.length)
                    : stem),
            sourcePath: path,
            sizeBytes: size,
            headerCwd: header?.cwd ?? '',
            title: header?.title ?? '',
            titleSource: header?.titleSource ?? '',
            firstPreview: '-',
            lastPreview: '-',
            searchText: '',
            mtimeMs: mtimeMs,
          ),
        );
      }
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
    // Pass 1: the tree skeleton + the physical slot/header lines.
    final shells = <TreeShell>[];
    var slotTitle = ('', '');
    var headerLine = 0;
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
      switch (json['type']) {
        case 'title':
          slotTitle = (
            json['title'] as String? ?? '',
            json['source'] as String? ?? 'auto',
          );
          shells.add(TreeShell.aux(line.number));
        case 'session':
          headerLine = line.number;
          shells.add(TreeShell.aux(line.number));
        default:
          final entryId = json['id'];
          if (entryId is String && entryId.isNotEmpty) {
            shells.add(
              TreeShell(line.number, entryId, json['parentId'] as String?),
            );
          } else {
            // Pre-v2 entries carry no ids: omp's own migration chains them
            // linearly in file order. Without ids they cannot join a tree;
            // count them skipped rather than guess.
            skipped++;
          }
      }
    }
    // Pass 2: re-read only the active branch, in file order. Blob images
    // are pre-loaded (bounded) so content parsing stays pure.
    final branch = activeBranchIds(shells);
    skipped += branch.skippedOffPath;
    final records = <ForeignRecord>[];
    if (slotTitle.$1.isNotEmpty) {
      records.add(
        ForeignTitleSlot(
          lineNumber: 1,
          title: slotTitle.$1,
          source: slotTitle.$2,
        ),
      );
    }
    final blobs = <String, ForeignImage>{};
    var sawHeader = false;
    await for (final line in scanForeignLines(fs, summary.sourcePath, limits)) {
      if (line.text == null) continue;
      final json = decodeJsonLine(line.text!);
      if (json == null) continue;
      final isPhysical = line.number == headerLine ||
          (line.number == 1 && json['type'] == 'title');
      final id = json['id'];
      if (!isPhysical && !(id is String && branch.pathIds.contains(id))) {
        continue;
      }
      await _preloadBlobs(json, fs, homeDir, limits, blobs);
      final record = _parseRecord(
        json,
        line.number,
        blobs,
        () => skippedBlocks++,
      );
      if (record == null) {
        skipped++;
        continue;
      }
      if (record is ForeignHeader) sawHeader = true;
      records.add(record);
    }
    if (!sawHeader) {
      throw ForeignFileError('no session header in ${summary.sourcePath}');
    }
    return ForeignParseResult(
      records: records,
      skippedRecords: skipped,
      skippedBlocks: skippedBlocks,
    );
  }

  Future<({String id, String cwd, String title, String titleSource})?>
  _readHeader(
    FileSystem fs,
    String path, {
    required int maxFileBytes,
  }) async {
    // The header sits in the first bytes (optional 256-byte title slot,
    // then the header line): a bounded prefix read keeps discovery cheap
    // on marathon files and lets oversized files still be DISCOVERED —
    // the size-cap refusal happens at read time, as a counted warning.
    final prefix = await _readPrefix(
      fs,
      path,
      4096,
      maxFileBytes: maxFileBytes,
    );
    if (prefix == null) return null;
    var slotTitle = ('', '');
    for (final line in const LineSplitter().convert(prefix).take(4)) {
      final json = decodeJsonLine(line);
      if (json == null) continue;
      switch (json['type']) {
        case 'title':
          slotTitle = (
            json['title'] as String? ?? '',
            json['source'] as String? ?? 'auto',
          );
        case 'session':
          final id = json['id'];
          if (id is! String || id.isEmpty) return null;
          final inlineTitle = json['title'] as String? ?? '';
          final inlineSource = json['titleSource'] as String? ?? 'auto';
          final title = slotTitle.$1.isNotEmpty
              ? slotTitle
              : (inlineTitle, inlineSource);
          return (
            id: id,
            cwd: json['cwd'] as String? ?? '',
            title: title.$1,
            titleSource: title.$2,
          );
      }
    }
    return null;
  }

  /// The first [bytes] of [path] as text, or null when unreadable or
  /// over [maxFileBytes]. Range reads on ranged backends; elsewhere a
  /// whole-file read fallback that consults the size gate FIRST, so no
  /// backend ever pulls an oversized file into memory during discovery.
  Future<String?> _readPrefix(
    FileSystem fs,
    String path,
    int bytes, {
    required int maxFileBytes,
  }) async {
    if (fs is RangedReadFileSystem) {
      final ranged = fs as RangedReadFileSystem;
      final read = await ranged.readRange(path, 0, bytes);
      if (read.isErr) return null;
      return utf8.decode(read.valueOrNull ?? const [], allowMalformed: true);
    }
    final info = await fs.fileInfo(path);
    final file = info.valueOrNull;
    if (info.isErr || file == null || file.kind != FileKind.file) return null;
    if (file.size > maxFileBytes) return null;
    final read = await fs.readTextFile(path);
    if (read.isErr) return null;
    final text = read.valueOrNull!;
    return text.length > bytes ? text.substring(0, bytes) : text;
  }

  ForeignRecord? _parseRecord(
    Map<String, dynamic> json,
    int lineNumber,
    Map<String, ForeignImage> blobs,
    void Function() onBlockSkip,
  ) {
    switch (json['type']) {
      case 'title':
        return ForeignTitleSlot(
          lineNumber: lineNumber,
          title: json['title'] as String? ?? '',
          source: json['source'] as String? ?? 'auto',
        );
      case 'session':
        return ForeignHeader(
          lineNumber: lineNumber,
          id: json['id'] as String? ?? '',
          cwd: json['cwd'] as String? ?? '',
          version: (json['version'] as num?)?.toInt() ?? 0,
          title: json['title'] as String?,
          titleSource: json['titleSource'] as String?,
        );
      case 'message':
        final message = json['message'];
        if (message is! Map<String, dynamic>) return null;
        return _parseOmpMessage(message, lineNumber, blobs, onBlockSkip);
      case 'model_change':
        return ForeignModelChange(
          lineNumber: lineNumber,
          model: json['model'] as String? ?? '',
        );
      case 'thinking_level_change':
        return ForeignThinkingLevelChange(
          lineNumber: lineNumber,
          level:
              (json['thinkingLevel'] ?? json['configured']) as String? ?? 'off',
        );
      case 'compaction':
        return ForeignCompaction(
          lineNumber: lineNumber,
          summary: json['summary'] as String? ?? '',
          droppedFields: [
            for (final field in const [
              'firstKeptEntryId',
              'tokensBefore',
              'shortSummary',
              'preserveData',
              'fromExtension',
              'details',
            ])
              if (json[field] != null) field,
          ],
        );
      case 'custom':
        return ForeignCustom(
          lineNumber: lineNumber,
          customType: json['customType'] as String? ?? '',
          data: json['data'],
        );
      case 'custom_message':
        final content = json['content'];
        return ForeignCustomMessage(
          lineNumber: lineNumber,
          customType: json['customType'] as String? ?? '',
          content: content is String
              ? content
              : parseForeignContent(content, onBlockSkip),
          display: json['display'] as bool? ?? false,
          details: json['details'],
          attribution: json['attribution'] as String?,
        );
      case 'title_change':
        return ForeignTitleSlot(
          lineNumber: lineNumber,
          title: json['title'] as String? ?? '',
          source: json['source'] as String? ?? 'user',
        );
      default:
        // Observed-but-unmapped and unknown future types (GOAL AC6):
        // tolerated, mapped to inert custom entries by the mapper.
        return ForeignUnhandled(
          lineNumber: lineNumber,
          type: json['type'] as String? ?? '',
          raw: json,
        );
    }
  }

  ForeignMessage _parseOmpMessage(
    Map<String, dynamic> message,
    int lineNumber,
    Map<String, ForeignImage> blobs,
    void Function() onBlockSkip,
  ) {
    final contents = parseForeignContent(
      message['content'],
      onBlockSkip,
      resolveBlob: (blobRef) => blobs[blobRef],
    );
    return ForeignMessage(
      lineNumber: lineNumber,
      role: message['role'] as String? ?? '',
      contents: contents,
      rawMessage: message,
      toolCallId: message['toolCallId'] as String?,
      toolName: message['toolName'] as String?,
      isError: message['isError'] as bool? ?? false,
      model: message['model'] as String?,
      provider: message['provider'] as String?,
      api: message['api'] as String?,
      usage: message['usage'] is Map<String, dynamic>
          ? message['usage'] as Map<String, dynamic>
          : null,
      stopReason: message['stopReason'] as String?,
      errorMessage: message['errorMessage'] as String?,
    );
  }

  /// Loads every `blob:sha256:<hash>` image this record references into
  /// [blobs] (bounded embed-or-skip, GOAL O5 + security section): the blob
  /// must exist under `~/.omp/agent/blobs/<hash>` and fit
  /// [ImportLimits.maxImageBytes]; its payload is base64 image data.
  Future<void> _preloadBlobs(
    Map<String, dynamic> json,
    FileSystem fs,
    String homeDir,
    ImportLimits limits,
    Map<String, ForeignImage> blobs,
  ) async {
    final message = json['message'];
    final content = message is Map<String, dynamic>
        ? message['content']
        : json['content'];
    if (content is! List) return;
    for (final item in content) {
      if (item is! Map<String, dynamic>) continue;
      if (item['type'] != 'image') continue;
      final data = item['data'];
      if (data is! String || !data.startsWith('blob:')) continue;
      if (blobs.containsKey(data)) continue;
      blobs[data] = await _loadBlob(data, fs, homeDir, limits);
    }
  }

  Future<ForeignImage> _loadBlob(
    String blobRef,
    FileSystem fs,
    String homeDir,
    ImportLimits limits,
  ) async {
    final hash = blobRef.startsWith('blob:sha256:')
        ? blobRef.substring('blob:sha256:'.length)
        : null;
    // The blob dir is content-addressed: only a real sha256 hex digest
    // may reach a path — a crafted `blob:sha256:../…` ref must never
    // escape the blob dir (path traversal).
    if (hash == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      return ForeignImage.skipped('malformed blob ref: $blobRef');
    }
    final blobPath = '$homeDir/.omp/agent/blobs/$hash';
    final info = await fs.fileInfo(blobPath);
    final file = info.valueOrNull;
    if (info.isErr || file == null || file.kind != FileKind.file) {
      return ForeignImage.skipped('blob not found: $blobRef');
    }
    if (file.size > limits.maxImageBytes) {
      return ForeignImage.skipped(
        'blob too large: $blobRef (${file.size} bytes)',
      );
    }
    final read = await fs.readBinaryFile(blobPath);
    if (read.isErr) return ForeignImage.skipped('unreadable blob: $blobRef');
    final text = utf8.decode(read.valueOrNull ?? [], allowMalformed: true);
    final base64 = _base64Payload(text);
    if (base64 == null) {
      return ForeignImage.skipped('undecodable blob: $blobRef');
    }
    return ForeignImage(base64Data: base64, mimeType: 'image/png');
  }
}

/// The omp bucket slug candidates for [cwd] (GOAL O1): omp encodes the
/// canonicalized cwd as `-<relative>` under home, `-tmp-<relative>` under
/// the temp root, and `--<encoded-absolute>--` otherwise, with path
/// separators replaced by `-`. Discovery compares slugs and header cwds —
/// it never decodes a slug (dash-ambiguous, GOAL E12).
Set<String> ompBucketSlugs(String cwd, String homeDir, String tempDir) {
  String enc(String path) => path.replaceAll(RegExp(r'[/\\:]'), '-');
  final normalized = cwd.replaceAll(RegExp(r'[/\\]+$'), '');
  final absolute = '--${enc(normalized.replaceFirst(RegExp(r'^[/\\]'), ''))}--';
  final candidates = <String>{absolute};
  final home = homeDir.replaceAll(RegExp(r'[/\\]+$'), '');
  if (home.isNotEmpty && normalized.startsWith('$home/')) {
    candidates.add('-${enc(normalized.substring(home.length + 1))}');
  }
  final temp = tempDir.replaceAll(RegExp(r'[/\\]+$'), '');
  if (temp.isNotEmpty && normalized.startsWith('$temp/')) {
    candidates.add('-tmp-${enc(normalized.substring(temp.length + 1))}');
  }
  return candidates;
}

/// Strips a `data:<mime>;base64,` header, validating the payload.
String? _base64Payload(String text) {
  final payload = text.startsWith('data:')
      ? RegExp(r'^data:[^;,]*;base64,(.+)$', dotAll: true)
          .firstMatch(text)
          ?.group(1)
      : text;
  if (payload == null ||
      payload.isEmpty ||
      !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(payload)) {
    return null;
  }
  return payload;
}
