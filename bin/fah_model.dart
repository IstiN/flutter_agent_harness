part of 'fah.dart';

/// The adapter KINDS whose stream path does not read the model-carried
/// `thinkingLevel` (issue #734 E1 boot note). gh-1426 wired the
/// openai-completions family (openai-completions/minimax/zai/aiin),
/// google, and anthropic; dial/copilot/chatgpt-codex keep their own
/// options and still carry-but-never-send a declared level.
const _thinkingUnwiredAdapterKinds = {'dial', 'copilot', 'chatgpt-codex'};

Model _buildModel(CliArgs args, {List<String>? input, String? thinkingLevel}) {
  return buildCliDefaultModel(
    args.provider,
    modelId: args.model,
    baseUrl: args.baseUrl,
    input: input,
    thinkingLevel: thinkingLevel,
  );
}

/// Built-in plugins available via `--plugin <name>` or `.fah/packages.yaml`.
/// [hubPlugin] is the process's single hub client instance — the same one
/// the settings-hub DAP / Hub flow reads its snapshot through. When
/// [fabricDeliversMail] is set the hub-backed messaging repository owns
/// hub mail delivery and the plugin host registers no separate inbox.
FahPlugin? _builtInPlugin(
  String name,
  HubPlugin hubPlugin, {
  required bool fabricDeliversMail,
  Map<String, String>? dapEnvironment,
}) {
  return switch (name) {
    'hub' => HubPluginHost(
      hubPlugin,
      environment: dapEnvironment,
      fabricDeliversMail: fabricDeliversMail,
    ),
    'inspect_image' => const InspectImagePlugin(),
    'transcribe_audio' => const TranscribeAudioPlugin(),
    _ => null,
  };
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

/// Resolves the enabled plugins and their `.fah/packages.yaml` config
/// (the loader lives in `lib/src/plugins/packages_config.dart`). A parse
/// failure is a hard startup error. With the hub plugin enabled AND DAP
/// unlocked (`DAP_MASTER_SECRET` — the plugin's own kill switch) AND the
/// `fabric.hub` kill switch not off (issue #304 E6), the returned
/// [HubFabricRepository] becomes the messaging fabric's hub layer
/// (issue #27) and the plugin host skips its separate inbox.
Future<
  ({
    List<FahPlugin> plugins,
    Map<String, dynamic> config,
    HubFabricRepository? hubFabric,
  })
>
_resolvePlugins(
  CliArgs args,
  ExecutionEnv env,
  HubPlugin hubPlugin,
  Map<String, String> dapEnvironment, {
  bool fabricHubAllowed = true,
}) async {
  final Map<String, dynamic> config;
  try {
    config = await loadPackagesConfig(env);
  } on ConfigException catch (error) {
    _fail(error.message);
  }
  final enabled = resolveEnabledPlugins(args.plugins, config);
  final hubEnabled = hubFabricWired(
    hubPluginEnabled: enabled.contains('hub'),
    dapUnlocked: (dapEnvironment[envMasterSecret] ?? '').isNotEmpty,
    fabricHubAllowed: fabricHubAllowed,
  );
  final hubFabric = hubEnabled ? HubFabricRepository(hubPlugin) : null;
  final plugins = <FahPlugin>[];
  for (final name in enabled) {
    final plugin = _builtInPlugin(
      name,
      hubPlugin,
      fabricDeliversMail: hubFabric != null,
      dapEnvironment: dapEnvironment,
    );
    if (plugin == null) _fail('unknown plugin: $name');
    plugins.add(plugin);
  }
  return (plugins: plugins, config: config, hubFabric: hubFabric);
}
