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
