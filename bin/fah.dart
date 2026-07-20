/// The `fah` executable: a terminal coding agent on top of
/// `flutter_agent_harness`.
///
/// Usage:
///
/// ```sh
/// dart run bin/fah.dart [--model <id>] [--provider <kind>] [--base-url <url>]
///                       [--cwd <dir>] [--session-root <dir>]
/// dart run bin/fah.dart [options] "summarize the changelog"   # headless
/// dart run bin/fah.dart [options] notes.md "summarize this"   # file prompt
/// ```
///
/// With no prompt arguments the CLI starts an interactive REPL; with `-p`/
/// `--prompt` or positional arguments it runs a single headless prompt and
/// exits (response on stdout, diagnostics on stderr).
///
/// API keys come from the environment: `OPENROUTER_API_KEY` (fallback
/// `OPENAI_API_KEY`) for the default `openai-completions` provider,
/// `ANTHROPIC_API_KEY` for `anthropic`, `GOOGLE_API_KEY` for `google`.
///
/// This is one of the two places `dart:io` is allowed (the other is
/// `lib/io.dart`); everything it drives is pure Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:yaml/yaml.dart' as yaml;

const _version = '0.1.0';

const _usage = '''
fah — flutter_agent_harness CLI agent

Usage: dart run bin/fah.dart [options] [prompt ...]
       dart run bin/fah.dart [options] -p "<prompt>"

Headless mode:
  With a prompt (positional arguments joined with spaces, or -p/--prompt)
  the CLI runs a single non-interactive prompt and exits: the response
  streams to stdout, tool indicators and notices go to stderr (stdout stays
  pipeable), nothing is ever prompted interactively, and the session
  persists like a normal REPL run. Exit codes: 0 ok, 1 provider error,
  130 aborted (Ctrl-C).
  A first positional naming an EXISTING file is used as the prompt source:
  text files (.md, .markdown, .txt) are inlined as the prompt; any other
  (binary) file is attached as a path reference for the agent's tools —
  with any trailing text appended as the instruction. A path that does not
  exist is treated as plain prompt text (a sentence may contain slashes).

Examples:
  dart run bin/fah.dart "summarize the changelog"
  dart run bin/fah.dart -p "fix the typos in README.md"
  dart run bin/fah.dart CHANGELOG.md "summarize this"
  dart run bin/fah.dart screenshot.png "describe it"

Options:
  -p, --prompt <text>       Run a single headless prompt and exit
  --model <id>              Model id (default per provider, see below)
  --provider <kind>         openai-completions | anthropic | google
                            (default: openai-completions, via OpenRouter)
  --base-url <url>          Override the provider API base URL
  --vision-model <id>       Enable inspect_image tool using this vision model
                            (e.g. gpt-4o, openai/gpt-4o)
  --vision-base-url <url>   Override the vision provider base URL
  --transcribe-model <id>   Enable transcribe_audio tool using this
                            transcription model (default: whisper-1)
  --transcribe-base-url <url>  Override the transcription endpoint base URL
  --plugin <name>          Enable a built-in plugin (repeatable). Built-ins:
                            inspect_image, transcribe_audio
  --prompt-template-dir <path>  Add a prompt template directory (repeatable)
  --mode <name>           Initial mode: code | architect | review
  --cwd <dir>               Working directory (default: current directory)
  --session-root <dir>      Session storage root (default: ~/.fah/sessions)
  --help, -h                Show this help
  --version                 Print the version

Environment:
  OPENROUTER_API_KEY        API key for openai-completions (or OPENAI_API_KEY)
  ANTHROPIC_API_KEY         API key for --provider anthropic
  GOOGLE_API_KEY            API key for --provider google
  VISION_API_KEY            API key for --vision-model (defaults to main key)
  TRANSCRIBE_API_KEY        API key for --transcribe-model (defaults to main key)

Configuration:
  .fah/packages.yaml        Plugin configuration (see docs).
  .fah/rules.yaml           Project TTSR stream rules (see docs).
  ~/.fah/config.yaml        Preferences; an optional `roles:` section pins
                            model roles (default/smol/slow/plan) to ordered
                            fallback chains, with `modelOverrides:` for
                            path-scoped chains. Key rotation stacks
                            _2.._N suffixes (OPENROUTER_API_KEY_2, ...).
                            An optional `ttsr:` section configures TTSR
                            stream rules (abort/inject/retry on regex
                            matches in the streaming output).

Defaults per provider:
  openai-completions    anthropic/claude-sonnet-4 @ https://openrouter.ai/api/v1
  anthropic             claude-sonnet-4-5 @ https://api.anthropic.com
  google                gemini-2.5-pro @ https://generativelanguage.googleapis.com/v1beta
''';

Never _fail(String message) {
  stderr.writeln('fah: $message');
  stderr.writeln('Run with --help for usage.');
  exit(64);
}

Never _exitWithUsage() {
  stdout.write(_usage);
  exit(0);
}

Never _exitWithVersion() {
  stdout.writeln('fah $_version');
  exit(0);
}

Model _buildModel(CliArgs args) {
  return buildCliDefaultModel(
    args.provider,
    modelId: args.model,
    baseUrl: args.baseUrl,
  );
}

String? _optionalApiKey(String provider) {
  final env = Platform.environment;
  return switch (provider) {
    'anthropic' => env['ANTHROPIC_API_KEY'],
    'google' => env['GOOGLE_API_KEY'],
    'vision' => env['VISION_API_KEY'],
    'transcribe' => env['TRANSCRIBE_API_KEY'],
    _ => env['OPENROUTER_API_KEY'] ?? env['OPENAI_API_KEY'],
  };
}

String _resolveApiKey(String provider, {String? fallback}) {
  final key = _optionalApiKey(provider) ?? fallback;
  if (key == null || key.isEmpty) {
    final name = switch (provider) {
      'anthropic' => 'ANTHROPIC_API_KEY',
      'google' => 'GOOGLE_API_KEY',
      'vision' => 'VISION_API_KEY',
      'transcribe' => 'TRANSCRIBE_API_KEY',
      _ => 'OPENROUTER_API_KEY',
    };
    _fail('missing API key: set $name in the environment');
  }
  return key;
}

/// Collects the secrets snapshot for the model-roles resolver: every
/// provider catalog env name plus its rotation stack (`NAME`, `NAME_2`,
/// `NAME_3`, ...), plus any base name referenced by an explicit
/// `apiKeyName` in the roles config.
Map<String, String> _collectRoleSecrets(ModelRolesConfig rolesConfig) {
  final baseNames = <String>{
    for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
    for (final chain in rolesConfig.roles.values)
      for (final ref in chain)
        if (ref.apiKeyName != null) ref.apiKeyName!,
    for (final override in rolesConfig.pathOverrides)
      for (final chain in override.roles.values)
        for (final ref in chain)
          if (ref.apiKeyName != null) ref.apiKeyName!,
  };
  final secrets = <String, String>{};
  final env = Platform.environment;
  for (final base in baseNames) {
    final suffix = RegExp('^${RegExp.escape(base)}_\\d+\$');
    for (final entry in env.entries) {
      if (entry.key == base || suffix.hasMatch(entry.key)) {
        if (entry.value.isNotEmpty) secrets[entry.key] = entry.value;
      }
    }
  }
  return secrets;
}

/// Built-in plugins available via `--plugin <name>` or `.fah/packages.yaml`.
FahPlugin? _builtInPlugin(String name) {
  return switch (name) {
    'inspect_image' => const InspectImagePlugin(),
    'transcribe_audio' => const TranscribeAudioPlugin(),
    _ => null,
  };
}

/// Loads plugin configuration from `.fah/packages.yaml` if it exists.
/// Returns a map of plugin name -> config.
Map<String, dynamic> _loadPackagesConfig(String cwd) {
  final file = File('$cwd/.fah/packages.yaml');
  if (!file.existsSync()) return const {};
  try {
    final doc = yaml.loadYaml(file.readAsStringSync());
    if (doc is! Map) return const {};
    return Map<String, dynamic>.fromEntries(
      doc.entries.whereType<MapEntry<String, dynamic>>(),
    );
  } on Object catch (error) {
    _fail('failed to parse .fah/packages.yaml: $error');
  }
}

/// Loads project-level TTSR rules from `.fah/rules.yaml` when it exists
/// (omp's project rule locations, reduced: one file, rules only — TTSR
/// settings stay in `~/.fah/config.yaml`). Returns null when absent.
List<TtsrRule>? _loadProjectTtsrRules(String cwd) {
  final file = File('$cwd/.fah/rules.yaml');
  if (!file.existsSync()) return null;
  try {
    final doc = yaml.loadYaml(file.readAsStringSync());
    return TtsrConfig.rulesFromYaml(doc, sourcePath: '.fah/rules.yaml');
  } on ConfigException catch (error) {
    _fail('invalid .fah/rules.yaml: ${error.message}');
  } on Object catch (error) {
    _fail('failed to parse .fah/rules.yaml: $error');
  }
}

/// Merges user-level TTSR config (`~/.fah/config.yaml`) with project rules:
/// project rules register first and win name clashes (the manager dedupes
/// by name, first wins). Settings come from the user config.
TtsrConfig? _resolveTtsr(CliConfig saved, String cwd) {
  final projectRules = _loadProjectTtsrRules(cwd) ?? const <TtsrRule>[];
  final user = saved.ttsr;
  if (projectRules.isEmpty) return user;
  return TtsrConfig(
    settings: user?.settings ?? TtsrSettings.defaultSettings,
    rules: [...projectRules, ...user?.rules ?? const <TtsrRule>[]],
  );
}

({List<FahPlugin> plugins, Map<String, dynamic> config}) _resolvePlugins(
  CliArgs args,
  String cwd,
) {
  final config = _loadPackagesConfig(cwd);
  final enabled = <String>{...args.plugins, ...config.keys};
  final plugins = <FahPlugin>[];
  for (final name in enabled) {
    final plugin = _builtInPlugin(name);
    if (plugin == null) _fail('unknown plugin: $name');
    plugins.add(plugin);
  }
  return (plugins: plugins, config: config);
}

String _defaultSessionRoot() {
  final home = _homeDir();
  return '$home/.fah/sessions';
}

String _homeDir() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    _fail('cannot resolve home directory; pass --session-root');
  }
  return home;
}

/// [CliIO] bound to the real terminal: stdin lines, stdout writes, and a
/// broadcast interrupt channel fed by the SIGINT handler in `main`.
///
/// In [headless] mode diagnostics ([writeln]) go to stderr so stdout carries
/// only the assistant text, input is never read, and the CLI is never
/// interactive (approval/ask prompts resolve non-interactively).
final class _TerminalCliIO implements CliIO {
  _TerminalCliIO({this.headless = false});

  /// Whether the CLI runs a single headless prompt.
  final bool headless;

  final _interrupts = StreamController<void>.broadcast();

  void fireInterrupt() => _interrupts.add(null);

  @override
  Stream<String> get lines => headless
      ? const Stream<String>.empty()
      : stdin.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => stdout.write(text);

  @override
  void writeln(String text) =>
      headless ? stderr.writeln(text) : stdout.writeln(text);

  /// Piped input (no terminal) means no human can answer approval prompts:
  /// the CLI then denies prompt-policy tool calls with a reason. Headless
  /// mode is never interactive, terminal or not.
  @override
  bool get isInteractive => !headless && stdin.hasTerminal;
}

Future<void> main(List<String> args) async {
  late final CliArgs parsed;
  try {
    parsed = switch (parseCliArgs(args)) {
      CliArgsHelp() => _exitWithUsage(),
      CliArgsVersion() => _exitWithVersion(),
      final CliArgs cliArgs => cliArgs,
    };
  } on CliArgsException catch (error) {
    _fail(error.message);
  }

  // Headless prompt resolution: -p verbatim; a first positional naming an
  // existing file inlines text files (.md/.markdown/.txt) or attaches other
  // files as a path reference; anything else is plain prompt text.
  final headlessPrompt = resolveHeadlessPrompt(
    prompt: parsed.prompt,
    positionals: parsed.positionals,
  );

  final home = homeDirectory();
  if (home == null || home.isEmpty) {
    _fail('cannot resolve home directory; pass --session-root');
  }
  late final CliConfig saved;
  try {
    saved = loadCliConfig(home);
  } on ConfigException catch (error) {
    _fail('invalid ~/.fah/config.yaml: ${error.message}');
  }

  final provider = parsed.provider;
  final modelId = parsed.model ?? saved.modelId;
  final baseUrl = parsed.baseUrl ?? saved.baseUrl;
  final mode = parsed.mode ?? saved.mode;

  final effective = CliArgs(
    model: modelId,
    provider: provider,
    baseUrl: baseUrl,
    visionModel: parsed.visionModel,
    visionBaseUrl: parsed.visionBaseUrl,
    transcribeModel: parsed.transcribeModel,
    transcribeBaseUrl: parsed.transcribeBaseUrl,
    plugins: parsed.plugins,
    promptTemplateDirs: parsed.promptTemplateDirs,
    mode: mode,
    cwd: parsed.cwd,
    sessionRoot: parsed.sessionRoot,
  );

  final model = _buildModel(effective);
  final cwd = effective.cwd ?? Directory.current.path;
  final sessionRoot = effective.sessionRoot ?? _defaultSessionRoot();

  // Model roles (optional): when ~/.fah/config.yaml declares a `roles:`
  // section, runs resolve through the default role's fallback chain with
  // key rotation. The legacy single provider/model path stays the fallback
  // when no default role resolves.
  final rolesConfig = saved.modelRoles;
  final roleSecrets = rolesConfig == null
      ? const <String, String>{}
      : _collectRoleSecrets(rolesConfig);
  ModelRolesResolver? rolesResolver;
  var defaultRoleResolved = false;
  if (rolesConfig != null) {
    rolesResolver = ModelRolesResolver(
      config: rolesConfig,
      secrets: roleSecrets,
      cwd: cwd,
      homeDir: home,
    );
    try {
      defaultRoleResolved = rolesResolver.resolveRole(defaultModelRole) != null;
    } on ConfigException catch (error) {
      _fail('invalid model roles config: ${error.message}');
    }
  }
  final apiKey = defaultRoleResolved
      ? (_optionalApiKey(provider) ?? '')
      : _resolveApiKey(provider);

  // Redact the API keys this CLI knows about from tool results and the
  // provider context, so they cannot leak into the LLM conversation or the
  // session files. The spawned shell already inherits the process
  // environment, so no env injection is needed here.
  final redactor = SecretRedactor();
  for (final name in const [
    'OPENROUTER_API_KEY',
    'OPENAI_API_KEY',
    'ANTHROPIC_API_KEY',
    'GOOGLE_API_KEY',
    'VISION_API_KEY',
    'TRANSCRIBE_API_KEY',
    'BRAVE_API_KEY',
    'TAVILY_API_KEY',
  ]) {
    final value = Platform.environment[name];
    if (value != null) redactor.register(name, value);
  }
  // Rotation stacks collected for the roles resolver are redacted too.
  for (final entry in roleSecrets.entries) {
    redactor.register(entry.key, entry.value);
  }

  // Web search works out of the box via keyless DuckDuckGo; keyed providers
  // (Brave, Tavily) join the chain when their API key is in the environment.
  final webSearchSecrets = InMemorySecretsStore({
    for (final name in const ['BRAVE_API_KEY', 'TAVILY_API_KEY'])
      if (Platform.environment[name] case final value? when value.isNotEmpty)
        name: value,
  });

  late final Future<void> Function() persistConfig;

  InspectImageConfig? visionConfig;
  if (effective.visionModel != null) {
    visionConfig = InspectImageConfig(
      modelId: effective.visionModel!,
      apiKey: _resolveApiKey('vision', fallback: apiKey),
      baseUrl: effective.visionBaseUrl,
    );
  }

  TranscribeAudioConfig? transcribeConfig;
  if (effective.transcribeModel != null) {
    transcribeConfig = TranscribeAudioConfig(
      modelId: effective.transcribeModel!,
      apiKey: _resolveApiKey('transcribe', fallback: apiKey),
      baseUrl: effective.transcribeBaseUrl,
    );
  }

  final resolved = _resolvePlugins(effective, cwd);

  if (!const {'code', 'architect', 'review'}.contains(effective.mode)) {
    _fail('unknown mode: ${effective.mode}');
  }

  final promptTemplateDirs = <String>[
    '$cwd/.fah/prompts',
    '$home/.fah/prompts',
    ...effective.promptTemplateDirs,
  ];

  final io = _TerminalCliIO(headless: headlessPrompt != null);
  final cli = AgentCli(
    config: AgentCliConfig(
      model: model,
      apiKey: apiKey,
      providerKind: provider,
      env: LocalExecutionEnv(cwd: cwd),
      sessionRoot: sessionRoot,
      visionConfig: visionConfig,
      transcribeConfig: transcribeConfig,
      webSearchConfig: WebSearchConfig(secrets: webSearchSecrets),
      sqliteEngine: const Sqlite3Engine(),
      // The lsp tool: the io-side process transport spawns `dart
      // language-server` (and any server from .fah/lsp.json); the host pid
      // lets servers exit when this process dies.
      lspConfig: LspToolConfig(
        transportFactory: ioLspTransportFactory,
        processId: pid,
      ),
      plugins: resolved.plugins,
      pluginConfig: resolved.config,
      promptTemplateDirs: promptTemplateDirs,
      initialMode: effective.mode!,
      approvalMode:
          approvalModeFromLabel(saved.approvalMode) ?? ApprovalMode.yolo,
      alwaysAllowTools: saved.allowedTools.toSet(),
      modelRolesResolver: rolesResolver,
      // TTSR stream rules: user config (~/.fah/config.yaml `ttsr:`) merged
      // with project rules (.fah/rules.yaml), project first.
      ttsr: _resolveTtsr(saved, cwd),
      onModelChanged: (_) async => persistConfig(),
      onModeChanged: (_) async => persistConfig(),
      onApprovalChanged: () async => persistConfig(),
    ),
    io: io,
  );
  if (!redactor.isEmpty) attachSecretRedactor(cli.agent, redactor);

  persistConfig = () async {
    await saveCliConfig(
      home,
      CliConfig(
        providerKind: provider,
        modelId: cli.agent.state.model.id,
        baseUrl: cli.agent.state.model.baseUrl,
        mode: cli.currentMode.name,
        approvalMode: cli.approval.mode.label,
        allowedTools: cli.approval.alwaysAllowedTools,
        // Roles are static per session except for a `/model` switch, which
        // re-pins the default chain on the resolver.
        modelRoles: rolesResolver?.config ?? saved.modelRoles,
        // TTSR rules are static per session; keep the loaded config so
        // saving doesn't drop the section.
        ttsr: saved.ttsr,
      ),
    );
  };

  await persistConfig();

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (cli.isBusy) {
      io.fireInterrupt();
    } else {
      // Idle Ctrl-C exits 130; the cosmetic newline stays off stdout in
      // headless mode so a pipe never sees it.
      if (headlessPrompt == null) stdout.writeln();
      exit(130);
    }
  });

  if (headlessPrompt != null) {
    final int code;
    try {
      code = await cli.runHeadless(headlessPrompt);
    } finally {
      await sigintSub.cancel();
    }
    exit(code);
  }

  try {
    await cli.run();
  } finally {
    await sigintSub.cancel();
  }
}
