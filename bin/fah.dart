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
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:yaml/yaml.dart' as yaml;

import 'self_manage.dart';
import 'serve_a2a.dart';

const _fallbackVersion = '0.1.0';

/// Reads the package version with four fallbacks so compiled binaries stay
/// accurate: `-DFA_VERSION=` baked at compile time (legacy AOT builds), then
/// a `version.txt` file alongside the `dart build cli` bundle, then the
/// `pubspec.yaml` next to the executable (source runs), then the constant.
String _packageVersion() {
  const fromEnv = String.fromEnvironment('FA_VERSION');
  if (fromEnv.isNotEmpty) return fromEnv;
  try {
    // Platform.resolvedExecutable always returns the full canonical path,
    // even when the binary was invoked via a bare name or relative path.
    // Platform.script may return a relative path on some platforms, which
    // makes exeDir = cwd instead of the binary's real directory.
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent;
    final bundleRoot = exeDir.parent;
    // Try bundle/version.txt first (dart build cli layout).
    final versionFile = File('${bundleRoot.path}/version.txt');
    if (versionFile.existsSync()) {
      final v = versionFile.readAsStringSync().trim();
      if (v.isNotEmpty) return v;
    }
    // Try <exe_dir>/version.txt (installer layout: version.txt next to fa).
    final dirVersionFile = File('${exeDir.path}/version.txt');
    if (dirVersionFile.existsSync()) {
      final v = dirVersionFile.readAsStringSync().trim();
      if (v.isNotEmpty) return v;
    }
    // Source run: pubspec.yaml sits two levels up from bin/.
    final pubspec = File('${bundleRoot.path}/pubspec.yaml');
    final doc = yaml.loadYaml(pubspec.readAsStringSync()) as Map;
    final value = doc['version'];
    if (value is String && value.isNotEmpty) return value;
  } on Object {
    // Fall back to the compile-time constant when nothing is available.
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

/// Writes an uncaught error to `~/.fah/crash.log` and stderr, then exits
/// non-zero. This is the last-resort handler so users can report what
/// happened instead of the CLI silently disappearing.
void _handleUncaughtError(Object error, StackTrace stackTrace) {
  final message = 'fa crashed: $error';
  stderr.writeln(message);
  if (error is SessionException ||
      message.contains('Failed to create session directory')) {
    stderr.writeln(
      '\nTip: If this is a permission issue with session storage, you can fix it by running:\n'
      '  sudo chown -R \$(whoami) ~/Library/"Group Containers"/group.dev.fa1.shared\n'
      '  chmod -R u+rwx ~/Library/"Group Containers"/group.dev.fa1.shared\n'
      'Or start fa with a custom session storage path:\n'
      '  fa --session-root ~/.fah/sessions\n',
    );
  }
  try {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final dir = Directory('$home/.fah');
      dir.createSync(recursive: true);
      final log = File('${dir.path}/crash.log');
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final version = _packageVersion();
      final buffer = StringBuffer()
        ..writeln('timestamp: $timestamp')
        ..writeln('version: $version')
        ..writeln('error: $error')
        ..writeln('stack:')
        ..writeln(stackTrace);
      log.writeAsStringSync('$buffer\n', mode: FileMode.append);
      stderr.writeln('details appended to ${log.path}');
    }
  } on Object catch (e) {
    stderr.writeln('could not write crash log: $e');
  }
  stderr.writeln('Run with --help for usage.');
  exit(1);
}

Future<void> main(List<String> args) async {
  await runZoned(
    () => _runApp(args),
    zoneSpecification: ZoneSpecification(
      handleUncaughtError: (self, parent, zone, error, stackTrace) {
        _handleUncaughtError(error, stackTrace);
      },
    ),
  );
}

Model _buildModel(CliArgs args) {
  return buildCliDefaultModel(
    args.provider,
    modelId: args.model,
    baseUrl: args.baseUrl,
  );
}

/// The env preconfig pick for this invocation — `(spec, activating env var
/// name)`, or null. Fires only on a pristine config: [CliConfig] has
/// non-null defaults (a fresh install reads providerKind
/// 'openai-completions', model 'openai/gpt-4o-mini', the OpenRouter URL),
/// so null-checks on the saved fields are dead code — "the user never
/// configured anything" means every provider-relevant field still equals
/// that pristine default. An explicit --provider or --model wins; any
/// saved provider switch, base URL, roles section, or custom provider
/// disables the pick.
(ProviderSpec, String)? _envPreconfigPick(CliArgs parsed, CliConfig saved) {
  final pristine = CliConfig();
  final untouched =
      !parsed.providerExplicit &&
      parsed.model == null &&
      saved.providerKind == pristine.providerKind &&
      saved.modelId == pristine.modelId &&
      saved.baseUrl == pristine.baseUrl &&
      saved.modelRoles == null &&
      saved.customProviders.isEmpty;
  if (!untouched) return null;
  final picked = envPreconfiguredProvider((name) => Platform.environment[name]);
  if (picked == null) return null;
  return (
    picked,
    picked.apiKeyEnvNames.firstWhere(
      (name) => (Platform.environment[name] ?? '').isNotEmpty,
    ),
  );
}

/// The `FA_PROVIDER_*` env preconfig (Docker/headless): `FA_PROVIDER_TYPE` +
/// `FA_PROVIDER_NAME` + `FA_PROVIDER_CONFIG` (a JSON object with required
/// `baseUrl`/`model` and an optional `apiKeyEnvVar`) plus the key env var
/// the config references. Every text input has a `_BASE64` twin
/// (`FA_PROVIDER_CONFIG_BASE64`, `<apiKeyEnvVar>_BASE64`) for platforms
/// that mangle special characters; when both carry the same value the
/// plain one is used. Unlike the catalog auto-pick above, this is an
/// explicit declaration, so it wins over the saved config restore too — a
/// container that declares its provider in env vars runs on it, store or
/// config notwithstanding, and the declaration becomes the session
/// default for every model role (the same selection a `/provider <name>`
/// switch performs). An explicit `--provider` flag means full manual
/// control and disables the preconfig entirely (mixing the flag's
/// provider with the env endpoint would be a silent misconfiguration).
///
/// Throws via [_fail] on a malformed declaration: a container that names its
/// provider wrong must fail loud at boot, not 401 mid-run.
EnvProviderPreconfig? _faProviderPreconfig(CliArgs parsed, CliConfig saved) {
  if (parsed.providerExplicit) return null;
  final env = Platform.environment;
  try {
    return parseEnvProviderPreconfig(
      providerType: env['FA_PROVIDER_TYPE'],
      providerName: env['FA_PROVIDER_NAME'],
      providerConfig: env['FA_PROVIDER_CONFIG'],
      providerConfigBase64: env['FA_PROVIDER_CONFIG_BASE64'],
      envVarValue: (name) => env[name],
      takenNames: [for (final entry in saved.customProviders) entry.name],
    );
  } on ConfigException catch (error) {
    _fail('invalid FA_PROVIDER_* preconfig: ${error.message}');
  }
}

/// Every catalog provider's env names (a redaction preload set: an env
/// value of ANY supported provider key must never reach the transcript).
List<String> _allCatalogEnvNames() => [
  for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
];

String _resolveApiKey(
  String provider,
  SecureKeyCache keys, {
  String? fallback,
  String? baseUrl,
  Iterable<String>? scopedKeyNames,
}) {
  final key =
      optionalProviderApiKey(
        provider,
        keys,
        baseUrl: baseUrl,
        scopedKeyNames: scopedKeyNames,
      ) ??
      fallback;
  if (key == null || key.isEmpty) {
    _fail(
      'missing API key: set ${apiKeyEnvNames(provider).first} in the '
      'environment',
    );
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
  if (Platform.isMacOS) {
    final groupDir =
        '$home/Library/Group Containers/group.dev.fa1.shared/fa/sessions';
    if (_isDirWritable(groupDir)) {
      return groupDir;
    }
    return '$home/.fah/sessions';
  }
  return '$home/.fah/sessions';
}

bool _isDirWritable(String path) {
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final probe = File('$path/.probe_${DateTime.now().microsecondsSinceEpoch}');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

String _homeDir() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    _fail('cannot resolve home directory; pass --session-root');
  }
  return home;
}

/// The runtime `FA_PROVIDERS` env override, applied at startup (the
/// dart-define always wins over it; see [providerEnabledInBuild]).
void _applyProviderFilterEnv() {
  final value = Platform.environment['FA_PROVIDERS'];
  if (value != null && value.trim().isNotEmpty) {
    providerFilterEnvOverride = value;
  }
}

/// Truthy env-var check (`1`/`true`/`yes`/`on`, case-insensitive).
/// The inverse default for flags that are ON unless explicitly disabled:
/// unset or a truthy value → true; only `0`/`false`/`no`/`off` → false.
bool _envNotFalsy(String name) {
  final value = Platform.environment[name]?.trim().toLowerCase();
  return value != '0' && value != 'false' && value != 'no' && value != 'off';
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
  int get columns {
    // stdout can be a pipe (session switch replay, headless-ish paths) —
    // terminalColumns throws StdoutException there (crash.log had two).
    try {
      return stdout.terminalColumns;
    } on StdoutException {
      return 80;
    }
  }

  @override
  int get rows {
    try {
      return stdout.terminalLines;
    } on StdoutException {
      return 24;
    }
  }

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

/// `fa serve --a2a` — mounts the fully-configured agent as an A2A endpoint
/// (Phase 5b). Every `message/send` runs one headless turn against the
/// resolved provider/model; the agent's reply becomes the task artifact.
Future<void> _serveA2a({
  required Model model,
  required String provider,
  required String apiKey,
  required int port,
  required String? token,
}) async {
  await runA2aServer(
    port: port,
    token: token,
    agentName: 'fa',
    agentDescription:
        'Fa CLI agent (flutter_agent_harness) — $provider/${model.id}',
    runner: (userMessage) async {
      final stream = providerStreamFunction(provider, apiKey)(
        model,
        Context(
          systemPrompt: cliCodeModePrompt.replaceAll(
            '{{cwd}}',
            Directory.current.path,
          ),
          messages: [UserMessage.text(userMessage)],
        ),
      );
      final response = await stream.result;
      if (response.stopReason == StopReason.error ||
          response.stopReason == StopReason.aborted) {
        throw StateError(response.errorMessage ?? 'agent turn failed');
      }
      return response.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join('\n')
          .trim();
    },
  );
}

/// Reads an int flag from the serve positionals (`--port N`).
int _serveFlagInt(List<String> args, String flag, int fallback) {
  final idx = args.indexOf(flag);
  if (idx < 0 || idx + 1 >= args.length) return fallback;
  return int.tryParse(args[idx + 1]) ?? fallback;
}

/// Reads a string flag from the serve positionals (`--token T`).
String? _serveFlagStr(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

Future<void> _runApp(List<String> args) async {
  final packageVersion = _packageVersion();
  _applyProviderFilterEnv();

  // `fa serve --a2a [--port N] [--token T]` — the parser does not know the
  // `--a2a` flag, so the serve form is intercepted before CliArgs parsing:
  // serve-specific flags are stripped from the parsed args and kept for the
  // late interception below (after model/key resolution).
  final isServeA2a = args.contains('serve');
  if (isServeA2a && !args.contains('--a2a')) {
    _fail('usage: fa serve --a2a [--port N] [--token T]');
  }
  final parseArgs = isServeA2a
      ? [
          for (var i = 0; i < args.length; i++)
            if (args[i] != 'serve' &&
                args[i] != '--a2a' &&
                args[i] != '--port' &&
                args[i] != '--token' &&
                (i == 0 ||
                    (args[i - 1] != '--port' && args[i - 1] != '--token')))
              args[i],
        ]
      : args;

  late final CliArgs parsed;
  try {
    parsed = switch (parseCliArgs(parseArgs)) {
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
  // Provider watchdog overrides (`providerTimeouts:` section): process-wide,
  // read by the adapters' connect/idle watchdogs on every request.
  providerTimeoutsOverride = saved.providerTimeouts;

  // An explicit --provider wins; without it the saved `provider:` (the
  // persisted /provider switch) restores the last provider kind — model and
  // baseUrl already restore from the config, losing only the kind would
  // rebuild e.g. dial as a plain openai endpoint. Only kinds the legacy
  // single-model path can build are restored (chatgpt-codex keeps the
  // openai-completions default; its OAuth flow re-establishes on demand).
  const restorableKinds = {
    'openai-completions',
    'anthropic',
    'google',
    'dial',
    'minimax',
    'zai',
  };
  // Explicit env preconfig (FA_PROVIDER_*): a container's declaration of its
  // provider. Precedence: an explicit --provider flag (full manual control,
  // preconfig disabled) > FA_PROVIDER_* > the pristine-config catalog pick
  // below > the saved kind restore > the default. The preconfig supplies
  // model/baseUrl too, so the saved restore never leaks through while it is
  // active (--model/--base-url flags still override individual fields).
  final faPreconfig = _faProviderPreconfig(parsed, saved);
  // Out-of-the-box env preconfig: on a pristine config (nothing the user
  // saved) an API key in the environment activates its catalog provider —
  // `ZAI_API_KEY=... fa` just runs. The pick wins over the pristine
  // (default) saved kind; anything configured skips it entirely — including
  // the explicit FA_PROVIDER_* declaration above.
  final (ProviderSpec, String)? envPreconfig = faPreconfig == null
      ? _envPreconfigPick(parsed, saved)
      : null;
  final provider = parsed.providerExplicit
      ? parsed.provider
      : faPreconfig?.spec.kind ??
            envPreconfig?.$1.kind ??
            (restorableKinds.contains(saved.providerKind)
                ? saved.providerKind
                : parsed.provider);
  String? modelId = parsed.model ?? faPreconfig?.modelId ?? saved.modelId;
  String? baseUrl = parsed.baseUrl ?? faPreconfig?.baseUrl ?? saved.baseUrl;
  // The pristine saved model/baseUrl are the constant defaults, not user
  // choices: the picked provider's catalog default model and endpoint
  // replace them.
  if (envPreconfig != null) {
    modelId = catalogDefaultModelId(envPreconfig.$1.name);
    baseUrl = null;
  }
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

  // Remote provider catalog (fa1.dev/models-catalog.json): default model
  // ids and per-provider context-window tables for endpoints that don't
  // publish them. Preloaded once, non-blocking (a 10s timeout, never
  // throws) — pickers fall back to the live endpoint + local defaults.
  await remoteCatalogEnrichment.preload(client: sharedProviderHttpClient());

  // Remote provider catalog (fa1.dev/models-catalog.json): default model
  // ids and per-provider context-window tables for endpoints that don't
  // publish them. Preloaded once, non-blocking (a 10s timeout, never
  // throws) — pickers fall back to the live endpoint + local defaults.
  await remoteCatalogEnrichment.preload(client: sharedProviderHttpClient());

  // Platform secure storage (macOS Keychain / Secret Service / Windows
  // Credential Locker): backs up every provider key the environment does
  // not set. Reads are process spawns, so the store is preloaded once into
  // a synchronous session cache — every later lookup (startup resolution,
  // the banner, `/provider`, `/key`) hits the snapshot.
  final keyCache = SecureKeyCache(platformSecureKeyStore());
  await keyCache.preload({
    for (final spec in providerCatalog.values) ...[
      ...spec.apiKeyEnvNames,
      // Endpoint-scoped keys (FA_KEY_<HOST>): catalog defaults, the
      // configured endpoint, and every saved custom provider's.
      CustomProviderRegistry.keyNameFor(spec.defaultBaseUrl),
    ],
    if (baseUrl case final url?) CustomProviderRegistry.keyNameFor(url),
    for (final entry in saved.customProviders)
      entry.keyName ?? CustomProviderRegistry.keyNameFor(entry.baseUrl),
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
    // FA_PROVIDER_* preconfig = one explicit provider switch for the whole
    // session: pin the default role to a single-entry chain on the env
    // provider — the same setDefaultChain + applyToAgent path a runtime
    // `/provider <name>` switch takes in roles mode. Roles the config
    // pins explicitly keep their chains; unpinned roles inherit the
    // default, so every resolution (default/smol/slow/plan) lands on the
    // env provider. A keyless declaration cannot form a chain entry
    // (chains require a key) — roles keep owning selection there, and
    // the boot note says so.
    if (faPreconfig case final preconfig? when preconfig.apiKeyEnvVar != null) {
      rolesResolver.addSecret(preconfig.apiKeyEnvVar!, preconfig.apiKey);
      rolesResolver.setDefaultChain([
        ModelRef(
          provider: preconfig.spec.name,
          modelId: preconfig.modelId,
          baseUrl: preconfig.baseUrl,
          apiKeyName: preconfig.apiKeyEnvVar,
        ),
      ]);
    }
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
  // Saved custom entries for this endpoint carry name-scoped keys
  // (multi-account); they resolve right after the host-scoped slot.
  final entryKeyNames = [
    for (final entry in saved.customProviders)
      if (entry.baseUrl == baseUrl && entry.keyName != null) entry.keyName!,
  ];
  // The FA_PROVIDER_* declaration carries its own key resolution (the
  // apiKeyEnvVar ref, or its _BASE64 twin): the env value IS the source
  // of truth for the booted session — store and config never override
  // it. Empty means a keyless endpoint (no ref declared — the spec's env
  // names are never probed).
  final apiKey = faPreconfig != null
      ? faPreconfig.apiKey
      : defaultRoleResolved || customEndpoint || interactive
      ? (optionalProviderApiKey(
              provider,
              keyCache,
              baseUrl: baseUrl,
              scopedKeyNames: entryKeyNames,
            ) ??
            '')
      : _resolveApiKey(
          provider,
          keyCache,
          baseUrl: baseUrl,
          scopedKeyNames: entryKeyNames,
        );

  // Redact the API keys this CLI knows about from tool results and the
  // provider context, so they cannot leak into the LLM conversation or the
  // session files. The spawned shell already inherits the process
  // environment, so no env injection is needed here.
  final redactor = SecretRedactor();
  for (final name in [
    ..._allCatalogEnvNames(),
    'BRAVE_API_KEY',
    'TAVILY_API_KEY',
  ]) {
    final value = Platform.environment[name];
    if (value != null) redactor.register(name, value);
  }
  // The FA_PROVIDER_* key ref may name ANY env var (not one of the well-known
  // names above) — redact it under its own name so the ref'd value can never
  // reach the transcript. A keyless declaration (no ref) carries no secret.
  if (faPreconfig case final preconfig? when preconfig.apiKey.isNotEmpty) {
    redactor.register(preconfig.apiKeyEnvVar!, preconfig.apiKey);
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
  // The one boot notice for env preconfig (same channel as the raw-mode
  // note below): names the provider and the env var that activated it,
  // never the key value.
  if (envPreconfig case (final picked, final envName)?) {
    io.writeln(
      'note: ${picked.name} activated from $envName '
      '(model ${catalogDefaultModelId(picked.name)})',
    );
  }
  // The FA_PROVIDER_* notice: names the declaration (type, resolved name,
  // key ref — or its keyless absence) — never the key value. The pinned
  // declaration is the session default for every model role; only a
  // keyless declaration under an active roles: section (which cannot pin
  // a chain) stays fallback-only, and the note says so.
  if (faPreconfig case final preconfig?) {
    io.writeln(
      'note: provider ${preconfig.name} (${preconfig.spec.name}) '
      'from FA_PROVIDER_* env — key: '
      '${preconfig.apiKeyEnvVar ?? 'none (keyless endpoint)'}',
    );
    if (defaultRoleResolved) {
      io.writeln(
        preconfig.apiKeyEnvVar == null
            ? 'note: FA_PROVIDER_* preconfig applies to the fallback model '
                  'only (roles: section is active; a keyless declaration '
                  'cannot pin a roles chain)'
            : 'note: FA_PROVIDER_* preconfig is the session default — all '
                  'model roles resolve to it unless roles: pins a chain',
      );
    }
  }
  if (io.isInteractive && !io.supportsRawMode) {
    io.writeln(
      'note: this terminal does not support raw-mode input; '
      'interactive slash/model menus are unavailable.',
    );
  }

  // `fa serve --a2a [--port N] [--token T]` — mount this agent as an A2A
  // endpoint (Phase 5b). Uses the fully-resolved model/key/provider.
  if (isServeA2a) {
    final port = _serveFlagInt(args, '--port', 8300);
    final token = _serveFlagStr(args, '--token');
    await _serveA2a(
      model: model,
      provider: provider,
      apiKey: apiKey,
      port: port,
      token: token,
    );
    exit(0);
  }
  // `late` so the onProviderChanged closure can reach the agent (to attach
  // the secret redactor on a runtime token) before the variable is assigned.
  late final AgentCli cli;
  // The live third-party skills consent (`skills:` config section): the
  // startup dialog and `/skills access` change it — persisted via
  // persistConfig.
  var skillsAccess = saved.skillsAccess;
  // The execution env shared by the CLI config (tools, session storage)
  // and the presence store (live-session heartbeats).
  late final LocalExecutionEnv cliEnv;
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
      // Shared by the env config and the presence store below.
      env: (cliEnv = LocalExecutionEnv(cwd: cwd)),
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
      // Saved custom providers (`customProviders:` config section): the
      // picker lists them first, the wizard appends, /model rewrites the
      // active entry's last-used model — all persisted via persistConfig.
      customProviders: CustomProviderRegistry(saved.customProviders),
      sessionRoot: sessionRoot,
      // Live-session presence: the running CLI heartbeats its session so
      // the Fa app (sharing the sessions root on macOS) marks it live and
      // can attach. Null where the root is process-local (tests).
      presenceStore: FileSessionPresenceStore(env: cliEnv, root: sessionRoot),
      processId: pid,
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
      // MCP servers (`mcp:` config section): the io-side factory spawns
      // stdio servers; remote (HTTP) servers work everywhere. Servers
      // connect in the background and register mcp__<server>__<tool> tools.
      mcpConfig: saved.mcp == null
          ? null
          : McpToolConfig(
              config: saved.mcp!,
              transportFactory: ioMcpTransportFactory,
            ),
      // A2A remote agents (`a2a:` config section, Phase 5a): pure-Dart HTTP
      // client, connects lazily per server.
      a2aConfig: saved.a2a,
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
      // The live models config (`models:` section): `/models set`/`remove`
      // mutate its media slot overrides and `/model <name>` resolves its
      // custom model definitions — persisted via persistConfig. An absent
      // section starts as an empty config so the commands always work.
      modelsConfig: saved.models ?? ModelsConfig(),
      onModelsConfigChanged: () async => persistConfig(),
      homeDir: home,
      // TTSR stream rules: user config (~/.fah/config.yaml `ttsr:`) merged
      // with project rules (.fah/rules.yaml), project first.
      ttsr: _resolveTtsr(saved, cwd),
      memoryConfig: saved.memory,
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
      // `request_secret` tool granted a secret: same redactor lazy attach.
      onSecretGranted: (name, value) {
        redactor.register(name, value);
        if (!redactorAttached && !redactor.isEmpty) {
          attachSecretRedactor(cli.agent, redactor);
          redactorAttached = true;
        }
      },
      onModeChanged: (_) async => persistConfig(),
      onApprovalChanged: () async => persistConfig(),
      // Third-party skills consent (`skills:` config section): the startup
      // dialog and `/skills access` set it; shell `!`cmd`` injections in
      // skill bodies follow `disableShellExecution`.
      skillsAccess: saved.skillsAccess,
      skillsDisableShellExecution: saved.skillsDisableShellExecution,
      onSkillsAccessChanged: (access) async {
        skillsAccess = access;
        await persistConfig();
      },
      // Shift+Enter in the TUI: terminals that do not encode the modifier
      // still expose it through the HID state (macOS only; null elsewhere).
      isShiftPressed: Platform.isMacOS ? _isShiftPressed : null,
      // Mouse capture is ON by default (wheel scrolls the session view —
      // in the alternate screen the terminal has no native scrollback, so
      // without capture two-finger scroll does nothing). FA_TUI_MOUSE=0
      // opts out for always-on native select-to-copy.
      tuiMouseCapture: _envNotFalsy('FA_TUI_MOUSE'),
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
        // Roles: the live resolver's config (a `/model` switch re-pins the
        // default chain, the settings-hub agent-models flow pins the
        // smol/subagent chains — possibly creating the resolver on demand).
        modelRoles: cli.config.modelRolesResolver?.config ?? saved.modelRoles,
        // TTSR rules are static per session; keep the loaded config so
        // saving doesn't drop the section.
        ttsr: saved.ttsr,
        // Saved custom providers (the live registry the CLI mutates).
        customProviders:
            cli.config.customProviders?.entries ?? saved.customProviders,
        // Models config (the live instance `/models set`/`remove` mutates).
        models: cli.config.modelsConfig ?? saved.models,
        // MCP servers (the live config — re-read on `/mcp reload`).
        mcp: cli.config.mcpConfig?.config ?? saved.mcp,
        // Third-party skills consent (mutable via the startup dialog and
        // `/skills access`); shell-execution policy is static per session.
        skillsAccess: skillsAccess,
        skillsDisableShellExecution: saved.skillsDisableShellExecution,
      ),
    );
  };

  await persistConfig();

  Future<void> resetTerminalForShell() async {
    if (!stdin.hasTerminal) return;
    stdout.write('\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l');
    stdout.write('\x1b[?1004l\x1b[?2004l');
    stdout.write('\x1b[?25h\x1b[?1049l');
    await stdout.flush();
    // Drain any pending terminal query/mouse responses so they don't echo
    // as garbage at the shell prompt.
    try {
      final drain = stdin.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await drain.cancel();
    } on Object {
      // Nothing to drain.
    }
  }

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    final wasBusy = cli.isBusy;
    switch (sigintAction(headless: headlessPrompt != null)) {
      case SigintAction.exitInteractive:
        // Ctrl+C exits exactly like /exit: abort any in-flight run first
        // (bounded — a stuck provider cannot wedge the exit), let the
        // partial transcript persist, then print the resume hint. Esc
        // inside the TUI stays the abort-without-exit key.
        io.resetRawMode();
        stdout.writeln();
        unawaited(
          Future(() async {
            // Restore terminal modes (mouse tracking off, alt-screen exit,
            // cursor show) BEFORE exit(130) — otherwise the shell prompt
            // inherits mouse reporting and wheel scrolls print escapes.
            await resetTerminalForShell();
            if (wasBusy) {
              io.fireInterrupt();
              await cli.waitForIdle();
            }
            await cli.deleteSessionIfEmpty();
            // Real stdout, not io: the TUI is being torn down by this very
            // exit — an io-routed line would land in a dead transcript.
            final hint = await cli.sessionResumeHint();
            if (hint != null) stdout.writeln(hint);
          }).whenComplete(() => exit(130)),
        );
      case SigintAction.exitHeadless:
        // Headless: no cosmetic newline on stdout so a pipe never sees it.
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

  // dart_tui's shutdown writes the reset sequences (?25h ?1049l ?1002l etc.)
  // and flushes stdout, but on some terminals the mouse-tracking disable
  // (?1002l ?1006l) arrives too late or is lost. Write them again here with
  await resetTerminalForShell();
  exit(0);
}
