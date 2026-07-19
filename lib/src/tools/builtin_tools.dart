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
/// Deliberate divergences from the TypeScript originals:
///
/// - No image support in [readFileTool]: the [FileSystem] abstraction is
///   text-only, so image reads are deferred until binary reads land.
/// - The `bash` tool does not spill truncated output to a temp file (pi's
///   `fullOutputPath`); the truncation notice omits the path. Streaming
///   `onUpdate` partials and pi's `commandPrefix`/spawn hooks are also
///   deferred.
/// - [writeFileTool] reports UTF-8 bytes (pi reports `String.length`, which
///   is UTF-16 code units mislabeled as bytes).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../approval/bash_interceptor.dart';
import '../env/execution_env.dart';
import '../types.dart';

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
List<AgentTool> builtinTools(ExecutionEnv env) {
  return [
    readFileTool(env),
    writeFileTool(env),
    editFileTool(env),
    listDirTool(env),
    shellTool(env),
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

/// Formats a byte count as a human-readable size (pi's `formatSize`).
String formatToolSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

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

const _defaultImageMaxDimension = 2000;

const _supportedImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
  ImageFormat.bmp,
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

Uint8List _encodeImage(Image image, ImageFormat format) {
  return switch (format) {
    ImageFormat.png => encodePng(image),
    ImageFormat.jpg => encodeJpg(image),
    ImageFormat.gif => encodeGif(image),
    ImageFormat.webp => encodeWebP(image),
    ImageFormat.bmp => encodeBmp(image),
    _ => encodePng(image),
  };
}

({
  String mimeType,
  String base64,
  int width,
  int height,
  bool resized,
  int outputWidth,
  int outputHeight,
})
_processImage(
  Uint8List bytes,
  ImageFormat format, {
  int maxDimension = _defaultImageMaxDimension,
}) {
  final image = decodeImage(bytes);
  if (image == null) {
    throw StateError('Could not decode image');
  }
  final width = image.width;
  final height = image.height;
  var outputWidth = width;
  var outputHeight = height;
  var resized = false;
  Image output = image;

  if (width > maxDimension || height > maxDimension) {
    if (width >= height) {
      outputWidth = maxDimension;
      outputHeight = (height * maxDimension / width).round();
    } else {
      outputHeight = maxDimension;
      outputWidth = (width * maxDimension / height).round();
    }
    output = copyResize(
      image,
      width: outputWidth,
      height: outputHeight,
      interpolation: Interpolation.cubic,
    );
    resized = true;
  }

  final outputFormat = format == ImageFormat.bmp ? ImageFormat.jpg : format;
  final encoded = _encodeImage(output, outputFormat);
  final mimeType = _mimeTypeForImageFormat(outputFormat);
  if (mimeType == null) {
    throw StateError('Unsupported image format: $outputFormat');
  }

  return (
    mimeType: mimeType,
    base64: base64Encode(encoded),
    width: width,
    height: height,
    resized: resized,
    outputWidth: outputWidth,
    outputHeight: outputHeight,
  );
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
// read (ported from pi's tools/read.ts, with image support)
// ---------------------------------------------------------------------------

/// Creates the `read` tool: reads a text file or image with optional `offset`
/// (1-indexed) and `limit`, truncating text output to [defaultToolMaxLines]
/// lines or [defaultToolMaxBytes] bytes with an actionable continuation notice.
/// Images are decoded, optionally resized, and returned as base64 content.
AgentTool readFileTool(ExecutionEnv env) {
  return AgentTool(
    name: 'read',
    label: 'read',
    tier: ApprovalTier.read,
    description:
        'Read the contents of a text file or image. Text output is truncated '
        'to $defaultToolMaxLines lines or ${defaultToolMaxBytes ~/ 1024}KB '
        '(whichever is hit first). Use offset/limit for large text files. '
        'Images are returned as base64 content.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the file to read (relative or absolute)',
        },
        'offset': {
          'type': 'integer',
          'description': 'Line number to start reading from (1-indexed)',
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum number of lines to read',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String;
      final offset = (arguments['offset'] as num?)?.toInt();
      final limit = (arguments['limit'] as num?)?.toInt();

      final binaryRead = await env.readBinaryFile(path);
      if (binaryRead.isErr) throw StateError('${binaryRead.errorOrNull}');
      final bytes = binaryRead.valueOrNull!;
      cancelToken?.throwIfCancelled();

      final format = _detectImageFormat(bytes);
      if (format != null && _supportedImageFormats.contains(format)) {
        final processed = _processImage(bytes, format);
        final note = StringBuffer()
          ..write('[Image: $path, ${processed.width}x${processed.height}');
        if (processed.resized) {
          note.write(
            ', resized to ${processed.outputWidth}x${processed.outputHeight}',
          );
        }
        note.write(']');
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

      final allLines = read.valueOrNull!.split('\n');
      final totalFileLines = allLines.length;
      final startLine = offset != null && offset > 1 ? offset - 1 : 0;
      final startLineDisplay = startLine + 1;
      if (startLine >= allLines.length) {
        throw StateError(
          'Offset $offset is beyond end of file ($totalFileLines lines total)',
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

      final truncation = _truncateHead(selectedContent);
      String outputText;
      if (truncation.firstLineExceedsLimit) {
        outputText =
            '[Line $startLineDisplay is '
            '${formatToolSize(_byteLength(allLines[startLine]))}, exceeds '
            '${formatToolSize(defaultToolMaxBytes)} limit. Use bash: '
            "sed -n '${startLineDisplay}p' $path | "
            'head -c $defaultToolMaxBytes]';
      } else if (truncation.truncated) {
        final endLineDisplay = startLineDisplay + truncation.outputLines - 1;
        final nextOffset = endLineDisplay + 1;
        outputText = truncation.content;
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
      } else if (userLimitedLines != null &&
          startLine + userLimitedLines < allLines.length) {
        final remaining = allLines.length - (startLine + userLimitedLines);
        final nextOffset = startLine + userLimitedLines + 1;
        outputText =
            '${truncation.content}\n\n[$remaining more lines in file. '
            'Use offset=$nextOffset to continue.]';
      } else {
        outputText = truncation.content;
      }
      return ToolExecutionResult.text(outputText);
    },
  );
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
// edit (search & replace with a uniqueness guarantee)
// ---------------------------------------------------------------------------

/// Creates the `edit` tool: replaces an exact text occurrence in a file.
///
/// The replacement only happens when `oldText` occurs exactly once — this is
/// the cheap, model-friendly way to make precise code edits without
/// rewriting whole files (mirrors pi's `edit` and Claude Code's
/// `str_replace` tools).
AgentTool editFileTool(ExecutionEnv env) {
  return AgentTool(
    name: 'edit',
    label: 'edit',
    tier: ApprovalTier.write,
    description:
        'Edit a file by replacing an exact text occurrence. oldText must '
        'match exactly (including indentation and newlines) and occur exactly '
        'once in the file. Prefer this over write for small, precise changes '
        'to existing files; read the file first to get the exact text.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the file to edit (relative or absolute)',
        },
        'oldText': {
          'type': 'string',
          'description':
              'Exact text to replace. Must occur exactly once in the file.',
        },
        'newText': {
          'type': 'string',
          'description': 'Replacement text (may be empty to delete oldText)',
        },
      },
      'required': ['path', 'oldText', 'newText'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String;
      final oldText = arguments['oldText'] as String;
      final newText = arguments['newText'] as String;

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
    },
  );
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
