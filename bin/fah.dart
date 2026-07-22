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
/// exits (response on stdout, diagnostics on stderr). Run with `--help` for
/// the full reference (`cliHelpText` in `lib/src/cli/cli_help.dart`).
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
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:yaml/yaml.dart' as yaml;

import 'self_manage.dart';

const _fallbackVersion = '0.1.0';

/// Reads the package version with three fallbacks so compiled binaries stay
/// accurate: `-DFA_VERSION=` baked at compile time (CI releases), then the
/// `pubspec.yaml` next to the executable (source runs), then the constant.
String _packageVersion() {
  const fromEnv = String.fromEnvironment('FA_VERSION');
  if (fromEnv.isNotEmpty) return fromEnv;
  try {
    final scriptPath = Platform.script.toFilePath();
    final pubspec = File('${File(scriptPath).parent.parent.path}/pubspec.yaml');
    final doc = yaml.loadYaml(pubspec.readAsStringSync()) as Map;
    final value = doc['version'];
    if (value is String && value.isNotEmpty) return value;
  } on Object {
    // Fall back to the compile-time constant when the pubspec is unavailable.
  }
  return _fallbackVersion;
}

Never _fail(String message) {
  stderr.writeln('fa: $message');
  stderr.writeln('Run with --help for usage.');
  exit(64);
}

/// macOS Core Graphics modifier check, mirroring pi's native-modifiers
/// helper: terminals that do not encode Shift+Enter in the input stream
/// still let us read the live Shift state from the HID system. Lazily opened
/// so non-macOS hosts never touch the dylib.
typedef _CGEventSourceFlagsStateC = ffi.Uint64 Function(ffi.Uint32);
typedef _CGEventSourceFlagsStateDart = int Function(int);

int Function(int)? _cgEventSourceFlagsState;
var _cgLookupAttempted = false;

bool _isShiftPressed() {
  if (!Platform.isMacOS) return false;
  if (!_cgLookupAttempted) {
    _cgLookupAttempted = true;
    try {
      final coreGraphics = ffi.DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      );
      _cgEventSourceFlagsState = coreGraphics
          .lookupFunction<
            _CGEventSourceFlagsStateC,
            _CGEventSourceFlagsStateDart
          >('CGEventSourceFlagsState');
    } on Object {
      _cgEventSourceFlagsState = null;
    }
  }
  final fn = _cgEventSourceFlagsState;
  if (fn == null) return false;
  const kCGEventSourceStateHIDSystemState = 1;
  const kCGEventFlagMaskShift = 0x00020000;
  try {
    final flags = fn(kCGEventSourceStateHIDSystemState);
    return (flags & kCGEventFlagMaskShift) != 0;
  } on Object {
    return false;
  }
}

Never _exitWithUsage(String version) {
  stdout.write(cliHelpText(version));
  exit(0);
}

Never _exitWithVersion(String version) {
  stdout.writeln('fa $version');
  exit(0);
}

Model _buildModel(CliArgs args) {
  return buildCliDefaultModel(
    args.provider,
    modelId: args.model,
    baseUrl: args.baseUrl,
  );
}

String? _optionalApiKey(String provider, SecureKeyCache keys) {
  final env = Platform.environment;
  // Resolution order per key name: environment first, then the platform
  // secure store (macOS Keychain / Secret Service / Credential Locker).
  String? byName(String name) {
    final value = env[name];
    if (value != null && value.isNotEmpty) return value;
    return keys.read(name);
  }

  return switch (provider) {
    'anthropic' => byName('ANTHROPIC_API_KEY'),
    'google' => byName('GOOGLE_API_KEY'),
    'vision' => byName('VISION_API_KEY'),
    'transcribe' => byName('TRANSCRIBE_API_KEY'),
    _ => byName('OPENROUTER_API_KEY') ?? byName('OPENAI_API_KEY'),
  };
}

String _resolveApiKey(
  String provider,
  SecureKeyCache keys, {
  String? fallback,
}) {
  final key = _optionalApiKey(provider, keys) ?? fallback;
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
/// `apiKeyName` in the roles config. The platform secure store backs up
/// base names where the environment has none (env wins; rotation stacks
/// stay env-only — secure storage holds base names only).
Map<String, String> _collectRoleSecrets(
  ModelRolesConfig rolesConfig,
  SecureKeyCache keys,
) {
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
    if (!secrets.containsKey(base)) {
      final stored = keys.read(base);
      if (stored != null) secrets[base] = stored;
    }
  }
  return secrets;
}

/// The explicit `apiKeyName`s referenced by a roles config (the secure-store
/// preload set; the catalog names are always preloaded).
Set<String> _roleKeyNames(ModelRolesConfig rolesConfig) {
  return {
    for (final chain in rolesConfig.roles.values)
      for (final ref in chain)
        if (ref.apiKeyName != null) ref.apiKeyName!,
    for (final override in rolesConfig.pathOverrides)
      for (final chain in override.roles.values)
        for (final ref in chain)
          if (ref.apiKeyName != null) ref.apiKeyName!,
  };
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
  StreamController<KeyEvent>? _keyController;
  StreamSubscription<List<int>>? _keySub;
  var _rawModeOk = true;

  void fireInterrupt() => _interrupts.add(null);

  @override
  Stream<String> get lines => headless
      ? const Stream<String>.empty()
      : stdin.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<KeyEvent> get keys {
    if (headless || !supportsRawMode) return const Stream<KeyEvent>.empty();
    _keyController ??= StreamController<KeyEvent>.broadcast(
      onListen: _startRawInput,
      onCancel: _stopRawInput,
    );
    return _keyController!.stream;
  }

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

  @override
  bool get supportsRawMode => !headless && stdin.hasTerminal && _rawModeOk;

  @override
  int get columns => stdout.terminalColumns;

  @override
  int get rows => stdout.terminalLines;

  void _startRawInput() {
    if (_keySub != null) return;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } on Exception {
      // Raw mode is not available in this terminal (e.g. embedded panels or
      // some Windows consoles). Fall back to canonical line input.
      _rawModeOk = false;
      _keyController?.close();
      return;
    }
    _keySub = stdin.listen(
      _onRawBytes,
      onDone: () => _keyController?.close(),
      onError: (_) => _keyController?.close(),
    );
  }

  void _stopRawInput() {
    _keySub?.cancel();
    _keySub = null;
    try {
      stdin.echoMode = true;
      stdin.lineMode = true;
    } on Exception {
      // May fail if the process is shutting down; ignore.
    }
  }

  /// Restores canonical terminal mode. Called before an idle Ctrl-C exits so
  /// the shell is not left in raw mode.
  void resetRawMode() => _stopRawInput();

  void _onRawBytes(List<int> bytes) {
    final controller = _keyController;
    if (controller == null || controller.isClosed) return;
    final events = _decodeKeys(bytes);
    for (final event in events) {
      controller.add(event);
    }
  }

  /// Decodes raw terminal bytes into [KeyEvent]s. Handles ASCII control
  /// characters and common ANSI escape sequences for arrow keys, home/end,
  /// and delete.
  List<KeyEvent> _decodeKeys(List<int> bytes) {
    final result = <KeyEvent>[];
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 0x1b) {
        // ANSI escape sequence.
        if (i + 2 < bytes.length && bytes[i + 1] == 0x5b) {
          final code = bytes[i + 2];
          switch (code) {
            case 0x41:
              result.add(const KeyEvent(type: KeyType.up));
            case 0x42:
              result.add(const KeyEvent(type: KeyType.down));
            case 0x43:
              result.add(const KeyEvent(type: KeyType.right));
            case 0x44:
              result.add(const KeyEvent(type: KeyType.left));
            case 0x48:
              result.add(const KeyEvent(type: KeyType.home));
            case 0x46:
              result.add(const KeyEvent(type: KeyType.end));
            case 0x33:
              if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                result.add(const KeyEvent(type: KeyType.delete));
                i += 3;
                continue;
              }
            case 0x31:
              if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                result.add(const KeyEvent(type: KeyType.home));
                i += 3;
                continue;
              }
            case 0x34:
              if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                result.add(const KeyEvent(type: KeyType.end));
                i += 3;
                continue;
              }
            default:
              result.add(const KeyEvent(type: KeyType.unknown));
          }
          i += 2;
        } else if (i + 1 < bytes.length && bytes[i + 1] == 0x4f) {
          // SS3 sequences: ESC O H / ESC O F on some terminals.
          if (i + 2 < bytes.length) {
            final code = bytes[i + 2];
            if (code == 0x48) {
              result.add(const KeyEvent(type: KeyType.home));
            } else if (code == 0x46) {
              result.add(const KeyEvent(type: KeyType.end));
            } else {
              result.add(const KeyEvent(type: KeyType.unknown));
            }
            i += 2;
          } else {
            result.add(const KeyEvent(type: KeyType.escape));
          }
        } else {
          result.add(const KeyEvent(type: KeyType.escape));
        }
      } else if (b == 0x09) {
        result.add(const KeyEvent(type: KeyType.tab));
      } else if (b == 0x0d || b == 0x0a) {
        result.add(const KeyEvent(type: KeyType.enter));
      } else if (b == 0x7f) {
        result.add(const KeyEvent(type: KeyType.backspace));
      } else if (b == 0x00) {
        // Ctrl-Space / null byte; ignore.
      } else if (b < 0x20) {
        // Ctrl+letter printable-ish range; treat as char for now.
        result.add(
          KeyEvent(
            char: String.fromCharCode(b + 0x40),
            type: KeyType.char,
            ctrl: true,
          ),
        );
      } else {
        result.add(KeyEvent(char: String.fromCharCode(b), type: KeyType.char));
      }
    }
    return result;
  }
}

Future<void> main(List<String> args) async {
  final packageVersion = _packageVersion();

  late final CliArgs parsed;
  try {
    parsed = switch (parseCliArgs(args)) {
      CliArgsHelp() => _exitWithUsage(packageVersion),
      CliArgsVersion() => _exitWithVersion(packageVersion),
      final CliArgs cliArgs => cliArgs,
    };
  } on CliArgsException catch (error) {
    _fail(error.message);
  }

  // Quick self-management commands, intercepted before prompt resolution:
  // `fa update` swaps in the latest release binary; `fa uninstall` removes
  // the binary + PATH entry (and ~/.fah on a second confirmation).
  if (parsed.positionals.length == 1 && parsed.prompt == null) {
    switch (parsed.positionals.single) {
      case 'update':
        exit(await runSelfUpdate(currentVersion: packageVersion));
      case 'uninstall':
        exit(await runSelfUninstall());
    }
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
    session: parsed.session,
  );

  final model = _buildModel(effective);
  final cwd = effective.cwd ?? Directory.current.path;
  final sessionRoot = effective.sessionRoot ?? _defaultSessionRoot();

  // Platform secure storage (macOS Keychain / Secret Service / Windows
  // Credential Locker): backs up every provider key the environment does
  // not set. Reads are process spawns, so the store is preloaded once into
  // a synchronous session cache — every later lookup (startup resolution,
  // the banner, `/provider`, `/key`) hits the snapshot.
  final keyCache = SecureKeyCache(platformSecureKeyStore());
  await keyCache.preload({
    for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
    'VISION_API_KEY',
    'TRANSCRIBE_API_KEY',
    if (saved.modelRoles != null) ..._roleKeyNames(saved.modelRoles!),
  });

  // Prompt overrides: the `prompts:` section of ~/.fah/config.yaml (file
  // paths resolve against the agent cwd, `~` expands; missing files are a
  // hard error, never a silent fallback).
  late final PromptOverrides promptOverrides;
  try {
    promptOverrides = resolvePromptOverrides(
      saved.promptOverrides,
      homeDir: home,
      baseDir: cwd,
    );
  } on ConfigException catch (error) {
    _fail('invalid ~/.fah/config.yaml: ${error.message}');
  }

  // --system-prompt[-file]: a per-invocation system prompt override that
  // wins over the config prompts: section and the built-in mode prompts.
  // The flag file resolves like file-as-prompt: relative to the process
  // working directory, where the user typed the command.
  var flagSystemPrompt = parsed.systemPrompt;
  final systemPromptFile = parsed.systemPromptFile;
  if (systemPromptFile != null) {
    try {
      flagSystemPrompt = loadPromptFile(
        systemPromptFile,
        homeDir: home,
        baseDir: Directory.current.path,
        source: '--system-prompt-file',
      );
    } on ConfigException catch (error) {
      _fail(error.message);
    }
  }

  // Model roles (optional): when ~/.fah/config.yaml declares a `roles:`
  // section, runs resolve through the default role's fallback chain with
  // key rotation. The legacy single provider/model path stays the fallback
  // when no default role resolves.
  final rolesConfig = saved.modelRoles;
  final roleSecrets = rolesConfig == null
      ? const <String, String>{}
      : _collectRoleSecrets(rolesConfig, keyCache);
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
  // A base URL other than the catalog default (--base-url or config baseUrl)
  // means a user-configured endpoint: local llama.cpp/Ollama/LM Studio
  // servers need no key at all, so the key is optional there (the hosted
  // presets keep requiring one; the config default IS the OpenRouter URL, so
  // compare values, not nullness). Roles mode already tolerates a missing
  // key; the openai-completions adapter omits the Authorization header
  // entirely when the key is empty.
  final customEndpoint =
      provider == 'openai-completions' &&
      baseUrl != providerCatalog['openrouter']!.defaultBaseUrl;
  // Interactive REPL can start without a key: the user can switch providers,
  // models, or base URLs with slash commands before the first run. Headless
  // mode needs a key immediately because it performs a single run and exits.
  final interactive = headlessPrompt == null;
  final apiKey = defaultRoleResolved || customEndpoint || interactive
      ? (_optionalApiKey(provider, keyCache) ?? '')
      : _resolveApiKey(provider, keyCache);

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
  // As are the keys preloaded from the platform secure store (keychain
  // values must never reach the transcript either).
  for (final name in keyCache.names) {
    final value = keyCache.read(name);
    if (value != null) redactor.register(name, value);
  }
  // Whether the redactor is attached to the agent. A keyless startup leaves
  // it detached; a `/provider` token arriving at runtime attaches it then.
  var redactorAttached = !redactor.isEmpty;

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
      apiKey: _resolveApiKey('vision', keyCache, fallback: apiKey),
      baseUrl: effective.visionBaseUrl,
    );
  }

  TranscribeAudioConfig? transcribeConfig;
  if (effective.transcribeModel != null) {
    transcribeConfig = TranscribeAudioConfig(
      modelId: effective.transcribeModel!,
      apiKey: _resolveApiKey('transcribe', keyCache, fallback: apiKey),
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
  if (io.isInteractive && !io.supportsRawMode) {
    io.writeln(
      'note: this terminal does not support raw-mode input; '
      'interactive slash/model menus are unavailable.',
    );
  }
  // `late` so the onProviderChanged closure can reach the agent (to attach
  // the secret redactor on a runtime token) before the variable is assigned.
  late final AgentCli cli;
  cli = AgentCli(
    useColor: headlessPrompt == null && stdout.supportsAnsiEscapes,
    useTui:
        headlessPrompt == null &&
        stdout.supportsAnsiEscapes &&
        io.isInteractive,
    version: packageVersion,
    config: AgentCliConfig(
      model: model,
      apiKey: apiKey,
      providerKind: provider,
      // The banner names the key env var in play (name only, never the
      // value); the catalog maps the effective provider to its var names.
      // A name counts as set when the environment OR the secure store has
      // it; the value resolves env-first.
      envVarIsSet: (name) =>
          (Platform.environment[name] ?? '').isNotEmpty ||
          keyCache.read(name) != null,
      // `/provider` resolves the target provider's key from the environment
      // (or the secure store) when no explicit token is passed.
      envVarValue: (name) {
        final value = Platform.environment[name];
        if (value != null && value.isNotEmpty) return value;
        return keyCache.read(name);
      },
      // `/key` manages the platform secure store; `/provider ... <token>`
      // persists the token there.
      secureKeys: keyCache,
      env: LocalExecutionEnv(cwd: cwd),
      sessionRoot: sessionRoot,
      sessionName: effective.session,
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
      systemPrompt: flagSystemPrompt,
      promptOverrides: promptOverrides,
      approvalMode:
          approvalModeFromLabel(saved.approvalMode) ?? ApprovalMode.yolo,
      alwaysAllowTools: saved.allowedTools.toSet(),
      modelRolesResolver: rolesResolver,
      homeDir: home,
      // TTSR stream rules: user config (~/.fah/config.yaml `ttsr:`) merged
      // with project rules (.fah/rules.yaml), project first.
      ttsr: _resolveTtsr(saved, cwd),
      onModelChanged: (_) async => persistConfig(),
      // `/provider` switches: redact an explicitly passed session token so
      // it cannot leak into tool results or session files, then persist the
      // new provider/model/baseUrl triple (never the key itself).
      onProviderChanged: (kind, key) async {
        if (key.isNotEmpty) {
          redactor.register('/provider token', key);
          // A keyless startup never attached the redactor; a runtime token
          // still gets masked from here on.
          if (!redactorAttached) {
            attachSecretRedactor(cli.agent, redactor);
            redactorAttached = true;
          }
        }
        await persistConfig();
      },
      // `/key set` stored a secret: mask it from here on (same lazy attach).
      onSecretStored: (name, value) {
        redactor.register(name, value);
        if (!redactorAttached && !redactor.isEmpty) {
          attachSecretRedactor(cli.agent, redactor);
          redactorAttached = true;
        }
      },
      onModeChanged: (_) async => persistConfig(),
      onApprovalChanged: () async => persistConfig(),
      // Shift+Enter in the TUI: terminals that do not encode the modifier
      // still expose it through the HID state (macOS only; null elsewhere).
      isShiftPressed: Platform.isMacOS ? _isShiftPressed : null,
    ),
    io: io,
  );
  if (redactorAttached) attachSecretRedactor(cli.agent, redactor);

  persistConfig = () async {
    await saveCliConfig(
      home,
      CliConfig(
        providerKind: cli.providerKind,
        modelId: cli.agent.state.model.id,
        baseUrl: cli.agent.state.model.baseUrl,
        mode: cli.currentMode.name,
        approvalMode: cli.approval.mode.label,
        allowedTools: cli.approval.alwaysAllowedTools,
        // Prompt overrides are static per session; keep the loaded raw map
        // so saving doesn't drop the section.
        promptOverrides: saved.promptOverrides,
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
      // headless mode so a pipe never sees it. Restore canonical mode first
      // so the shell is not left with raw input disabled.
      if (headlessPrompt == null) {
        io.resetRawMode();
        stdout.writeln();
      }
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

  // Swallow late terminal query responses: dart_tui asks the terminal for its
  // background color and sync-update support at startup, and the replies
  // arrive as ordinary stdin bytes. If they land after the program stopped
  // listening, the shell echoes them as garbage characters at the prompt.
  // Drain stdin briefly in raw mode before handing the terminal back.
  if (stdin.hasTerminal) {
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      final drain = stdin.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await drain.cancel();
      try {
        stdin.echoMode = true;
        stdin.lineMode = true;
      } on Exception {
        // Best effort.
      }
    } on Object {
      // Nothing to drain: on Windows a cancelled stdin subscription keeps
      // the underlying console read alive, so re-listening throws "Stream
      // has already been listened to" — skipping the drain only means the
      // late query replies may echo once in the shell.
    }
  }
}
