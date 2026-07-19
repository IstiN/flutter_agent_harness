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
  --plugin <name>          Enable a built-in plugin (repeatable). Built-ins:
                            inspect_image
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

Configuration:
  .fah/packages.yaml        Plugin configuration (see docs).

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
    plugins: plugins,
    promptTemplateDirs: promptTemplateDirs,
    mode: mode,
    cwd: cwd,
    sessionRoot: sessionRoot,
  );
}

Model _buildModel(_Args args) {
  return switch (args.provider) {
    'anthropic' => Model(
      id: args.model ?? 'claude-sonnet-4-5',
      name: args.model ?? 'claude-sonnet-4-5',
      api: 'anthropic-messages',
      provider: 'anthropic',
      baseUrl: args.baseUrl ?? 'https://api.anthropic.com',
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 8192,
    ),
    'google' => Model(
      id: args.model ?? 'gemini-2.5-pro',
      name: args.model ?? 'gemini-2.5-pro',
      api: 'google-generative-ai',
      provider: 'google',
      baseUrl:
          args.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta',
      reasoning: true,
      contextWindow: 1000000,
      maxTokens: 8192,
    ),
    _ => Model(
      id: args.model ?? 'anthropic/claude-sonnet-4',
      name: args.model ?? 'anthropic/claude-sonnet-4',
      api: 'openai-completions',
      provider: args.baseUrl == null ? 'openrouter' : 'openai',
      baseUrl: args.baseUrl ?? 'https://openrouter.ai/api/v1',
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 8192,
    ),
  };
}

String _resolveApiKey(String provider, {String? fallback}) {
  final env = Platform.environment;
  final key = switch (provider) {
    'anthropic' => env['ANTHROPIC_API_KEY'],
    'google' => env['GOOGLE_API_KEY'],
    'vision' => env['VISION_API_KEY'] ?? fallback,
    _ => env['OPENROUTER_API_KEY'] ?? env['OPENAI_API_KEY'],
  };
  if (key == null || key.isEmpty) {
    final name = switch (provider) {
      'anthropic' => 'ANTHROPIC_API_KEY',
      'google' => 'GOOGLE_API_KEY',
      'vision' => 'VISION_API_KEY',
      _ => 'OPENROUTER_API_KEY',
    };
    _fail('missing API key: set $name in the environment');
  }
  return key;
}

/// Built-in plugins available via `--plugin <name>` or `.fah/packages.yaml`.
FahPlugin? _builtInPlugin(String name) {
  return switch (name) {
    'inspect_image' => const InspectImagePlugin(),
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
  final saved = loadCliConfig(home);

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
    plugins: parsed.plugins,
    promptTemplateDirs: parsed.promptTemplateDirs,
    mode: mode,
    cwd: parsed.cwd,
    sessionRoot: parsed.sessionRoot,
  );

  final model = _buildModel(effective);
  final apiKey = _resolveApiKey(provider);
  final cwd = effective.cwd ?? Directory.current.path;
  final sessionRoot = effective.sessionRoot ?? _defaultSessionRoot();

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
    'BRAVE_API_KEY',
    'TAVILY_API_KEY',
  ]) {
    final value = Platform.environment[name];
    if (value != null) redactor.register(name, value);
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
      webSearchConfig: WebSearchConfig(secrets: webSearchSecrets),
      plugins: resolved.plugins,
      pluginConfig: resolved.config,
      promptTemplateDirs: promptTemplateDirs,
      initialMode: effective.mode!,
      approvalMode:
          approvalModeFromLabel(saved.approvalMode) ?? ApprovalMode.yolo,
      alwaysAllowTools: saved.allowedTools.toSet(),
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
