/// The `fah` executable: a terminal coding agent on top of
/// `flutter_agent_harness`.
///
/// Usage:
///
/// ```sh
/// dart run bin/fah.dart [--model <id>] [--provider <kind>] [--base-url <url>]
///                       [--cwd <dir>] [--session-root <dir>]
/// ```
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

Usage: dart run bin/fah.dart [options]

Options:
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
  ~/.fah/config.yaml        Preferences; an optional `roles:` section pins
                            model roles (default/smol/slow/plan) to ordered
                            fallback chains, with `modelOverrides:` for
                            path-scoped chains. Key rotation stacks
                            _2.._N suffixes (OPENROUTER_API_KEY_2, ...).

Defaults per provider:
  openai-completions    anthropic/claude-sonnet-4 @ https://openrouter.ai/api/v1
  anthropic             claude-sonnet-4-5 @ https://api.anthropic.com
  google                gemini-2.5-pro @ https://generativelanguage.googleapis.com/v1beta
''';

final class _Args {
  _Args({
    this.model,
    this.provider = 'openai-completions',
    this.baseUrl,
    this.visionModel,
    this.visionBaseUrl,
    this.transcribeModel,
    this.transcribeBaseUrl,
    this.plugins = const [],
    this.promptTemplateDirs = const [],
    this.mode,
    this.cwd,
    this.sessionRoot,
  });

  final String? model;
  final String provider;
  final String? baseUrl;
  final String? visionModel;
  final String? visionBaseUrl;
  final String? transcribeModel;
  final String? transcribeBaseUrl;
  final List<String> plugins;
  final List<String> promptTemplateDirs;
  final String? mode;
  final String? cwd;
  final String? sessionRoot;
}

Never _fail(String message) {
  stderr.writeln('fah: $message');
  stderr.writeln('Run with --help for usage.');
  exit(64);
}

_Args _parseArgs(List<String> args) {
  String? model;
  var provider = 'openai-completions';
  String? baseUrl;
  String? visionModel;
  String? visionBaseUrl;
  String? transcribeModel;
  String? transcribeBaseUrl;
  final plugins = <String>[];
  final promptTemplateDirs = <String>[];
  String? mode;
  String? cwd;
  String? sessionRoot;

  String valueFor(int index, String flag) {
    if (index + 1 >= args.length) _fail('$flag requires a value');
    return args[index + 1];
  }

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--help' || '-h':
        stdout.write(_usage);
        exit(0);
      case '--version':
        stdout.writeln('fah $_version');
        exit(0);
      case '--model':
        model = valueFor(i, '--model');
        i++;
      case '--provider':
        provider = valueFor(i, '--provider');
        i++;
      case '--base-url':
        baseUrl = valueFor(i, '--base-url');
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
      default:
        _fail('unknown argument: ${args[i]}');
    }
  }
  if (!const {'openai-completions', 'anthropic', 'google'}.contains(provider)) {
    _fail('unknown provider: $provider');
  }
  return _Args(
    model: model,
    provider: provider,
    baseUrl: baseUrl,
    visionModel: visionModel,
    visionBaseUrl: visionBaseUrl,
    transcribeModel: transcribeModel,
    transcribeBaseUrl: transcribeBaseUrl,
    plugins: plugins,
    promptTemplateDirs: promptTemplateDirs,
    mode: mode,
    cwd: cwd,
    sessionRoot: sessionRoot,
  );
}

Model _buildModel(_Args args) {
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

({List<FahPlugin> plugins, Map<String, dynamic> config}) _resolvePlugins(
  _Args args,
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
final class _TerminalCliIO implements CliIO {
  _TerminalCliIO();

  final _interrupts = StreamController<void>.broadcast();

  void fireInterrupt() => _interrupts.add(null);

  @override
  Stream<String> get lines =>
      stdin.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => stdout.write(text);

  @override
  void writeln(String text) => stdout.writeln(text);

  /// Piped input (no terminal) means no human can answer approval prompts:
  /// the CLI then denies prompt-policy tool calls with a reason.
  @override
  bool get isInteractive => stdin.hasTerminal;
}

Future<void> main(List<String> args) async {
  final parsed = _parseArgs(args);
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

  final effective = _Args(
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

  final io = _TerminalCliIO();
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
      plugins: resolved.plugins,
      pluginConfig: resolved.config,
      promptTemplateDirs: promptTemplateDirs,
      initialMode: effective.mode!,
      approvalMode:
          approvalModeFromLabel(saved.approvalMode) ?? ApprovalMode.yolo,
      alwaysAllowTools: saved.allowedTools.toSet(),
      modelRolesResolver: rolesResolver,
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
      ),
    );
  };

  await persistConfig();

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (cli.isBusy) {
      io.fireInterrupt();
    } else {
      stdout.writeln();
      exit(130);
    }
  });

  try {
    await cli.run();
  } finally {
    await sigintSub.cancel();
  }
}
