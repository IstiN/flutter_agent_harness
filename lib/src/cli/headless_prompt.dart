/// Headless prompt-source resolution for the `fah` executable
/// (`bin/fah.dart`): `fah "prompt"` text, or a file passed instead of the
/// prompt.
///
/// `dart:io` lives here (exported only from `lib/io.dart`) so the agent core
/// stays pure Dart.
library;

import 'dart:io';

import 'cli_args.dart';

/// File extensions whose content is inlined as the headless prompt body.
const headlessTextExtensions = {'.md', '.markdown', '.txt'};

/// Resolves the headless prompt from parsed CLI arguments.
///
/// - [CliArgs.prompt] (`-p`/`--prompt`) is used verbatim — never resolved as
///   a file.
/// - Empty [CliArgs.positionals] (and no `-p`) returns null: interactive
///   REPL mode.
/// - When the FIRST positional names an existing file (relative paths
///   resolve against the process working directory — where the user typed
///   the command, not `--cwd`): a text file ([headlessTextExtensions]) is
///   read and its content becomes the prompt; any other file becomes a path
///   reference (`[attached file: ... — read it with your tools]` with the
///   absolute path) so the agent opens it with its own tools. Remaining
///   positionals append as the instruction in both cases. A text file that
///   fails to read (permissions, invalid UTF-8) falls back to the path
///   reference.
/// - A first positional that does NOT name an existing file is plain prompt
///   text: all positionals join with spaces (a sentence may contain
///   slashes — never fail on a missing "file").
String? resolveHeadlessPrompt({
  String? prompt,
  List<String> positionals = const [],
}) {
  if (prompt != null) return prompt;
  if (positionals.isEmpty) return null;
  final file = File(positionals.first);
  if (!file.existsSync()) return positionals.join(' ');
  final trailing = positionals.skip(1).join(' ');
  final lower = file.path.toLowerCase();
  if (headlessTextExtensions.any(lower.endsWith)) {
    try {
      final content = file.readAsStringSync();
      return trailing.isEmpty ? content : '$content\n\n$trailing';
    } on Object {
      // Unreadable or undecodable "text" file: attach by path instead.
    }
  }
  final reference =
      '[attached file: ${file.absolute.path} — read it with your tools]';
  return trailing.isEmpty ? reference : '$reference\n\n$trailing';
}

/// Creates the [File] probed by [resolveInteractiveFileReference].
typedef InputPromptFileFactory = File Function(String path);

/// Files bigger than this are not read at all for statistics — size alone
/// tells the model enough (pi-style estimate reads must never stall paste).
const _attachStatsReadCap = 8 * 1024 * 1024;

/// Resolves an interactive prompt that starts with a pasted file path.
///
/// The first whitespace-delimited token is treated as a file reference
/// when it looks path-like (`/…`, `~/`, `./`, `../`) AND names an
/// existing file. It becomes an explicit `[attached file: …]` path
/// reference — the marker headless mode uses too — annotated with locally
/// measured stats so the model can judge the cost BEFORE reading:
///
///     [attached file: /logs/build.log (97.7 KB · 3412 lines · ~8500
///      tokens est.) — read it with your tools]
///
/// Size formats as human-readable B/KB/MB; decodable text additionally
/// reports line count and the repo's standard ~4-chars-per-token estimate
/// (the compaction heuristic in `token_estimation.dart`). Content itself
/// is deliberately NEVER inlined — pasting happens before anyone looked
/// at the size, so the model decides whether and how much to read with
/// its tools (`read` takes line-range selectors). For files over
/// [_attachStatsReadCap] the content is not read even for statistics;
/// the size speaks for itself. Everything typed after the path rides
/// along as the instruction.
///
/// Conservative by design: a token without a path-like prefix is never
/// converted (plain sentences and bare words stay untouched), and input
/// with no such leading reference returns unchanged.
String resolveInteractiveFileReference(
  String text, {
  InputPromptFileFactory fileOf = _defaultFileOf,
}) {
  final token = _leadingPathLikeToken(text);
  if (token == null) return text;
  final file = fileOf(token);
  try {
    if (!file.existsSync()) return text;
  } on Object {
    return text;
  }
  var length = 0;
  try {
    length = file.lengthSync();
  } on Object {
    // Stats are best-effort; an unreadable length still attaches.
  }
  final textStats = _attachTextStats(file, length);
  final stats = [_formatAttachBytes(length), ?textStats].join(' · ');
  final trailing = text.trimLeft().substring(token.length).trim();
  final body =
      '[attached file: ${file.absolute.path} ($stats)'
      ' — read it with your tools]';
  return trailing.isEmpty ? body : '$body\n\n$trailing';
}

/// The first whitespace-delimited token of [text] after leading blanks,
/// or null when there is none or it lacks a path-like prefix (`/…`, `~/`,
/// `./`, `../`) — plain sentences and bare words stay untouched.
String? _leadingPathLikeToken(String text) {
  final trimmedStart = text.trimLeft();
  final match = RegExp(r'^\S+').firstMatch(trimmedStart);
  if (match == null) return null;
  const pathPrefixes = ['/', '~/', './', '../'];
  final token = match.group(0)!;
  return pathPrefixes.any(token.startsWith) ? token : null;
}

/// Line/token estimate annotation for a decodable text attachment, or
/// null when [length] reads as binary-or-oversized ([_attachStatsReadCap]
/// caps the probing read). Same ~4-chars-per-token heuristic the
/// compaction estimator uses.
String? _attachTextStats(File file, int length) {
  if (length <= 0 || length > _attachStatsReadCap) return null;
  try {
    final content = file.readAsStringSync();
    final lines = content.split('\n').length;
    final tokens = (content.length / _attachCharsPerToken).ceil();
    final tokenLabel =
        '~${tokens >= 10000 ? '${tokens ~/ 1000}k' : '$tokens'}'
        ' tokens est.';
    final lineLabel = '${lines == 1 ? '1 line' : '$lines lines'} · $tokenLabel';
    return lineLabel;
  } on Object {
    // Binary or undecodable: size-only annotation above.
    return null;
  }
}

/// Characters per token in the compaction estimation heuristic
/// (see `lib/src/compaction/token_estimation.dart`).
const _attachCharsPerToken = 4;

/// Human-readable byte size for attachment annotations: raw B under 1 KiB,
/// then one-decimal KB/MB/GB (two decimals dropped ≥ 100 to stay short).
String _formatAttachBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

File _defaultFileOf(String path) => File(path);
