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

/// The provider kinds accepted by `--provider`. Static — the set of every
/// headless-capable catalog kind; a build filtered through the
/// `FA_PROVIDERS` dart-define rejects the filtered kinds at resolution
/// time (buildCliDefaultModel resolves through the filtered
/// [catalogProvider]).
const cliProviderKinds = {
  'openai-completions',
  'anthropic',
  'google',
  'dial',
  'minimax',
  'zai',
  'copilot',
};

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
    this.providerExplicit = false,
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
    this.session,
    this.prompt,
    this.cubeName,
    this.cubeConfigPath,
    this.trajectory,
    this.positionals = const [],
  }) : super._();

  /// `--model <id>`.
  final String? model;

  /// `--provider <kind>` (default: openai-completions, via OpenRouter).
  final String provider;

  /// Whether `--provider` was passed explicitly. When false, the executable
  /// prefers the saved `provider:` from `~/.fah/config.yaml` (the persisted
  /// `/provider` switch) over the openai-completions default.
  final bool providerExplicit;

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

  /// `--session <name>`.
  ///
  /// Resume the named session for the current working directory if it exists,
  /// otherwise create a new session with that name. Applies to both the
  /// interactive REPL and headless mode.
  final String? session;

  /// `--cube <name>`: apply the cube sandbox profile
  /// `<cwd>/.fah/cubes/<name>.yaml` for this run. Wins over the `cube:`
  /// config section; `--cube-config` beats it.
  final String? cubeName;

  /// `--cube-config <path>`: apply the cube sandbox profile from an
  /// explicit manifest path (highest cube precedence).
  final String? cubeConfigPath;

  /// The `-p`/`--prompt` headless prompt, used verbatim (no file
  /// resolution). Mutually exclusive with [positionals].
  final String? prompt;

  /// Positional arguments: the headless prompt source. Joined with spaces,
  /// or resolved as a file by `resolveHeadlessPrompt` when the first one
  /// names an existing file. Empty for interactive REPL mode.
  final List<String> positionals;

  /// The `fa trajectory <verb>` subcommand, when the invocation routed to
  /// the trajectory reader instead of a prompt run.
  final TrajectoryCliCommand? trajectory;

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
  // `fa trajectory <verb> [args]` — the trajectory reader subcommand,
  // intercepted before prompt parsing (the verb words are not prompts).
  if (args.isNotEmpty && args.first == 'trajectory') {
    return _parseTrajectoryArgs(args.sublist(1));
  }
  final values = _CliArgValues();
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') return const CliArgsHelp();
    if (arg == '--version') return const CliArgsVersion();
    final flag = _valueFlags[arg];
    if (flag != null) {
      final (canonical, apply) = flag;
      if (i + 1 >= args.length) {
        throw CliArgsException('$canonical requires a value');
      }
      apply(values, args[i + 1]);
      i++;
      continue;
    }
    // Anything not flag-like is a positional prompt fragment; unknown
    // `-...` arguments stay an error.
    if (arg.startsWith('-')) {
      throw CliArgsException('unknown argument: $arg');
    }
    values.positionals.add(arg);
  }
  return values.finish();
}

/// The `fa trajectory` subcommand: a read-only trajectory view over a
/// stored session.
///
/// [positionals] carry the verb's operands: the record number for
/// `inspect` (validated at parse time), then the optional session id; the
/// other verbs take only the optional session id.
final class TrajectoryCliCommand {
  /// Creates a [TrajectoryCliCommand].
  const TrajectoryCliCommand({
    required this.verb,
    this.positionals = const [],
    this.json = false,
    this.at,
  });

  /// One of [trajectoryVerbs].
  final String verb;

  /// The verb's positional operands (record number / session id).
  final List<String> positionals;

  /// `--json`: one compact JSON record per line.
  final bool json;

  /// `--at N` (view only): the snapshot as it stood at record N.
  final int? at;
}

/// The verbs accepted by `fa trajectory`.
const trajectoryVerbs = {'view', 'tail', 'cost', 'inspect'};

/// Parses the `trajectory` subcommand operands (everything after the
/// `trajectory` word). Unknown verbs and flags are usage errors so a typo
/// never becomes a prompt sent to a model.
CliArgsResult _parseTrajectoryArgs(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    return const CliArgsHelp();
  }
  if (args.isEmpty) {
    throw const CliArgsException(
      'usage: fa trajectory <view|tail|cost|inspect> [sessionId] '
      '[--json] [--at N]',
    );
  }
  final verb = args.first;
  if (!trajectoryVerbs.contains(verb)) {
    throw CliArgsException(
      'unknown trajectory verb: $verb '
      '(expected view|tail|cost|inspect)',
    );
  }
  final positionals = <String>[];
  var json = false;
  int? at;
  String? cwd;
  String? sessionRoot;
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--json':
        json = true;
      case '--cwd' || '--session-root':
        if (i + 1 >= args.length) {
          throw CliArgsException('$arg requires a value');
        }
        if (arg == '--cwd') {
          cwd = args[++i];
        } else {
          sessionRoot = args[++i];
        }
      case '--at':
        if (i + 1 >= args.length) {
          throw const CliArgsException('--at requires a record number');
        }
        at = int.tryParse(args[++i]);
        if (at == null) {
          throw const CliArgsException('--at requires a record number');
        }
      default:
        if (arg.startsWith('-')) {
          throw CliArgsException('unknown argument: $arg');
        }
        if (positionals.length >= 2) {
          throw CliArgsException('unexpected argument: $arg');
        }
        positionals.add(arg);
    }
  }
  if (verb == 'inspect') {
    if (positionals.isEmpty) {
      throw const CliArgsException(
        'usage: fa trajectory inspect <recordNumber> [sessionId]',
      );
    }
    if (int.tryParse(positionals.first) == null) {
      throw const CliArgsException(
        'trajectory inspect requires a record number',
      );
    }
  }
  if (at != null && verb != 'view') {
    throw const CliArgsException('--at only applies to fa trajectory view');
  }
  return CliArgs(
    cwd: cwd,
    sessionRoot: sessionRoot,
    trajectory: TrajectoryCliCommand(
      verb: verb,
      positionals: positionals,
      json: json,
      at: at,
    ),
  );
}

/// A value-taking CLI flag: its canonical name (for error messages, so
/// `-p` reports as `--prompt`) and the setter applying it to [_CliArgValues].
typedef _ValueFlag = (String, void Function(_CliArgValues, String));

/// Every flag that consumes the next argument as its value.
const _valueFlags = <String, _ValueFlag>{
  '--model': ('--model', _setModel),
  '--provider': ('--provider', _setProvider),
  '--base-url': ('--base-url', _setBaseUrl),
  '--system-prompt': ('--system-prompt', _setSystemPrompt),
  '--system-prompt-file': ('--system-prompt-file', _setSystemPromptFile),
  '--vision-model': ('--vision-model', _setVisionModel),
  '--vision-base-url': ('--vision-base-url', _setVisionBaseUrl),
  '--transcribe-model': ('--transcribe-model', _setTranscribeModel),
  '--transcribe-base-url': ('--transcribe-base-url', _setTranscribeBaseUrl),
  '--plugin': ('--plugin', _addPlugin),
  '--prompt-template-dir': ('--prompt-template-dir', _addPromptTemplateDir),
  '--mode': ('--mode', _setMode),
  '--cwd': ('--cwd', _setCwd),
  '--session-root': ('--session-root', _setSessionRoot),
  '--session': ('--session', _setSession),
  '--cube': ('--cube', _setCubeName),
  '--cube-config': ('--cube-config', _setCubeConfigPath),
  '-p': ('--prompt', _setPrompt),
  '--prompt': ('--prompt', _setPrompt),
};

void _setModel(_CliArgValues v, String value) => v.model = value;
void _setProvider(_CliArgValues v, String value) {
  v.provider = value;
  v.providerExplicit = true;
}

void _setBaseUrl(_CliArgValues v, String value) => v.baseUrl = value;
void _setSystemPrompt(_CliArgValues v, String value) => v.systemPrompt = value;
void _setSystemPromptFile(_CliArgValues v, String value) =>
    v.systemPromptFile = value;
void _setVisionModel(_CliArgValues v, String value) => v.visionModel = value;
void _setVisionBaseUrl(_CliArgValues v, String value) =>
    v.visionBaseUrl = value;
void _setTranscribeModel(_CliArgValues v, String value) =>
    v.transcribeModel = value;
void _setTranscribeBaseUrl(_CliArgValues v, String value) =>
    v.transcribeBaseUrl = value;
void _addPlugin(_CliArgValues v, String value) => v.plugins.add(value);
void _addPromptTemplateDir(_CliArgValues v, String value) =>
    v.promptTemplateDirs.add(value);
void _setMode(_CliArgValues v, String value) => v.mode = value;
void _setCwd(_CliArgValues v, String value) => v.cwd = value;
void _setSessionRoot(_CliArgValues v, String value) => v.sessionRoot = value;
void _setSession(_CliArgValues v, String value) => v.session = value;
void _setCubeName(_CliArgValues v, String value) => v.cubeName = value;
void _setCubeConfigPath(_CliArgValues v, String value) =>
    v.cubeConfigPath = value;
void _setPrompt(_CliArgValues v, String value) => v.prompt = value;

/// Accumulates flag values while [parseCliArgs] walks the argument list,
/// then validates the combinations and builds the [CliArgs].
final class _CliArgValues {
  String? model;
  String provider = 'openai-completions';
  bool providerExplicit = false;
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
  String? session;
  String? cubeName;
  String? cubeConfigPath;
  String? prompt;
  final positionals = <String>[];

  /// Validates flag combinations and builds the resulting [CliArgs].
  CliArgs finish() {
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
      providerExplicit: providerExplicit,
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
      session: session,
      cubeName: cubeName,
      cubeConfigPath: cubeConfigPath,
      prompt: prompt,
      positionals: positionals,
    );
  }
}
