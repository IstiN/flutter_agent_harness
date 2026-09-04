/// CLI user preferences: last model, provider, base URL, mode, approval
/// policy, prompt overrides, and (optionally) model roles with fallback
/// chains.
///
/// Stored in `~/.fah/config.yaml` so the terminal REPL remembers choices
/// between runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../a2a/a2a_config.dart';
import '../exceptions.dart';
import '../mcp/mcp_config.dart';
import '../model_roles/model_roles.dart';
import '../prompts/prompt_overrides.dart';
import '../cube/config/cube_settings.dart';
import '../providers/provider_common.dart';
import '../skills/skills_access.dart';
import '../memory_config.dart';
import '../redact/redaction_types.dart';
import '../ttsr/ttsr.dart';
import '../tools/availability.dart';
import 'custom_providers.dart';

/// Parses the `providerTimeouts:` section: provider watchdog overrides
/// (see [ProviderTimeoutsOverride]). Strict — a bad schema throws
/// [ConfigException] instead of silently keeping the defaults.
ProviderTimeoutsOverride? _parseProviderTimeouts(Object? node) {
  if (node == null) return null;
  if (node is! YamlMap) {
    throw ConfigException('providerTimeouts must be a map, got: $node');
  }
  Duration? readTimeout(String key) {
    final value = node[key];
    if (value == null) return null;
    if (value is! int || value <= 0) {
      throw ConfigException(
        '"providerTimeouts.$key" must be a positive integer (milliseconds)',
      );
    }
    return Duration(milliseconds: value);
  }

  final connect = readTimeout('connectTimeoutMs');
  final streamIdle = readTimeout('streamIdleTimeoutMs');
  for (final key in node.keys) {
    if (key != 'connectTimeoutMs' && key != 'streamIdleTimeoutMs') {
      throw ConfigException('unknown "providerTimeouts" key: $key');
    }
  }
  if (connect == null && streamIdle == null) return null;
  return ProviderTimeoutsOverride(connect: connect, streamIdle: streamIdle);
}

/// Persisted CLI configuration.
final class CliConfig {
  CliConfig({
    this.providerKind = 'openai-completions',
    this.modelId = 'openai/gpt-4o-mini',
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.mode = 'code',
    this.approvalMode = 'yolo',
    this.allowedTools = const [],
    this.promptOverrides = const {},
    this.modelRoles,
    this.ttsr,
    this.customProviders = const [],
    this.models,
    this.mcp,
    this.a2a,
    this.providerTimeouts,
    this.skillsAccess = SkillsAccess.granted,
    this.skillsDisableShellExecution = false,
    this.memory,
    this.cube,
    this.tools,
    this.redact,
  });

  factory CliConfig.fromYaml(YamlMap map) {
    final skillsSection = _parseSkillsSection(map['skills']);
    return CliConfig(
      providerKind: map['provider'] as String? ?? 'openai-completions',
      modelId: map['model'] as String? ?? 'openai/gpt-4o-mini',
      baseUrl: map['baseUrl'] as String? ?? 'https://openrouter.ai/api/v1',
      mode: map['mode'] as String? ?? 'code',
      approvalMode: map['approvalMode'] as String? ?? 'yolo',
      allowedTools: switch (map['allowedTools']) {
        final YamlList list => [for (final entry in list) '$entry'],
        _ => const [],
      },
      // The prompts section is parsed strictly: unknown prompt names throw
      // [ConfigException] instead of silently doing nothing.
      promptOverrides: parsePromptOverrideMap(map['prompts']),
      // The roles section is parsed strictly: schema errors throw
      // [ConfigException] instead of silently resetting to defaults.
      modelRoles: map['roles'] == null && map['modelOverrides'] == null
          ? null
          : ModelRolesConfig.fromYaml(map),
      // The ttsr section is parsed strictly too (bad rules must surface).
      ttsr: map['ttsr'] == null
          ? null
          : TtsrConfig.fromYaml(map['ttsr'], sourcePath: '~/.fah/config.yaml'),
      // The memory section: storage path overrides; strict like the rest.
      memory: map['memory'] == null
          ? null
          : MemoryConfig.fromYaml(map['memory']),
      cube: map['cube'] == null ? null : CubeSettings.fromYaml(map['cube']),
      // The tools section (capability-gated tool availability); strict too.
      tools: map['tools'] == null ? null : ToolsConfig.fromYaml(map['tools']),
      // The redact section (layered secret redaction); tolerant like
      // RedactionConfig.fromJson — invalid values fall back to defaults.
      redact: map['redact'] == null
          ? null
          : RedactionConfig.fromYaml(map['redact']),
      // Saved custom providers; entry-level errors throw [ConfigException].
      customProviders: switch (map['customProviders']) {
        null => const [],
        final YamlList list => [
          for (final entry in list) CustomProviderEntry.fromYaml(entry),
        ],
        final other => throw ConfigException(
          'customProviders must be a list, got: $other',
        ),
      },
      // The models section (media slot overrides + custom model
      // definitions) is parsed strictly too.
      models: map['models'] == null
          ? null
          : ModelsConfig.fromYaml(map['models']),
      // The mcp section (external tool servers) is parsed strictly too.
      mcp: map['mcp'] == null ? null : McpConfig.fromYaml(map['mcp']),
      // The a2a section (remote Agent2Agent endpoints) is strict too; its
      // `${NAME}` token references resolve against the environment.
      a2a: map['a2a'] == null
          ? null
          : A2aConfig.fromYaml(
              map['a2a'],
              (name) => Platform.environment[name],
            ),
      // The providerTimeouts section (provider watchdog overrides) is strict
      // too.
      providerTimeouts: _parseProviderTimeouts(map['providerTimeouts']),
      // The skills section (third-party skills access consent + shell
      // execution toggle) is strict too.
      skillsAccess:
          skillsSection['skillsAccess'] as SkillsAccess? ??
          SkillsAccess.granted,
      skillsDisableShellExecution:
          skillsSection['skillsDisableShellExecution'] as bool? ?? false,
    );
  }

  /// Parses the `skills:` section: `access` (ask/granted/denied — consent
  /// to read third-party `.claude`/`.github`/`.codex` skill directories)
  /// and `disableShellExecution` (Claude-style `!`cmd`` skill injections).
  static Map<String, Object?> _parseSkillsSection(Object? node) {
    if (node == null) return const {};
    if (node is! YamlMap) {
      throw ConfigException('skills must be a map, got: $node');
    }
    final result = <String, Object?>{};
    for (final key in node.keys) {
      switch (key) {
        case 'access':
          final value = '${node[key]}'.trim();
          if (!{'ask', 'granted', 'denied'}.contains(value)) {
            throw ConfigException(
              'skills.access must be ask, granted or denied, got: $value',
            );
          }
          result['skillsAccess'] = skillsAccessFromLabel(value);
        case 'disableShellExecution':
          final value = node[key];
          if (value is! bool) {
            throw ConfigException(
              'skills.disableShellExecution must be a boolean, got: $value',
            );
          }
          result['skillsDisableShellExecution'] = value;
        default:
          throw ConfigException('unknown "skills" key: $key');
      }
    }
    return result;
  }

  final String providerKind;
  final String modelId;
  final String baseUrl;
  final String mode;

  /// Approval mode label (`always-ask`, `write`, `yolo`, `unattended`);
  /// parsed with
  /// `approvalModeFromLabel` from `lib/src/approval/`.
  final String approvalMode;

  /// Tools the user always-allowed (via `/allow` or an "approve always"
  /// prompt answer), persisted across runs.
  final List<String> allowedTools;

  /// Raw prompt overrides from the `prompts:` yaml section: prompt name →
  /// file path or inline text (validated by [parsePromptOverrideMap]). The
  /// executable resolves it into a `PromptOverrides` via
  /// `resolvePromptOverrides` (file reads live in `lib/io.dart`); an empty
  /// map keeps the built-in prompts.
  final Map<String, String> promptOverrides;

  /// Optional model roles: role → fallback chains, path-scoped overrides,
  /// and the retry policy (`roles:` / `modelOverrides:` / `retry:` yaml
  /// sections). `null` keeps the legacy single provider/model behavior.
  final ModelRolesConfig? modelRoles;

  /// Optional TTSR stream rules (`ttsr:` yaml section). `null` disables
  /// stream-rule monitoring.
  final TtsrConfig? ttsr;

  /// Saved custom providers (`customProviders:` yaml section), shown first
  /// in the `/provider` picker and appended to by the `/provider custom`
  /// wizard. Parsed strictly: a malformed entry throws [ConfigException].
  final List<CustomProviderEntry> customProviders;

  /// Optional models config (`models:` yaml section): per-slot media model
  /// overrides (managed by `/models set`/`/models remove`) and named custom
  /// model definitions (`/model <name>` targets). Parsed strictly: a schema
  /// error throws [ConfigException]. `null` means the section is absent.
  final ModelsConfig? models;

  /// Optional MCP servers config (`mcp:` yaml section). Parsed strictly:
  /// a schema error throws [ConfigException]. `null` disables MCP. Managed
  /// by editing the config file only (no CLI commands yet).
  final McpConfig? mcp;

  /// Optional A2A remote agents config (`a2a:` yaml section). Parsed
  /// strictly; `${NAME}` tokens resolve from the environment.
  final A2aConfig? a2a;

  /// Optional provider watchdog overrides (`providerTimeouts:` yaml
  /// section, `connectTimeoutMs`/`streamIdleTimeoutMs`). Parsed strictly.
  /// `bin/fah.dart` publishes it to [providerTimeoutsOverride] at startup.
  final ProviderTimeoutsOverride? providerTimeouts;

  /// Consent to read third-party skill/agent directories
  /// (`.claude`/`.github`/`.codex` + their `~/` mirrors), from the
  /// `skills.access` yaml key. [SkillsAccess.granted] is the default —
  /// discovery is opt-out so migrating users get their existing skills with
  /// zero setup; `ask` makes the interactive REPL prompt once at startup.
  final SkillsAccess skillsAccess;

  /// When true, Claude-style `!`cmd`` / ```` ```! ```` shell injections in
  /// skill bodies render as a disabled placeholder instead of executing
  /// (the `skills.disableShellExecution` yaml key).
  final bool skillsDisableShellExecution;

  /// Optional `memory:` section — long-term memory storage path overrides
  /// (git-backed project memory). Null = the historical `.fah/memory`
  /// layout.
  final MemoryConfig? memory;

  /// Optional `cube:` section — the default fa_cube sandbox profile applied
  /// at startup when neither `--cube` nor `--cube-config` is passed. Parsed
  /// strictly; `null` means the section is absent.
  final CubeSettings? cube;

  /// Optional `tools:` section — capability-gated tool availability for
  /// the GLOBAL scope. Parsed strictly; `null` means the section is
  /// absent. The project scope reads live via [loadProjectToolsConfig] and
  /// the runtime scope arrives as `--tools`/`FA_TOOLS`; scopes stay
  /// separate for the deepest-wins resolution.
  final ToolsConfig? tools;

  /// Optional `redact:` section — layered secret redaction. `null` means
  /// the section is absent (redaction still runs with default config; the
  /// pipeline assembly happens in the host startup, see
  /// [buildRedactionPipeline]).
  final RedactionConfig? redact;

  String toYaml() {
    final buffer = StringBuffer()
      ..write('provider: $providerKind\n')
      ..write('model: $modelId\n')
      ..write('baseUrl: $baseUrl\n')
      ..write('mode: $mode\n')
      ..write('approvalMode: $approvalMode\n')
      ..write(_allowedToolsYaml())
      ..write(_promptOverridesYaml());
    final roles = modelRoles;
    if (roles != null) buffer.write(roles.toYaml());
    final ttsrConfig = ttsr;
    if (ttsrConfig != null) buffer.write(ttsrConfig.toYaml());
    buffer.write(_customProvidersYaml());
    final modelsConfig = models;
    if (modelsConfig != null && !modelsConfig.isEmpty) {
      buffer.write(modelsConfig.toYaml());
    }
    final mcpConfig = mcp;
    if (mcpConfig != null) buffer.write(mcpConfig.toYaml());
    buffer.write(_providerTimeoutsYaml());
    buffer.write(_skillsYaml());
    final cubeConfig = cube;
    if (cubeConfig != null) buffer.write(cubeConfig.toYamlFragment());
    final toolsConfig = tools;
    if (toolsConfig != null && !toolsConfig.isEmpty) {
      buffer.write(toolsConfig.toYaml());
    }
    buffer.write(_redactYaml());
    return buffer.toString();
  }

  /// The `redact:` section, only when explicitly configured; defaults are
  /// never written so the file stays minimal.
  String _redactYaml() {
    final config = redact;
    if (config == null || config == const RedactionConfig()) return '';
    final buffer = StringBuffer('redact:\n')
      ..write('  enabled: ${config.enabled}\n')
      ..write('  blockMode: ${config.blockMode}\n');
    if (config.layerToggles.isNotEmpty) {
      buffer.write('  layers:\n');
      config.layerToggles.forEach(
        (key, value) => buffer.write('    ${key.name}: $value\n'),
      );
    }
    String listYaml(String key, Iterable<String> values) {
      if (values.isEmpty) return '';
      // Values are single-quoted: regex patterns (allowlist) routinely
      // start with `[` or contain other YAML flow indicators.
      final items = values
          .map((value) => "    - '${value.replaceAll("'", "''")}'\n")
          .join();
      return '  $key:\n$items';
    }

    buffer
      ..write(
        listYaml('allowlist', [
          for (final regex in config.allowlistRegexes) regex.pattern,
        ]),
      )
      ..write(listYaml('toolAllow', config.toolAllow))
      ..write(listYaml('toolDeny', config.toolDeny));
    return buffer.toString();
  }

  String _providerTimeoutsYaml() {
    final timeouts = providerTimeouts;
    if (timeouts == null) return '';
    final buffer = StringBuffer('providerTimeouts:\n');
    final connect = timeouts.connect;
    if (connect != null) {
      buffer.write('  connectTimeoutMs: ${connect.inMilliseconds}\n');
    }
    final streamIdle = timeouts.streamIdle;
    if (streamIdle != null) {
      buffer.write('  streamIdleTimeoutMs: ${streamIdle.inMilliseconds}\n');
    }
    return buffer.toString();
  }

  String _skillsYaml() {
    if (!_skillsSectionNeeded) return '';
    final buffer = StringBuffer('skills:\n');
    _writeSkillsAccess(buffer);
    _writeSkillsDisableShellExecution(buffer);
    return buffer.toString();
  }

  bool get _skillsSectionNeeded =>
      skillsAccess != SkillsAccess.granted || skillsDisableShellExecution;

  void _writeSkillsAccess(StringBuffer buffer) {
    if (skillsAccess != SkillsAccess.granted) {
      buffer.write('  access: ${skillsAccessLabel(skillsAccess)}\n');
    }
  }

  void _writeSkillsDisableShellExecution(StringBuffer buffer) {
    if (skillsDisableShellExecution) {
      buffer.write('  disableShellExecution: true\n');
    }
  }

  String _allowedToolsYaml() {
    if (allowedTools.isEmpty) return 'allowedTools: []\n';
    final buffer = StringBuffer('allowedTools:\n');
    for (final tool in allowedTools) {
      buffer.write('  - $tool\n');
    }
    return buffer.toString();
  }

  String _promptOverridesYaml() {
    if (promptOverrides.isEmpty) return '';
    // JSON-quoted values are valid yaml scalars and keep inline multi-line
    // prompt text round-trippable (same convention as the ttsr section).
    final buffer = StringBuffer('prompts:\n');
    for (final entry in promptOverrides.entries) {
      buffer.write('  ${entry.key}: ${jsonEncode(entry.value)}\n');
    }
    return buffer.toString();
  }

  String _customProvidersYaml() {
    if (customProviders.isEmpty) return '';
    final buffer = StringBuffer('customProviders:\n');
    for (final entry in customProviders) {
      buffer.write(
        '  - name: ${entry.name}\n'
        '    apiType: ${entry.apiType}\n'
        '    baseUrl: ${entry.baseUrl}\n',
      );
      if (entry.keyName != null) {
        buffer.write('    keyName: ${entry.keyName}\n');
      }
      buffer.write('    modelId: ${entry.modelId}\n');
    }
    return buffer.toString();
  }
}

/// Returns the user's home directory, or `null` if it cannot be determined.
String? homeDirectory() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  }
  return Platform.environment['HOME'];
}

/// Loads [CliConfig] from `~/.fah/config.yaml`.
///
/// Returns defaults when the file is missing or unreadable. A syntactically
/// valid file whose model-roles section is invalid throws [ConfigException]
/// (bad roles must surface, never silently vanish).
CliConfig loadCliConfig(String homeDir) {
  final file = File('$homeDir/.fah/config.yaml');
  if (!file.existsSync()) return CliConfig();
  try {
    final content = file.readAsStringSync();
    final doc = loadYaml(content);
    if (doc is YamlMap) return CliConfig.fromYaml(doc);
  } on ConfigException {
    rethrow;
  } on Object {
    // Ignore corrupt config and fall back to defaults.
  }
  return CliConfig();
}

/// Loads the PROJECT-level `memory:` section from
/// `<projectDir>/.fah/config.yaml` — the git-backed memory path travels
/// with the repo (anyone cloning gets the pointer AND the memory).
/// Project wins over the user-level `memory:` section. Null when the
/// file or the section is absent/unreadable; a present-but-invalid
/// section throws [ConfigException] (strict, like the user config).
MemoryConfig? loadProjectMemoryConfig(String projectDir) {
  final file = File('$projectDir/.fah/config.yaml');
  if (!file.existsSync()) return null;
  try {
    final doc = loadYaml(file.readAsStringSync());
    if (doc is! YamlMap) return null;
    final node = doc['memory'];
    return node == null ? null : MemoryConfig.fromYaml(node);
  } on ConfigException {
    rethrow;
  } on Object {
    return null;
  }
}

/// Loads the PROJECT-level `cube:` section from
/// `<projectDir>/.fah/config.yaml` — the git-backed sandbox default
/// travels with the repo. Project wins over the user-level `cube:`
/// section. Null when the file or the section is absent/unreadable; a
/// present-but-invalid section throws [ConfigException] (strict, like the
/// user config).
CubeSettings? loadProjectCubeSettings(String projectDir) {
  final file = File('$projectDir/.fah/config.yaml');
  if (!file.existsSync()) return null;
  try {
    final doc = loadYaml(file.readAsStringSync());
    if (doc is! YamlMap) return null;
    final node = doc['cube'];
    return node == null ? null : CubeSettings.fromYaml(node);
  } on ConfigException {
    rethrow;
  } on Object {
    return null;
  }
}

/// Loads the PROJECT-level `tools:` section from
/// `<projectDir>/.fah/config.yaml` — the git-backed availability policy
/// travels with the repo. The PROJECT scope is consumed live (separate
/// from the saved global [CliConfig.tools]) so the deepest-wins resolution
/// can stack both. Null when the file or the section is absent/unreadable;
/// a present-but-invalid section throws [ConfigException] (strict, like
/// the user config).
ToolsConfig? loadProjectToolsConfig(String projectDir) {
  final file = File('$projectDir/.fah/config.yaml');
  if (!file.existsSync()) return null;
  try {
    final doc = loadYaml(file.readAsStringSync());
    if (doc is! YamlMap) return null;
    final node = doc['tools'];
    return node == null ? null : ToolsConfig.fromYaml(node);
  } on ConfigException {
    rethrow;
  } on Object {
    return null;
  }
}

/// Parses the `FA_TOOLS` env twin of the `--tools` flag: the same csv
/// spec, for Docker/headless hosts that cannot pass flags. Absent or empty
/// yields null (no runtime intent); a malformed value throws
/// [ConfigException] naming the bad token.
ToolsConfig? toolsSpecFromEnv(Map<String, String> env) {
  final spec = env['FA_TOOLS'];
  if (spec == null || spec.trim().isEmpty) return null;
  return parseToolsSpec(spec);
}

/// The startup cube source (fa_cube): explicit flags win, then the project
/// `cube:` section, then the user `cube:` section — each config section
/// applies only when enabled. Null = start unsandboxed.
String? resolveStartupCubeSource({
  String? flagConfigPath,
  String? flagName,
  CubeSettings? project,
  CubeSettings? user,
}) {
  if (flagConfigPath != null) return flagConfigPath;
  if (flagName != null) return flagName;
  if (project != null && project.enabled) return project.configPath;
  if (user != null && user.enabled) return user.configPath;
  return null;
}

/// Saves [CliConfig] to `~/.fah/config.yaml`.
Future<void> saveCliConfig(String homeDir, CliConfig config) async {
  final dir = Directory('$homeDir/.fah');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('${dir.path}/config.yaml');
  await file.writeAsString(config.toYaml());
}
