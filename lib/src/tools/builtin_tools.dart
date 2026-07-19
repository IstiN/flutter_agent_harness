/// Built-in agent tools for the CLI harness: file read, file write,
/// directory listing, and shell execution — all on top of the abstract
/// [ExecutionEnv] (never `dart:io` directly), so the same tools run against
/// [MemoryExecutionEnv] in tests or a browser-storage-backed env on web.
///
/// Shaped after pi-mono's built-in tools (`packages/coding-agent/src/core/
/// tools/{read,write,ls,bash}.ts`): same tool names (`read`, `write`, `ls`,
/// `bash`), same JSON-schema parameters, same output-truncation limits
/// ([defaultToolMaxLines] lines / [defaultToolMaxBytes] bytes, whichever is
/// hit first), and the same continuation notices so the model knows how to
/// page through truncated output.
///
/// The `edit` tool additionally ports oh-my-pi's hashline patch language
/// (`packages/hashline`): the model may pass a `patch` with `[path#TAG]`
/// section headers and `SWAP`/`DEL`/`INS` ops anchored on line numbers from
/// a hashline-mode `read`; a stale tag is rejected before any write. The
/// `read` tool's `hashline` parameter emits the numbered, tag-carrying
/// output those anchors cite, and both tools share one session
/// [HashlineSnapshotStore] (see [builtinTools]).
///
/// Deliberate divergences from the TypeScript originals:
///
/// - [readFileTool] image support runs in-process on `package:image` instead
///   of pi's Photon/WASM worker; the pipeline matches pi's
///   `utils/image-process.ts` (EXIF orientation baking, pass-through within
///   limits, PNG-then-JPEG byte-budget ladder at 4.5MB base64).
/// - The `bash` tool does not spill truncated output to a temp file (pi's
///   `fullOutputPath`); the truncation notice omits the path. Streaming
///   `onUpdate` partials and pi's `commandPrefix`/spawn hooks are also
///   deferred.
/// - [writeFileTool] reports UTF-8 bytes (pi reports `String.length`, which
///   is UTF-16 code units mislabeled as bytes).
/// - The hashline port covers the line-range ops only (`SWAP`/`DEL`/`INS.*`);
///   omp's tree-sitter block ops (`SWAP.BLK`/`DEL.BLK`/`INS.BLK.POST`), file
///   ops (`REM`/`MV`), boundary-repair leniency, and diff-based stale-anchor
///   auto-remap are skipped (see `lib/src/hashline/`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../approval/bash_interceptor.dart';
import '../cancel_token.dart';
import '../env/execution_env.dart';
import '../hashline/hashline.dart';
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../types.dart';
import '../web_search/web_search.dart';
import 'archive_reader.dart';
import 'read_selector.dart';
import 'sqlite/sqlite_reader.dart';
import 'tool_format.dart';

export 'tool_format.dart' show formatToolSize;

/// Default line limit for tool output truncation (pi's `DEFAULT_MAX_LINES`).
const defaultToolMaxLines = 2000;

/// Default byte limit for tool output truncation (pi's `DEFAULT_MAX_BYTES`).
const defaultToolMaxBytes = 50 * 1024;

/// Default entry cap for the `ls` tool (pi's `DEFAULT_LIMIT`).
const defaultLsEntryLimit = 500;

/// Maximum shell timeout: pi clamps at the int32 max milliseconds.
const _maxTimeoutMs = 2147483647;

/// Creates the four built-in tools ([readFileTool], [writeFileTool],
/// [listDirTool], [shellTool]) bound to [env].
///
/// [snapshots] is the session-scoped hashline snapshot store shared by the
/// `read` and `edit` tools: hashline-mode reads mint the content tags that
/// hashline edit patches cite, and edits mint fresh tags for follow-ups.
/// Defaults to a fresh store — one per [builtinTools] call, i.e. one per
/// agent session.
///
/// When [webSearch] is provided, the `web_search` and `web_fetch` tools are
/// registered with it (provider chain resolved from the config; keyless
/// DuckDuckGo works with all defaults).
///
/// When [sqlite] is provided, the `read` tool resolves SQLite database
/// targets (`data.db:table`); without an engine (e.g. web hosts, where FFI
/// is unavailable) such reads return a clean "not supported" note.
///
/// [model] is forwarded to [readFileTool] for the non-vision image note.
List<AgentTool> builtinTools(
  ExecutionEnv env, {
  HashlineSnapshotStore? snapshots,
  WebSearchConfig? webSearch,
  Model? Function()? model,
  SqliteEngine? sqlite,
}) {
  final store = snapshots ?? HashlineSnapshotStore();
  return [
    readFileTool(env, snapshots: store, model: model, sqlite: sqlite),
    writeFileTool(env),
    editFileTool(env, snapshots: store),
    listDirTool(env),
    shellTool(env),
    if (webSearch != null) ...[
      webSearchTool(config: webSearch),
      webFetchTool(config: webSearch),
    ],
  ];
}

// ---------------------------------------------------------------------------
// Truncation (ported from pi's tools/truncate.ts)
// ---------------------------------------------------------------------------

/// Which limit truncated the output.
enum _TruncatedBy { lines, bytes }

final class _Truncation {
  const _Truncation({
    required this.content,
    required this.truncated,
    required this.totalLines,
    required this.outputLines,
    this.truncatedBy,
    this.firstLineExceedsLimit = false,
  });
  final String content;
  final bool truncated;
  final int totalLines;
  final int outputLines;
  final _TruncatedBy? truncatedBy;
  final bool firstLineExceedsLimit;
}

List<String> _splitLinesForCounting(String content) {
  if (content.isEmpty) return const [];
  final lines = content.split('\n');
  if (content.endsWith('\n')) lines.removeLast();
  return lines;
}

int _byteLength(String text) => utf8.encode(text).length;

/// Formats a byte count as a human-readable size (pi's `formatSize`) — moved
/// to `tool_format.dart` and re-exported here for compatibility.

/// Keeps the first [maxLines] lines / [maxBytes] bytes of [content],
/// never returning partial lines (pi's `truncateHead`).
_Truncation _truncateHead(
  String content, {
  int maxLines = defaultToolMaxLines,
  int maxBytes = defaultToolMaxBytes,
}) {
  final lines = _splitLinesForCounting(content);
  final totalBytes = _byteLength(content);
  if (lines.length <= maxLines && totalBytes <= maxBytes) {
    return _Truncation(
      content: content,
      truncated: false,
      totalLines: lines.length,
      outputLines: lines.length,
    );
  }
  if (lines.isNotEmpty && _byteLength(lines.first) > maxBytes) {
    return _Truncation(
      content: '',
      truncated: true,
      totalLines: lines.length,
      outputLines: 0,
      truncatedBy: _TruncatedBy.bytes,
      firstLineExceedsLimit: true,
    );
  }
  final kept = <String>[];
  var keptBytes = 0;
  var truncatedBy = _TruncatedBy.lines;
  for (var i = 0; i < lines.length && i < maxLines; i++) {
    final lineBytes = _byteLength(lines[i]) + (i > 0 ? 1 : 0);
    if (keptBytes + lineBytes > maxBytes) {
      truncatedBy = _TruncatedBy.bytes;
      break;
    }
    kept.add(lines[i]);
    keptBytes += lineBytes;
  }
  return _Truncation(
    content: kept.join('\n'),
    truncated: true,
    totalLines: lines.length,
    outputLines: kept.length,
    truncatedBy: kept.length >= maxLines ? _TruncatedBy.lines : truncatedBy,
  );
}

/// Keeps the last [maxLines] lines / [maxBytes] bytes of [content],
/// never returning partial lines (subset of pi's `truncateTail`).
_Truncation _truncateTail(
  String content, {
  int maxLines = defaultToolMaxLines,
  int maxBytes = defaultToolMaxBytes,
}) {
  final lines = _splitLinesForCounting(content);
  final totalBytes = _byteLength(content);
  if (lines.length <= maxLines && totalBytes <= maxBytes) {
    return _Truncation(
      content: content,
      truncated: false,
      totalLines: lines.length,
      outputLines: lines.length,
    );
  }
  final kept = <String>[];
  var keptBytes = 0;
  var truncatedBy = _TruncatedBy.lines;
  for (var i = lines.length - 1; i >= 0 && kept.length < maxLines; i--) {
    final lineBytes = _byteLength(lines[i]) + (kept.isNotEmpty ? 1 : 0);
    if (keptBytes + lineBytes > maxBytes) {
      truncatedBy = _TruncatedBy.bytes;
      break;
    }
    kept.insert(0, lines[i]);
    keptBytes += lineBytes;
  }
  return _Truncation(
    content: kept.join('\n'),
    truncated: true,
    totalLines: lines.length,
    outputLines: kept.length,
    truncatedBy: kept.length >= maxLines ? _TruncatedBy.lines : truncatedBy,
  );
}

// ---------------------------------------------------------------------------
// Image handling for the read tool
// ---------------------------------------------------------------------------

/// Maximum width/height for inline images (pi's `maxWidth`/`maxHeight`).
const _defaultImageMaxDimension = 2000;

/// Base64 payload budget for inline images: 4.5MB of base64 (== `4.5 * 1024 *
/// 1024`), providing headroom below Anthropic's 5MB inline limit (pi's
/// `DEFAULT_MAX_BYTES`).
const _defaultImageMaxBase64Bytes = 4718592;

/// JPEG quality ladder tried after PNG at each size step (pi's `qualitySteps`
/// with the default `jpegQuality` 80).
const _imageJpegQualitySteps = [80, 85, 70, 55, 40];

const _supportedImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
  ImageFormat.bmp,
};

/// Formats providers accept inline; other decodable formats (BMP) are
/// converted first (pi's `normalizeSupportedImageMimeType`).
const _inlineImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
};

String? _mimeTypeForImageFormat(ImageFormat format) {
  return switch (format) {
    ImageFormat.png => 'image/png',
    ImageFormat.jpg => 'image/jpeg',
    ImageFormat.gif => 'image/gif',
    ImageFormat.webp => 'image/webp',
    ImageFormat.bmp => 'image/bmp',
    _ => null,
  };
}

/// Encoded size of [bytes] as base64 text (pi compares the UTF-8 byte length
/// of the base64 string, which equals its character length).
int _base64Length(Uint8List bytes) => ((bytes.length + 2) ~/ 3) * 4;

({
  String mimeType,
  String base64,
  int width,
  int height,
  bool resized,
  int outputWidth,
  int outputHeight,
  String? convertedFrom,
})
_processImage(
  Uint8List bytes,
  ImageFormat format, {
  int maxDimension = _defaultImageMaxDimension,
  int maxBase64Bytes = _defaultImageMaxBase64Bytes,
}) {
  // Normalize (pi's `normalizeImage`): formats providers do not accept inline
  // (BMP) decode and convert to PNG first; EXIF orientation is baked in.
  var inputBytes = bytes;
  var inputFormat = format;
  String? convertedFrom;
  if (!_inlineImageFormats.contains(format)) {
    final source = decodeImage(bytes);
    if (source == null) {
      throw StateError('Could not decode image');
    }
    inputBytes = encodePng(bakeOrientation(source));
    inputFormat = ImageFormat.png;
    convertedFrom = _mimeTypeForImageFormat(format);
  }
  return _resizeInlineImage(
    inputBytes,
    inputFormat,
    convertedFrom: convertedFrom,
    maxDimension: maxDimension,
    maxBase64Bytes: maxBase64Bytes,
  );
}

/// Fits an inline-format image within the dimension and base64 byte limits.
///
/// Ported from pi's `resizeImageInProcess` (`utils/image-resize-core.ts`):
/// EXIF orientation is baked before measuring; images already within ALL
/// limits pass through with their ORIGINAL bytes untouched; otherwise each
/// size step tries PNG, then JPEG at decreasing quality
/// ([_imageJpegQualitySteps]), shrinking dimensions by 0.75 until a candidate
/// fits the byte budget.
({
  String mimeType,
  String base64,
  int width,
  int height,
  bool resized,
  int outputWidth,
  int outputHeight,
  String? convertedFrom,
})
_resizeInlineImage(
  Uint8List bytes,
  ImageFormat format, {
  required String? convertedFrom,
  required int maxDimension,
  required int maxBase64Bytes,
}) {
  final decoded = decodeImage(bytes);
  if (decoded == null) {
    throw StateError('Could not decode image');
  }
  // Bake EXIF orientation before measuring/resizing so the model sees the
  // image as displayed (pi's `applyExifOrientation`).
  final image =
      decoded.exif.imageIfd.hasOrientation &&
          decoded.exif.imageIfd.orientation != 1
      ? bakeOrientation(decoded)
      : decoded;
  final width = image.width;
  final height = image.height;

  // Pass-through: within the dimension AND byte limits, keep the original
  // bytes untouched (no re-encode).
  if (width <= maxDimension &&
      height <= maxDimension &&
      _base64Length(bytes) < maxBase64Bytes) {
    return (
      mimeType: _mimeTypeForImageFormat(format) ?? 'image/png',
      base64: base64Encode(bytes),
      width: width,
      height: height,
      resized: false,
      outputWidth: width,
      outputHeight: height,
      convertedFrom: convertedFrom,
    );
  }

  var targetWidth = width;
  var targetHeight = height;
  if (width > maxDimension || height > maxDimension) {
    if (width >= height) {
      targetWidth = maxDimension;
      targetHeight = (height * maxDimension / width).round();
    } else {
      targetHeight = maxDimension;
      targetWidth = (width * maxDimension / height).round();
    }
  }

  var currentWidth = targetWidth;
  var currentHeight = targetHeight;
  while (true) {
    final candidate = currentWidth == width && currentHeight == height
        ? image
        : copyResize(
            image,
            width: currentWidth,
            height: currentHeight,
            interpolation: Interpolation.cubic,
          );
    final png = encodePng(candidate);
    if (_base64Length(png) < maxBase64Bytes) {
      return (
        mimeType: 'image/png',
        base64: base64Encode(png),
        width: width,
        height: height,
        resized: true,
        outputWidth: currentWidth,
        outputHeight: currentHeight,
        convertedFrom: convertedFrom,
      );
    }
    var accepted = false;
    String? jpegBase64;
    for (final quality in _imageJpegQualitySteps) {
      final jpeg = encodeJpg(candidate, quality: quality);
      if (_base64Length(jpeg) < maxBase64Bytes) {
        jpegBase64 = base64Encode(jpeg);
        accepted = true;
        break;
      }
    }
    if (accepted) {
      return (
        mimeType: 'image/jpeg',
        base64: jpegBase64!,
        width: width,
        height: height,
        resized: true,
        outputWidth: currentWidth,
        outputHeight: currentHeight,
        convertedFrom: convertedFrom,
      );
    }

    if (currentWidth == 1 && currentHeight == 1) {
      break;
    }
    final nextWidth = currentWidth == 1 ? 1 : currentWidth * 3 ~/ 4;
    final nextHeight = currentHeight == 1 ? 1 : currentHeight * 3 ~/ 4;
    if (nextWidth == currentWidth && nextHeight == currentHeight) {
      break;
    }
    currentWidth = nextWidth;
    currentHeight = nextHeight;
  }

  throw StateError('Could not resize image below the inline image size limit');
}

ImageFormat? _detectImageFormat(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  try {
    return findFormatForData(bytes);
  } on Object {
    return null;
  }
}

// ---------------------------------------------------------------------------
// read (ported from pi's tools/read.ts, with image support; extended with
// oh-my-pi's trailing-selector grammar, archive inner paths, and SQLite
// targets — one path grammar keeps the tool count flat)
// ---------------------------------------------------------------------------

/// Default entry cap for archive directory listings (omp's
/// `#readArchiveDirectory` DEFAULT_LIMIT).
const defaultArchiveListLimit = 500;

/// Creates the `read` tool: reads a text file or image with optional `offset`
/// (1-indexed) and `limit`, truncating text output to [defaultToolMaxLines]
/// lines or [defaultToolMaxBytes] bytes with an actionable continuation notice.
/// Images are decoded, optionally resized to the inline dimension/byte limits,
/// and returned as base64 content.
///
/// The path may carry a trailing selector (oh-my-pi's grammar, ported in
/// `read_selector.dart`): `:N` / `:A-B` / `:A+C` line ranges, comma-merged
/// multi-ranges (`:5-16,960-973`), and `:raw` verbatim output — alone or
/// combined with a range in either order (`:raw:50-100`). A single range maps
/// onto the offset/limit pipeline; multi-ranges render one block per range
/// joined by an elision separator, with out-of-bounds ranges reported as
/// skipped notices. `:raw` suppresses line numbers, the hashline header, and
/// all continuation notices. The `offset`/`limit` arguments keep working and
/// must not be combined with a selector.
///
/// Two extended targets consume their own colon syntax behind the same tool:
///
/// - Archive inner paths (`archive.zip:inner/entry`, also `.tar` and
///   `.tar.gz`/`.tgz`, via `archive_reader.dart`): the member's text runs
///   through the same pipeline (selectors apply after extraction); a bare
///   archive path or inner directory lists its contents, and binary entries
///   yield a note instead of bytes.
/// - SQLite databases (`data.db`, `data.db:table`, `data.db:table:key`,
///   `data.db:table?limit=…&offset=…&order=…&where=…`, `data.db?q=SELECT …`,
///   via `sqlite/sqlite_reader.dart`): rendered as width-capped ASCII
///   tables. Only available when the host provides a [SqliteEngine] (FFI,
///   exported from `lib/io.dart`); without one the read returns a clean
///   "not supported" note — what web hosts get.
///
/// With `hashline: true` (omp's hashline display mode), text output lines are
/// prefixed with their 1-indexed line number (`N:text`) and the output is
/// preceded by a `[path#TAG]` header carrying the whole-file content-hash
/// tag; the full file text plus the displayed line range are recorded in
/// [snapshots] so `edit` patches can anchor against them. Ranged reads keep
/// real file line numbers. Default is `false` (omp defaults it on; we keep
/// the legacy plain output as the default so existing read consumers are
/// unaffected — the `edit` tool description tells the model to opt in when
/// it intends to edit by anchors).
///
/// When [model] is provided, image results carry an extra note when the
/// current model has no `image` input (pi's `getNonVisionImageNote`); the
/// image itself stays in the result — providers substitute an explicit
/// placeholder at request time (see `downgradeUnsupportedImages`).
AgentTool readFileTool(
  ExecutionEnv env, {
  HashlineSnapshotStore? snapshots,
  Model? Function()? model,
  SqliteEngine? sqlite,
}) {
  final store = snapshots ?? HashlineSnapshotStore();
  return AgentTool(
    name: 'read',
    label: 'read',
    tier: ApprovalTier.read,
    description: readToolDescriptionPrompt
        .replaceAll('{{maxLines}}', '$defaultToolMaxLines')
        .replaceAll('{{maxBytesKb}}', '${defaultToolMaxBytes ~/ 1024}'),
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'Path to the file to read (relative or absolute). May end '
              'with a trailing selector such as :50-100 or :raw, address an '
              'archive member (archive.zip:inner/file), or address a SQLite '
              'database (data.db:table?limit=20)',
        },
        'offset': {
          'type': 'integer',
          'description': 'Line number to start reading from (1-indexed)',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum number of lines to read',
        },
        'hashline': {
          'type': 'boolean',
          'description':
              'Prefix each line with its line number and prepend a '
              '[path#TAG] content-hash header for anchoring hashline edit '
              'patches (default: false)',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final rawPath = arguments['path'] as String;
      final offset = (arguments['offset'] as num?)?.toInt();
      final limit = (arguments['limit'] as num?)?.toInt();
      final hashlineMode = (arguments['hashline'] as bool?) ?? false;

      // Peel a trailing selector off the path (omp's grammar). A literal file
      // whose name ends in a selector-shaped tail (`test:1-2`) wins over the
      // selector interpretation.
      final split = await splitPathAndSelPreferringLiteral(rawPath, env);
      final parsed = parseSel(split.sel);
      if (parsed is! ReadSelectorNone && (offset != null || limit != null)) {
        throw StateError(
          'offset/limit cannot be combined with a path selector; use one or '
          'the other.',
        );
      }

      // Archive and SQLite targets consume their own colon syntax, so probe
      // them on the RAW path — unless it was kept literal because a real
      // file with a selector-shaped name exists (omp's rawPathIsLiteral).
      final rawPathIsLiteral =
          split.sel == null && splitPathAndSel(rawPath).sel != null;
      if (!rawPathIsLiteral) {
        final archiveResult = await _tryReadArchive(env, rawPath, cancelToken);
        if (archiveResult != null) return archiveResult;
        final sqliteResult = await _tryReadSqlite(env, rawPath, sqlite);
        if (sqliteResult != null) {
          cancelToken?.throwIfCancelled();
          return sqliteResult;
        }
      }

      final path = split.path;
      final binaryRead = await env.readBinaryFile(path);
      if (binaryRead.isErr) throw StateError('${binaryRead.errorOrNull}');
      final bytes = binaryRead.valueOrNull!;
      cancelToken?.throwIfCancelled();

      final format = _detectImageFormat(bytes);
      if (format != null && _supportedImageFormats.contains(format)) {
        if (parsed is! ReadSelectorNone) {
          throw StateError(
            'Line selectors (:N, :A-B, :raw) apply to text files; '
            "'$path' is an image.",
          );
        }
        final processed = _processImage(bytes, format);
        final note = StringBuffer()
          ..write('[Image: $path, ${processed.width}x${processed.height}');
        if (processed.resized) {
          note.write(
            ', resized to ${processed.outputWidth}x${processed.outputHeight}',
          );
        }
        note.write(']');
        // pi's `conversionHint`.
        final convertedFrom = processed.convertedFrom;
        if (convertedFrom != null && convertedFrom != processed.mimeType) {
          note.write(
            '\n[Image converted from $convertedFrom to ${processed.mimeType}.]',
          );
        }
        // pi's `formatDimensionNote`: coordinate-mapping hint after resize.
        if (processed.resized) {
          final scale = processed.width / processed.outputWidth;
          note.write(
            '\n[Image: original ${processed.width}x${processed.height}, '
            'displayed at ${processed.outputWidth}x${processed.outputHeight}. '
            'Multiply coordinates by ${scale.toStringAsFixed(2)} to map to '
            'original image.]',
          );
        }
        // pi's `getNonVisionImageNote`.
        final currentModel = model?.call();
        if (currentModel != null && !currentModel.input.contains('image')) {
          note.write(
            '\n[Current model does not support images. The image will be '
            'omitted from this request.]',
          );
        }
        return ToolExecutionResult(
          content: [
            TextContent(text: note.toString()),
            ImageContent(data: processed.base64, mimeType: processed.mimeType),
          ],
        );
      }

      final read = await env.readTextFile(path);
      if (read.isErr) throw StateError('${read.errorOrNull}');
      cancelToken?.throwIfCancelled();

      final rawContent = read.valueOrNull!;
      final allLines = rawContent.split('\n');
      final totalFileLines = allLines.length;
      final raw = isRawSelector(parsed);

      // Multi-range selector: one block per in-bounds range joined by an
      // elision separator; ranges past EOF surface as skipped notices (omp's
      // #buildInMemoryMultiRangeResult).
      if (parsed is ReadSelectorLines && parsed.ranges.length > 1) {
        final multi = _formatMultiRange(
          allLines: allLines,
          ranges: parsed.ranges,
          raw: raw,
          hashlineMode: hashlineMode,
          entityLabel: 'file',
        );
        var multiOutput = multi.text;
        if (hashlineMode && !raw) {
          final normalized = normalizeToLF(stripBom(rawContent).text);
          final canonical = (await env.absolutePath(path)).valueOrNull ?? path;
          final tag = store.record(canonical, normalized, multi.seenLines);
          multiOutput = '${formatHashlineHeader(path, tag)}\n$multiOutput';
        }
        return ToolExecutionResult.text(multiOutput);
      }

      // Whole-file/raw or a single range: map onto the offset/limit pipeline.
      // A selector range past EOF gets omp's graceful note instead of the
      // offset-argument error.
      var effectiveOffset = offset;
      var effectiveLimit = limit;
      if (parsed is ReadSelectorLines) {
        final range = parsed.ranges.first;
        if (range.startLine > totalFileLines) {
          return ToolExecutionResult.text(
            'Line ${range.startLine} is beyond end of file '
            '($totalFileLines lines total). Use :1 to read from the start, '
            'or :$totalFileLines to read the last line.',
          );
        }
        effectiveOffset = range.startLine;
        effectiveLimit = range.endLine == null
            ? null
            : range.endLine! - range.startLine + 1;
      }

      final formatted = _selectAndTruncate(
        allLines: allLines,
        entityLabel: 'file',
        offset: effectiveOffset,
        limit: effectiveLimit,
        raw: raw,
        numbered: hashlineMode && !raw,
        path: path,
      );
      var outputText = formatted.text;

      if (hashlineMode && !raw) {
        // Record the FULL normalized file text (the tag is a whole-file
        // content hash) plus the 1-indexed lines actually displayed, so a
        // later edit patch validates the tag and the seen-line guard knows
        // which lines the model was shown.
        final normalized = normalizeToLF(stripBom(rawContent).text);
        final canonical = (await env.absolutePath(path)).valueOrNull ?? path;
        final lastDisplayed =
            formatted.startLineDisplay + formatted.displayedLines - 1;
        final seenLines = [
          for (
            var line = formatted.startLineDisplay;
            line <= lastDisplayed;
            line++
          )
            line,
        ];
        final tag = store.record(canonical, normalized, seenLines);
        outputText = '${formatHashlineHeader(path, tag)}\n$outputText';
      }
      return ToolExecutionResult.text(outputText);
    },
  );
}

/// The result of [_selectAndTruncate]: the rendered text plus the window of
/// lines actually displayed (for hashline seen-line recording).
final class _SelectedText {
  const _SelectedText({
    required this.text,
    required this.startLineDisplay,
    required this.displayedLines,
  });

  /// The rendered output (including any continuation notices).
  final String text;

  /// 1-indexed number of the first displayed line.
  final int startLineDisplay;

  /// Number of whole lines that survived truncation.
  final int displayedLines;
}

/// Selects [offset]/[limit] lines out of [allLines] and renders them with
/// the shared head truncation and continuation notices (pi's
/// `truncateHead`). This is the single-range/whole-file pipeline shared by
/// local reads and archive member reads:
///
/// - [raw] (omp's `:raw`) suppresses line numbers and every notice, and
///   answers a first-line-over-byte-limit with a byte snippet instead of the
///   `sed` hint (omp's in-memory `truncateHeadBytes` path).
/// - [numbered] prefixes each line with its real 1-indexed number (hashline
///   display mode).
/// - [path] enables the `sed` continuation hint for local files; pass null
///   for archive members (a snippet is shown instead, like omp).
_SelectedText _selectAndTruncate({
  required List<String> allLines,
  required String entityLabel,
  int? offset,
  int? limit,
  bool raw = false,
  bool numbered = false,
  String? path,
}) {
  final totalFileLines = allLines.length;
  final startLine = offset != null && offset > 1 ? offset - 1 : 0;
  final startLineDisplay = startLine + 1;
  if (startLine >= allLines.length) {
    throw StateError(
      'Offset $offset is beyond end of $entityLabel '
      '($totalFileLines lines total)',
    );
  }

  String selectedContent;
  int? userLimitedLines;
  if (limit != null) {
    final endLine = (startLine + limit) < allLines.length
        ? startLine + limit
        : allLines.length;
    selectedContent = allLines.sublist(startLine, endLine).join('\n');
    userLimitedLines = endLine - startLine;
  } else {
    selectedContent = allLines.sublist(startLine).join('\n');
  }

  final displayContent = numbered
      ? formatNumberedLines(selectedContent, startLineDisplay)
      : selectedContent;
  final truncation = _truncateHead(displayContent);
  String outputText;
  if (truncation.firstLineExceedsLimit) {
    if (raw || path == null) {
      outputText = _bytePrefixSnippet(allLines[startLine], defaultToolMaxBytes);
    } else {
      outputText =
          '[Line $startLineDisplay is '
          '${formatToolSize(_byteLength(allLines[startLine]))}, exceeds '
          '${formatToolSize(defaultToolMaxBytes)} limit. Use bash: '
          "sed -n '${startLineDisplay}p' $path | "
          'head -c $defaultToolMaxBytes]';
    }
  } else if (truncation.truncated) {
    final endLineDisplay = startLineDisplay + truncation.outputLines - 1;
    final nextOffset = endLineDisplay + 1;
    outputText = truncation.content;
    if (!raw) {
      if (truncation.truncatedBy == _TruncatedBy.lines) {
        outputText +=
            '\n\n[Showing lines $startLineDisplay-$endLineDisplay of '
            '$totalFileLines. Use offset=$nextOffset to continue.]';
      } else {
        outputText +=
            '\n\n[Showing lines $startLineDisplay-$endLineDisplay of '
            '$totalFileLines (${formatToolSize(defaultToolMaxBytes)} limit). '
            'Use offset=$nextOffset to continue.]';
      }
    }
  } else if (!raw &&
      userLimitedLines != null &&
      startLine + userLimitedLines < allLines.length) {
    final remaining = allLines.length - (startLine + userLimitedLines);
    final nextOffset = startLine + userLimitedLines + 1;
    outputText =
        '${truncation.content}\n\n[$remaining more lines in $entityLabel. '
        'Use offset=$nextOffset to continue.]';
  } else {
    outputText = truncation.content;
  }
  return _SelectedText(
    text: outputText,
    startLineDisplay: startLineDisplay,
    displayedLines: truncation.outputLines,
  );
}

/// Returns the longest leading substring of [line] whose UTF-8 encoding fits
/// within [maxBytes] (omp's `truncateHeadBytes`), shown when a raw or
/// archive read hits a first line that alone exceeds the byte limit.
String _bytePrefixSnippet(String line, int maxBytes) {
  final bytes = utf8.encode(line);
  if (bytes.length <= maxBytes) return line;
  // Walk back to a UTF-8 boundary (continuation bytes match 10xxxxxx).
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

/// Renders a multi-range selector against in-memory text (omp's
/// `#buildInMemoryMultiRangeResult`): each in-bounds range emits one block
/// (numbered in hashline mode), blocks join with an elision separator, and
/// ranges past EOF surface as `[… skipped]` notices so the model can correct
/// the next call. No leading/trailing context is added — multi-range callers
/// always specify exact bounds.
({String text, List<int> seenLines}) _formatMultiRange({
  required List<String> allLines,
  required List<LineRange> ranges,
  required bool raw,
  required bool hashlineMode,
  required String entityLabel,
}) {
  final totalLines = allLines.length;
  final notices = <String>[];
  final blocks = <String>[];
  final blockStarts = <int>[];
  final blockLengths = <int>[];
  for (final range in ranges) {
    if (range.startLine > totalLines) {
      final bound = range.endLine != null
          ? '${range.startLine}-${range.endLine}'
          : '${range.startLine}';
      notices.add(
        '[Range $bound is beyond end of $entityLabel '
        '($totalLines lines total); skipped]',
      );
      continue;
    }
    final end = range.endLine == null
        ? totalLines
        : (range.endLine! < totalLines ? range.endLine! : totalLines);
    final blockText = allLines.sublist(range.startLine - 1, end).join('\n');
    blocks.add(
      hashlineMode && !raw
          ? formatNumberedLines(blockText, range.startLine)
          : blockText,
    );
    blockStarts.add(range.startLine);
    blockLengths.add(end - range.startLine + 1);
  }

  var output = blocks.join('\n\n…\n\n');
  final truncation = _truncateHead(output);
  output = truncation.content;

  // Seen lines for the hashline store: walk the blocks against the surviving
  // whole-line budget (the blank/…/blank separator lines consume budget but
  // map to no file lines).
  final seenLines = <int>[];
  if (hashlineMode && !raw) {
    var budget = truncation.outputLines;
    for (var i = 0; i < blocks.length && budget > 0; i++) {
      final kept = blockLengths[i] < budget ? blockLengths[i] : budget;
      for (var line = blockStarts[i]; line < blockStarts[i] + kept; line++) {
        seenLines.add(line);
      }
      budget -= kept;
      if (budget > 0 && i + 1 < blocks.length) budget -= 3;
    }
  }

  if (truncation.truncated) {
    final note =
        '[Output truncated: showing ${truncation.outputLines} of '
        '${truncation.totalLines} selected lines. Use narrower ranges to '
        'continue.]';
    output = output.isEmpty ? note : '$output\n\n$note';
  }
  if (notices.isNotEmpty) {
    output = output.isEmpty
        ? notices.join('\n')
        : '$output\n${notices.join('\n')}';
  }
  return (text: output, seenLines: seenLines);
}

/// Converts a single-range selector to the offset/limit pair used by archive
/// directory listings (omp's `selToOffsetLimit`): returns the FIRST range
/// only — multi-range callers must branch before calling this.
({int? offset, int? limit}) _selToOffsetLimit(ReadSelector sel) {
  if (sel is ReadSelectorLines) {
    final first = sel.ranges.first;
    return (
      offset: first.startLine,
      limit: first.endLine == null
          ? null
          : first.endLine! - first.startLine + 1,
    );
  }
  return (offset: null, limit: null);
}

// ---------------------------------------------------------------------------
// read: archive inner paths (omp's #readArchive / #readArchiveDirectory)
// ---------------------------------------------------------------------------

/// Probes [rawPath] for archive targets (`archive.zip:inner/…`, also `.tar`,
/// `.tar.gz`/`.tgz`) and reads the member or listing when a candidate names
/// an existing archive file. Returns null when no candidate resolves — the
/// caller falls through to a plain file read.
Future<ToolExecutionResult?> _tryReadArchive(
  ExecutionEnv env,
  String rawPath,
  CancelToken? cancelToken,
) async {
  final candidates = parseArchivePathCandidates(rawPath);
  for (final candidate in candidates) {
    final info = await env.fileInfo(candidate.archivePath);
    if (info.isErr) continue;
    if (info.valueOrNull!.kind != FileKind.file) continue;

    final bytesRead = await env.readBinaryFile(candidate.archivePath);
    if (bytesRead.isErr) throw StateError('${bytesRead.errorOrNull}');
    cancelToken?.throwIfCancelled();
    final format = archiveFormatFromPath(candidate.archivePath)!;
    final archive = ArchiveReader.decode(bytesRead.valueOrNull!, format);
    cancelToken?.throwIfCancelled();

    // `archive.zip:inner.txt:50-60`: peel the selector off the member path.
    final subSplit = splitPathAndSel(candidate.subPath);
    var sel = parseSel(subSplit.sel);
    var archiveSubPath = subSplit.path;
    var node = archive.getNode(archiveSubPath);
    if (node == null && archiveSubPath.isNotEmpty) {
      // `archive.zip:500` / `archive.zip:raw`: the whole subPath is a
      // selector on the archive root, not a member name. Member names take
      // precedence (the getNode above); fall back to root + selector (omp).
      final wholeSel = parseSel(archiveSubPath);
      if (wholeSel is! ReadSelectorNone) {
        node = archive.getNode('');
        archiveSubPath = '';
        sel = wholeSel;
      }
    }
    if (node == null) {
      throw StateError("Path '$rawPath' not found inside archive");
    }

    if (node.isDirectory) {
      if (sel is ReadSelectorLines && sel.ranges.length > 1) {
        throw StateError(
          'Multi-range line selectors are not supported for archive '
          'directory listings.',
        );
      }
      final (:offset, :limit) = _selToOffsetLimit(sel);
      return _readArchiveDirectory(archive, archiveSubPath, offset, limit);
    }

    final entryBytes = archive.readFileBytes(archiveSubPath);
    cancelToken?.throwIfCancelled();
    final text = decodeUtf8Text(entryBytes);
    if (text == null) {
      return ToolExecutionResult.text(
        "[Cannot read binary archive entry '${node.path}' "
        '(${formatToolSize(entryBytes.length)})]',
      );
    }

    // Archive members are immutable — there is no edit path for bytes inside
    // an archive, and a hashline tag keyed to the archive file would invite
    // (and fail) edits — so the member renders without hashline anchors
    // (omp's immutable display mode). Selectors still apply.
    final entryLines = text.split('\n');
    final raw = isRawSelector(sel);
    if (sel is ReadSelectorLines) {
      if (sel.ranges.length > 1) {
        return ToolExecutionResult.text(
          _formatMultiRange(
            allLines: entryLines,
            ranges: sel.ranges,
            raw: raw,
            hashlineMode: false,
            entityLabel: 'archive entry',
          ).text,
        );
      }
      final range = sel.ranges.first;
      if (range.startLine > entryLines.length) {
        return ToolExecutionResult.text(
          'Line ${range.startLine} is beyond end of archive entry '
          '(${entryLines.length} lines total). Use :1 to read from the '
          'start, or :${entryLines.length} to read the last line.',
        );
      }
      return ToolExecutionResult.text(
        _selectAndTruncate(
          allLines: entryLines,
          entityLabel: 'archive entry',
          offset: range.startLine,
          limit: range.endLine == null
              ? null
              : range.endLine! - range.startLine + 1,
          raw: raw,
        ).text,
      );
    }
    return ToolExecutionResult.text(
      _selectAndTruncate(
        allLines: entryLines,
        entityLabel: 'archive entry',
        raw: raw,
      ).text,
    );
  }
  return null;
}

/// Renders an archive directory listing (omp's `#readArchiveDirectory`):
/// immediate children, directories suffixed with `/`, files with their size,
/// capped at [limit] entries (default [defaultArchiveListLimit]) and the
/// shared byte cap. A selector offset starts the listing at the Nth entry
/// (`a.zip:dir:50`).
ToolExecutionResult _readArchiveDirectory(
  ArchiveReader archive,
  String subPath,
  int? offset,
  int? limit,
) {
  final allEntries = archive.listDirectory(subPath);
  final entries = offset != null && offset > 1
      ? allEntries.skip(offset - 1)
      : allEntries;
  final effectiveLimit = limit ?? defaultArchiveListLimit;
  final results = <String>[];
  for (final entry in entries) {
    if (results.length >= effectiveLimit) break;
    if (entry.isDirectory) {
      results.add('${entry.name}/');
    } else {
      results.add(
        entry.size > 0
            ? '${entry.name} (${formatToolSize(entry.size)})'
            : entry.name,
      );
    }
  }
  final output = results.isEmpty
      ? '(empty archive directory)'
      : results.join('\n');
  // Byte truncation only; the entry count is already capped above (omp sets
  // the list-limit metadata without a text notice).
  return ToolExecutionResult.text(
    _truncateHead(output, maxLines: 1 << 62).content,
  );
}

// ---------------------------------------------------------------------------
// read: SQLite targets (omp's #readSqlite)
// ---------------------------------------------------------------------------

/// Probes [rawPath] for SQLite targets (`data.db:table?…`) and renders the
/// selected view when a candidate names an existing database file. Returns
/// null when no candidate resolves. Without a [SqliteEngine] (web hosts have
/// no FFI) a resolved target yields a clean "not supported" note instead of
/// opening the file.
Future<ToolExecutionResult?> _tryReadSqlite(
  ExecutionEnv env,
  String rawPath,
  SqliteEngine? engine,
) async {
  final candidates = parseSqlitePathCandidates(rawPath);
  for (final candidate in candidates) {
    final info = await env.fileInfo(candidate.sqlitePath);
    if (info.isErr) continue;
    if (info.valueOrNull!.kind != FileKind.file) continue;

    final selector = parseSqliteSelector(
      candidate.subPath,
      candidate.queryString,
    );
    if (engine == null) {
      return ToolExecutionResult.text(
        '[SQLite database reads are not supported in this environment '
        '(no SQLite engine available); ${candidate.sqlitePath} was not '
        'opened.]',
      );
    }

    final absolute =
        (await env.absolutePath(candidate.sqlitePath)).valueOrNull ??
        candidate.sqlitePath;
    SqliteDatabase? db;
    try {
      db = engine.openReadOnly(absolute);
      switch (selector) {
        case SqliteListSelector():
          final tables = listSqliteTables(
            db,
          ).take(maxSqliteTableListEntries).toList();
          return ToolExecutionResult.text(renderSqliteTableList(tables));
        case SqliteSchemaSelector(:final table, :final sampleLimit):
          final sample = querySqliteRows(
            db,
            table,
            limit: sampleLimit,
            offset: 0,
          );
          var output = renderSqliteSchema(
            getSqliteTableSchema(db, table),
            SqliteRows(columns: sample.columns, rows: sample.rows),
          );
          if (sample.rows.length < sample.totalCount) {
            final remaining = sample.totalCount - sample.rows.length;
            output +=
                '\n[$remaining more rows; append '
                ':$table?limit=$defaultSqliteQueryLimit&offset=${sample.rows.length} '
                'to the database path to continue]';
          }
          return ToolExecutionResult.text(output);
        case SqliteRowSelector(:final table, :final key):
          final lookup = resolveSqliteRowLookup(db, table);
          final row = getSqliteRow(db, table, lookup, key);
          if (row == null) {
            return ToolExecutionResult.text(
              "No row found in table '$table' for key '$key'.",
            );
          }
          return ToolExecutionResult.text(renderSqliteRow(row));
        case SqliteQuerySelector(
          :final table,
          :final limit,
          :final offset,
          :final order,
          :final where,
        ):
          final page = querySqliteRows(
            db,
            table,
            limit: limit,
            offset: offset,
            order: order,
            where: where,
          );
          return ToolExecutionResult.text(
            renderSqliteTable(
              page.columns,
              page.rows,
              totalCount: page.totalCount,
              offset: offset,
              limit: limit,
              table: table,
            ),
          );
        case SqliteRawSelector(:final sql):
          final result = executeSqliteReadQuery(db, sql);
          var output = renderSqliteTable(
            result.columns,
            result.rows,
            totalCount: result.rows.length,
            offset: 0,
            limit: result.rows.isEmpty
                ? defaultToolMaxLines
                : result.rows.length,
            table: 'query',
          );
          if (result.truncated) {
            output +=
                '\n[Output capped at $maxSqliteRawQueryRows rows; add a '
                'LIMIT/OFFSET clause to the query to page through more]';
          }
          return ToolExecutionResult.text(output);
      }
    } on StateError {
      rethrow;
    } on Object catch (error) {
      // Engine/backend failures (e.g. "file is not a database") surface as
      // the tool's error channel, mirroring omp's ToolError wrap.
      throw StateError('$error');
    } finally {
      db?.close();
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// write (ported from pi's tools/write.ts)
// ---------------------------------------------------------------------------

/// Creates the `write` tool: creates or overwrites a file, creating parent
/// directories as needed.
AgentTool writeFileTool(ExecutionEnv env) {
  return AgentTool(
    name: 'write',
    label: 'write',
    tier: ApprovalTier.write,
    description:
        'Write content to a file, creating parent directories as needed. '
        'Overwrites the file if it already exists.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the file to write (relative or absolute)',
        },
        'content': {
          'type': 'string',
          'description': 'Content to write to the file',
        },
      },
      'required': ['path', 'content'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String;
      final content = arguments['content'] as String;
      final written = await env.writeFile(path, content);
      if (written.isErr) throw StateError('${written.errorOrNull}');
      return ToolExecutionResult.text(
        'Successfully wrote ${_byteLength(content)} bytes to $path',
      );
    },
  );
}

// ---------------------------------------------------------------------------
// edit (exact-match replace, or hashline patch with content-hash anchors)
// ---------------------------------------------------------------------------

/// Creates the `edit` tool: edits a file in one of two modes.
///
/// Legacy exact-match mode (`path` + `oldText` + `newText`): the replacement
/// only happens when `oldText` occurs exactly once — the cheap, model-friendly
/// way to make precise code edits without rewriting whole files (mirrors pi's
/// `edit` and Claude Code's `str_replace` tools).
///
/// Hashline mode (`patch`): a hashline patch with `[path#TAG]` section
/// headers and `SWAP`/`DEL`/`INS` ops on 1-indexed line anchors, ported from
/// oh-my-pi `packages/hashline`. The tag is a whole-file content hash minted
/// by a hashline-mode `read` (or a previous edit response); a stale tag is
/// rejected BEFORE any write with a diagnostic naming the drifted lines, so
/// a mistargeted edit can never silently corrupt the file.
///
/// [snapshots] is the session snapshot store binding tags to file content;
/// share it with the `read` tool (via [builtinTools]) so read-minted tags
/// validate here.
AgentTool editFileTool(ExecutionEnv env, {HashlineSnapshotStore? snapshots}) {
  final store = snapshots ?? HashlineSnapshotStore();
  return AgentTool(
    name: 'edit',
    label: 'edit',
    tier: ApprovalTier.write,
    description: editToolDescriptionPrompt,
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'Path to the file to edit (relative or absolute). Required '
              'for exact-match mode; optional in hashline mode (the patch '
              'header carries its own [path#TAG]).',
        },
        'oldText': {
          'type': 'string',
          'description':
              'Exact-match mode: exact text to replace. Must occur exactly '
              'once in the file.',
        },
        'newText': {
          'type': 'string',
          'description':
              'Exact-match mode: replacement text (may be empty to delete '
              'oldText).',
        },
        'patch': {
          'type': 'string',
          'description':
              'Hashline mode: a hashline patch — [path#TAG] section '
              'header(s) followed by SWAP/DEL/INS ops anchored on line '
              'numbers from a hashline-mode read.',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String?;
      final oldText = arguments['oldText'] as String?;
      final newText = arguments['newText'] as String?;
      final patch = arguments['patch'] as String?;

      if (patch != null) {
        if (oldText != null || newText != null) {
          throw StateError(
            'Provide either patch (hashline mode) or oldText/newText '
            '(exact-match mode), not both.',
          );
        }
        return _executeHashlineEdit(env, store, path, patch, cancelToken);
      }
      if (path == null || oldText == null || newText == null) {
        throw StateError(
          'Missing arguments: provide either patch (hashline mode) or '
          'path + oldText + newText (exact-match mode).',
        );
      }
      return _executeExactMatchEdit(env, path, oldText, newText, cancelToken);
    },
  );
}

Future<ToolExecutionResult> _executeExactMatchEdit(
  ExecutionEnv env,
  String path,
  String oldText,
  String newText,
  CancelToken? cancelToken,
) async {
  if (oldText.isEmpty) {
    throw StateError('oldText must not be empty');
  }

  final read = await env.readTextFile(path);
  if (read.isErr) throw StateError('${read.errorOrNull}');
  cancelToken?.throwIfCancelled();
  final content = read.valueOrNull!;

  final occurrences = _countOccurrences(content, oldText);
  if (occurrences == 0) {
    throw StateError(
      'No exact match found in $path. oldText must match the file '
      'contents byte-for-byte (check whitespace and newlines with read).',
    );
  }
  if (occurrences > 1) {
    throw StateError(
      'oldText occurs $occurrences times in $path and is ambiguous. '
      'Include more surrounding context so it matches exactly once.',
    );
  }

  final updated = content.replaceFirst(oldText, newText);
  final written = await env.writeFile(path, updated);
  if (written.isErr) throw StateError('${written.errorOrNull}');

  return ToolExecutionResult.text(
    'Edited $path: replaced ${_byteLength(oldText)} bytes with '
    '${_byteLength(newText)} bytes.',
  );
}

/// Runs one hashline-mode edit: parses [patchText], applies it all-or-
/// nothing via [HashlinePatcher], and renders the post-edit `[path#TAG]`
/// header(s) the model anchors its next edit on (omp's edit response).
Future<ToolExecutionResult> _executeHashlineEdit(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String? path,
  String patchText,
  CancelToken? cancelToken,
) async {
  final patch = HashlinePatch.parse(patchText, fallbackPath: path);
  if (patch.sections.isEmpty) {
    throw StateError('No hashline sections found in patch input.');
  }
  final patcher = HashlinePatcher(env: env, snapshots: store);
  final result = await patcher.apply(patch);
  cancelToken?.throwIfCancelled();

  // Single-section no-op: the body rows matched the file byte-for-byte —
  // surface omp's soft diagnostic so the model re-reads instead of widening
  // the payload (multi-section no-ops already threw inside `apply`).
  if (result.sections.length == 1 &&
      result.sections[0].op == HashlineSectionOp.noop) {
    return ToolExecutionResult.text(
      noChangeDiagnostic(result.sections[0].path),
    );
  }

  final parts = <String>[];
  for (final section in result.sections) {
    final buffer = StringBuffer(section.header);
    if (section.firstChangedLine != null) {
      buffer.write('\nFirst change at line ${section.firstChangedLine}.');
    }
    if (section.warnings.isNotEmpty) {
      buffer.write('\n\nWarnings:\n${section.warnings.join('\n')}');
    }
    parts.add(buffer.toString());
  }
  return ToolExecutionResult.text(parts.join('\n\n'));
}

int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var start = 0;
  while (true) {
    final index = haystack.indexOf(needle, start);
    if (index == -1) return count;
    count++;
    start = index + needle.length;
  }
}

// ---------------------------------------------------------------------------
// ls (ported from pi's tools/ls.ts)
// ---------------------------------------------------------------------------

/// Creates the `ls` tool: lists directory entries sorted alphabetically
/// (case-insensitive), directories suffixed with `/`, capped at `limit`
/// entries (default [defaultLsEntryLimit]) and [defaultToolMaxBytes] bytes.
AgentTool listDirTool(ExecutionEnv env) {
  return AgentTool(
    name: 'ls',
    label: 'ls',
    tier: ApprovalTier.read,
    description:
        'List directory contents. Returns entries sorted alphabetically, '
        "with '/' suffix for directories. Output is truncated to "
        '$defaultLsEntryLimit entries or ${defaultToolMaxBytes ~/ 1024}KB '
        '(whichever is hit first).',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Directory to list (default: current directory)',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum number of entries to return (default: 500)',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = (arguments['path'] as String?) ?? '.';
      final limit =
          (arguments['limit'] as num?)?.toInt() ?? defaultLsEntryLimit;

      // POSIX ls accepts a file path and prints the file name. Check the
      // target kind first so we don't fail with notDirectory for a file.
      final info = await env.fileInfo(path);
      if (info.isErr) {
        // Fall back to listing if we can't stat (e.g. path with a trailing
        // slash or a backend where fileInfo is unsupported).
        if (info.errorOrNull!.code != FileErrorCode.notSupported) {
          throw StateError('${info.errorOrNull}');
        }
      } else if (info.valueOrNull!.kind == FileKind.file) {
        return ToolExecutionResult.text(info.valueOrNull!.name);
      }

      final listed = await env.listDir(path);
      if (listed.isErr) throw StateError('${listed.errorOrNull}');
      cancelToken?.throwIfCancelled();

      final entries = listed.valueOrNull!.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      final results = <String>[];
      var entryLimitReached = false;
      for (final entry in entries) {
        if (results.length >= limit) {
          entryLimitReached = true;
          break;
        }
        final suffix = entry.kind == FileKind.directory ? '/' : '';
        results.add('${entry.name}$suffix');
      }

      if (results.isEmpty && !entryLimitReached) {
        return ToolExecutionResult.text('(empty directory)');
      }

      // Byte truncation only: the entry count is already capped above.
      final truncation = _truncateHead(results.join('\n'), maxLines: 1 << 62);
      var output = truncation.content;
      final notices = <String>[];
      if (entryLimitReached) {
        notices.add(
          '$limit entries limit reached. Use limit=${limit * 2} for more',
        );
      }
      if (truncation.truncated) {
        notices.add('${formatToolSize(defaultToolMaxBytes)} limit reached');
      }
      if (notices.isNotEmpty) output += '\n\n[${notices.join('. ')}]';
      return ToolExecutionResult.text(output);
    },
  );
}

// ---------------------------------------------------------------------------
// bash (ported subset of pi's tools/bash.ts)
// ---------------------------------------------------------------------------

Duration _resolveTimeout(num timeoutSeconds) {
  if (!timeoutSeconds.isFinite || timeoutSeconds <= 0) {
    throw StateError('Invalid timeout: must be a finite number of seconds');
  }
  final timeoutMs = (timeoutSeconds * 1000).round();
  if (timeoutMs > _maxTimeoutMs) {
    throw StateError(
      'Invalid timeout: maximum is ${_maxTimeoutMs / 1000} seconds',
    );
  }
  return Duration(milliseconds: timeoutMs);
}

String _appendStatus(String text, String status) {
  return text.isEmpty ? status : '$text\n\n$status';
}

/// Creates the `bash` tool: executes a shell command via [ExecutionEnv.exec]
/// and returns stdout followed by stderr, truncated to the last
/// [defaultToolMaxLines] lines / [defaultToolMaxBytes] bytes. A non-zero
/// exit code, timeout, or abort throws (the loop turns it into an error
/// tool result, pi semantics).
AgentTool shellTool(ExecutionEnv env) {
  return AgentTool(
    name: bashToolName,
    label: 'bash',
    tier: ApprovalTier.exec,
    description:
        'Execute a bash command in the current working directory. Returns '
        'stdout and stderr. Output is truncated to the last '
        '$defaultToolMaxLines lines or ${defaultToolMaxBytes ~/ 1024}KB '
        '(whichever is hit first). Optionally provide a timeout in seconds.',
    parameters: const {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'The bash command to execute',
        },
        'timeout': {
          'type': 'number',
          'description': 'Timeout in seconds (optional, no default timeout)',
        },
      },
      'required': ['command'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final command = arguments['command'] as String;
      final timeoutArg = arguments['timeout'] as num?;
      final timeout = timeoutArg == null ? null : _resolveTimeout(timeoutArg);

      final result = await env.exec(
        command,
        options: ShellExecOptions(timeout: timeout, cancelToken: cancelToken),
      );

      String outputOf(ShellExecResult execResult) {
        final parts = <String>[
          if (execResult.stdout.isNotEmpty) execResult.stdout,
          if (execResult.stderr.isNotEmpty) execResult.stderr,
        ];
        return parts.join('\n');
      }

      String truncate(String output) {
        final truncation = _truncateTail(output);
        if (!truncation.truncated) return output;
        final startLine = truncation.totalLines - truncation.outputLines + 1;
        final endLine = truncation.totalLines;
        var notice =
            '\n\n[Showing lines $startLine-$endLine of ${truncation.totalLines}';
        if (truncation.truncatedBy == _TruncatedBy.bytes) {
          notice += ' (${formatToolSize(defaultToolMaxBytes)} limit)';
        }
        return '${truncation.content}$notice.]';
      }

      if (result.isErr) {
        final error = result.errorOrNull!;
        throw switch (error.code) {
          ExecutionErrorCode.aborted => StateError(
            _appendStatus('', 'Command aborted'),
          ),
          ExecutionErrorCode.timeout => StateError(
            _appendStatus(
              '',
              'Command timed out after ${timeoutArg ?? 'unknown'} seconds',
            ),
          ),
          _ => StateError('$error'),
        };
      }

      final execResult = result.valueOrNull!;
      final rawOutput = outputOf(execResult);
      if (execResult.exitCode != 0) {
        throw StateError(
          _appendStatus(
            truncate(rawOutput),
            'Command exited with code ${execResult.exitCode}',
          ),
        );
      }
      final output = truncate(rawOutput);
      return ToolExecutionResult.text(output.isEmpty ? '(no output)' : output);
    },
  );
}
