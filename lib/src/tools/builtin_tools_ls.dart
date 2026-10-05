/// The `ls` tool ([listDirTool], pi's `tools/ls.ts`): the sorted, capped directory listing with entry-limit and byte-limit notices. Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

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
      return _listDirectory(env, path, limit, cancelToken);
    },
  );
}

/// Runs one `ls` call: resolves a plain-file target to its name (POSIX ls
/// prints the file name), otherwise lists the directory sorted and renders
/// the capped entry names with the limit notices.
Future<ToolExecutionResult> _listDirectory(
  ExecutionEnv env,
  String path,
  int limit,
  CancelToken? cancelToken,
) async {
  final fileName = await _fileListingName(env, path);
  if (fileName != null) return ToolExecutionResult.text(fileName);

  final listed = await env.listDir(path);
  if (listed.isErr) throw StateError('${listed.errorOrNull}');
  cancelToken?.throwIfCancelled();

  final entries = listed.valueOrNull!.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  final (:results, :entryLimitReached) = _cappedEntryNames(entries, limit);
  if (results.isEmpty && !entryLimitReached) {
    return ToolExecutionResult.text('(empty directory)');
  }
  return _listingOutput(results, limit, entryLimitReached);
}

/// Returns the entry name when [path] resolves to a plain file (POSIX ls
/// accepts a file path and prints the file name), or null to fall through to
/// a directory listing. Checking the target kind first keeps a file path
/// from failing with notDirectory; an unsupported stat falls back to
/// listing (e.g. path with a trailing slash or a backend where fileInfo is
/// unsupported).
Future<String?> _fileListingName(ExecutionEnv env, String path) async {
  final info = await env.fileInfo(path);
  if (info.isErr) {
    if (info.errorOrNull!.code != FileErrorCode.notSupported) {
      throw StateError('${info.errorOrNull}');
    }
    return null;
  }
  if (info.valueOrNull!.kind == FileKind.file) {
    return info.valueOrNull!.name;
  }
  return null;
}

/// Renders up to [limit] entry names (directories suffixed with `/`),
/// reporting when the cap stopped the walk.
({List<String> results, bool entryLimitReached}) _cappedEntryNames(
  List<FileInfo> entries,
  int limit,
) {
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
  return (results: results, entryLimitReached: entryLimitReached);
}

/// Renders the listing output: byte truncation only (the entry count is
/// already capped by [_cappedEntryNames]) plus the limit notices.
ToolExecutionResult _listingOutput(
  List<String> results,
  int limit,
  bool entryLimitReached,
) {
  final truncation = _truncateHead(
    results.join('\n'),
    maxLines: _unboundedMaxLines,
  );
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
}
