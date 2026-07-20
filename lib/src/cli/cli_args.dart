/// Command-line parsing for the `fah` executable (`bin/fah.dart`), extracted
/// as a pure, testable function: the executable maps the result to
/// usage/version output or an exit code, tests assert on it directly.
///
/// Two invocation shapes:
///
/// - interactive REPL: no prompt arguments (`fah --model ...`);
/// - headless: a prompt via `-p`/`--prompt <text>` or positional arguments
///   (`fah "summarize the changelog"` — multiple positionals join with
///   spaces, like claude/pi). A positional that names an existing file is
///   resolved as the prompt source by `resolveHeadlessPrompt` (see
///   `headless_prompt.dart`, exported from `lib/io.dart`).
library;

/// The provider kinds accepted by `--provider`.
const cliProviderKinds = {'openai-completions', 'anthropic', 'google'};

/// Invalid command line: the executable prints [message] plus a usage hint
/// to stderr and exits with code 64 (EX_USAGE).
final class CliArgsException implements Exception {
  /// Creates a [CliArgsException].
  const CliArgsException(this.message);

  /// The human-readable error.
  final String message;

  @override
  String toString() => message;
}

/// The outcome of parsing the `fah` argument list.
sealed class CliArgsResult {
  const CliArgsResult._();
}

/// `--help`/`-h` was passed: print usage and exit 0.
final class CliArgsHelp extends CliArgsResult {
  /// Creates a [CliArgsHelp].
  const CliArgsHelp() : super._();
}

/// `--version` was passed: print the version and exit 0.
final class CliArgsVersion extends CliArgsResult {
  /// Creates a [CliArgsVersion].
  const CliArgsVersion() : super._();
}

/// A parsed run configuration (interactive or headless).
final class CliArgs extends CliArgsResult {
  /// Creates a [CliArgs].
  const CliArgs({
    this.model,
    this.provider = 'openai-completions',
    this.baseUrl,
    this.systemPrompt,
    this.systemPromptFile,
    this.visionModel,
    this.visionBaseUrl,
    this.transcribeModel,
    this.transcribeBaseUrl,
    this.plugins = const [],
    this.promptTemplateDirs = const [],
    this.mode,
    this.cwd,
    this.sessionRoot,
    this.prompt,
    this.positionals = const [],
  }) : super._();

  /// `--model <id>`.
  final String? model;

  /// `--provider <kind>` (default: openai-completions, via OpenRouter).
  final String provider;

  /// `--base-url <url>`.
  final String? baseUrl;

  /// `--system-prompt <text>`: a per-invocation system prompt override, used
  /// verbatim. Wins over the config `prompts:` section and the built-in mode
  /// prompts. Mutually exclusive with [systemPromptFile].
  final String? systemPrompt;

  /// `--system-prompt-file <path>`: a per-invocation system prompt override
  /// read from a Markdown file. Mutually exclusive with [systemPrompt].
  final String? systemPromptFile;

  /// `--vision-model <id>`.
  final String? visionModel;

  /// `--vision-base-url <url>`.
  final String? visionBaseUrl;

  /// `--transcribe-model <id>`.
  final String? transcribeModel;

  /// `--transcribe-base-url <url>`.
  final String? transcribeBaseUrl;

  /// `--plugin <name>` (repeatable).
  final List<String> plugins;

  /// `--prompt-template-dir <path>` (repeatable).
  final List<String> promptTemplateDirs;

  /// `--mode <name>` (code | architect | review).
  final String? mode;

  /// `--cwd <dir>`.
  final String? cwd;

  /// `--session-root <dir>`.
  final String? sessionRoot;

  /// The `-p`/`--prompt` headless prompt, used verbatim (no file
  /// resolution). Mutually exclusive with [positionals].
  final String? prompt;

  /// Positional arguments: the headless prompt source. Joined with spaces,
  /// or resolved as a file by `resolveHeadlessPrompt` when the first one
  /// names an existing file. Empty for interactive REPL mode.
  final List<String> positionals;

  /// Whether this invocation runs a single headless prompt instead of the
  /// interactive REPL.
  bool get isHeadless => prompt != null || positionals.isNotEmpty;
}

/// Parses the `fah` argument list.
///
/// Throws [CliArgsException] on unknown flags, missing flag values, an
/// unknown provider, `--system-prompt` combined with `--system-prompt-file`,
/// or `-p`/`--prompt` combined with positional arguments.
CliArgsResult parseCliArgs(List<String> args) {
  String? model;
  var provider = 'openai-completions';
  String? baseUrl;
  String? systemPrompt;
  String? systemPromptFile;
  String? visionModel;
  String? visionBaseUrl;
  String? transcribeModel;
  String? transcribeBaseUrl;
  final plugins = <String>[];
  final promptTemplateDirs = <String>[];
  String? mode;
  String? cwd;
  String? sessionRoot;
  String? prompt;
  final positionals = <String>[];

  String valueFor(int index, String flag) {
    if (index + 1 >= args.length) {
      throw CliArgsException('$flag requires a value');
    }
    return args[index + 1];
  }

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--help' || '-h':
        return const CliArgsHelp();
      case '--version':
        return const CliArgsVersion();
      case '--model':
        model = valueFor(i, '--model');
        i++;
      case '--provider':
        provider = valueFor(i, '--provider');
        i++;
      case '--base-url':
        baseUrl = valueFor(i, '--base-url');
        i++;
      case '--system-prompt':
        systemPrompt = valueFor(i, '--system-prompt');
        i++;
      case '--system-prompt-file':
        systemPromptFile = valueFor(i, '--system-prompt-file');
        i++;
      case '--vision-model':
        visionModel = valueFor(i, '--vision-model');
        i++;
      case '--vision-base-url':
        visionBaseUrl = valueFor(i, '--vision-base-url');
        i++;
      case '--transcribe-model':
        transcribeModel = valueFor(i, '--transcribe-model');
        i++;
      case '--transcribe-base-url':
        transcribeBaseUrl = valueFor(i, '--transcribe-base-url');
        i++;
      case '--plugin':
        plugins.add(valueFor(i, '--plugin'));
        i++;
      case '--prompt-template-dir':
        promptTemplateDirs.add(valueFor(i, '--prompt-template-dir'));
        i++;
      case '--mode':
        mode = valueFor(i, '--mode');
        i++;
      case '--cwd':
        cwd = valueFor(i, '--cwd');
        i++;
      case '--session-root':
        sessionRoot = valueFor(i, '--session-root');
        i++;
      case '-p' || '--prompt':
        prompt = valueFor(i, '--prompt');
        i++;
      default:
        // Anything not flag-like is a positional prompt fragment; unknown
        // `-...` arguments stay an error.
        if (args[i].startsWith('-')) {
          throw CliArgsException('unknown argument: ${args[i]}');
        }
        positionals.add(args[i]);
    }
  }
  if (!cliProviderKinds.contains(provider)) {
    throw CliArgsException('unknown provider: $provider');
  }
  if (systemPrompt != null && systemPromptFile != null) {
    throw CliArgsException(
      'cannot combine --system-prompt and --system-prompt-file',
    );
  }
  if (prompt != null && positionals.isNotEmpty) {
    throw CliArgsException(
      'cannot combine -p/--prompt with positional prompt arguments',
    );
  }
  return CliArgs(
    model: model,
    provider: provider,
    baseUrl: baseUrl,
    systemPrompt: systemPrompt,
    systemPromptFile: systemPromptFile,
    visionModel: visionModel,
    visionBaseUrl: visionBaseUrl,
    transcribeModel: transcribeModel,
    transcribeBaseUrl: transcribeBaseUrl,
    plugins: plugins,
    promptTemplateDirs: promptTemplateDirs,
    mode: mode,
    cwd: cwd,
    sessionRoot: sessionRoot,
    prompt: prompt,
    positionals: positionals,
  );
}
