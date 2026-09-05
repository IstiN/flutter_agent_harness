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
import 'dart:typed_data';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/trajectory_tui.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:yaml/yaml.dart' as yaml;
// The ONLY place the core CLI imports the hub client package: downstream
// forks that want a different or no hub client patch this import and the
// 'hub' case in `_builtInPlugin`.
import 'package:fa_hub_client/fa_hub_client.dart'
    show
        HubConfig,
        HubPlugin,
        defaultDapConfigFile,
        persistDapConfig,
        resolveDapSettings;
import 'fah_hub_plugin.dart';
import 'self_manage.dart';
import 'serve_a2a.dart';
import 'serve_bridge.dart';

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

/// Resolved once at first use; null when CoreGraphics is unavailable
/// (non-macOS hosts — the dylib path simply fails to open).
final int Function(int)? _cgEventSourceFlagsState =
    _lookupCGEventSourceFlagsState();

int Function(int)? _lookupCGEventSourceFlagsState() {
  try {
    final coreGraphics = ffi.DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    return coreGraphics.lookupFunction<
      _CGEventSourceFlagsStateC,
      _CGEventSourceFlagsStateDart
    >('CGEventSourceFlagsState');
  } on Object {
    return null;
  }
}

bool _isShiftPressed() {
  final fn = _cgEventSourceFlagsState;
  if (fn == null) return false;
  const kCGEventSourceStateHIDSystemState = 1;
  const kCGEventFlagMaskShift = 0x00020000;
  return fn(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskShift != 0;
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

/// Built-in plugins available via `--plugin <name>` or `.fah/packages.yaml`.
/// [hubPlugin] is the process's single hub client instance — the same one
/// the settings-hub DAP / Hub flow reads its snapshot through.
FahPlugin? _builtInPlugin(String name, HubPlugin hubPlugin) {
  return switch (name) {
    'hub' => HubPluginHost(hubPlugin),
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
/// failure is a hard startup error.
Future<({List<FahPlugin> plugins, Map<String, dynamic> config})>
_resolvePlugins(CliArgs args, ExecutionEnv env, HubPlugin hubPlugin) async {
  final Map<String, dynamic> config;
  try {
    config = await loadPackagesConfig(env);
  } on ConfigException catch (error) {
    _fail(error.message);
  }
  final enabled = resolveEnabledPlugins(args.plugins, config);
  final plugins = <FahPlugin>[];
  for (final name in enabled) {
    final plugin = _builtInPlugin(name, hubPlugin);
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

/// `fa trajectory <verb> [args]` — read-only trajectory views over a
/// stored session (phase 9). Runs without booting the agent: opens the
/// session store, resolves the session (id / name match / most recent),
/// projects the active branch, and prints through the pure renderers in
/// `trajectory_tui.dart`. Payload goes to stdout, diagnostics to stderr.
/// `tail` re-opens the session file on every poll until interrupted.
Future<int> _runTrajectoryCommand(
  TrajectoryCliCommand command,
  CliArgs args,
) async {
  final io = _TerminalCliIO(headless: true);
  final env = LocalExecutionEnv(cwd: args.cwd ?? Directory.current.path);
  final sessionRoot = args.sessionRoot ?? _defaultSessionRoot();
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
  final sessionId = switch (command.verb) {
    'inspect' when command.positionals.length > 1 => command.positionals[1],
    'inspect' => null,
    _ => command.positionals.isEmpty ? null : command.positionals.first,
  };
  final session = await resolveTrajectorySession(repo, sessionId);
  if (session == null) {
    io.writeln(
      sessionId == null
          ? 'trajectory: no sessions in $sessionRoot'
          : 'trajectory: session not found: $sessionId',
    );
    return 1;
  }
  final records = await session.getBranch();
  switch (command.verb) {
    case 'view':
      final snapshot = command.at == null
          ? trajectorySnapshotOf(records)
          : trajectorySnapshotAt(records, command.at!);
      if (snapshot == null) {
        io.writeln(
          trajectoryRangeError(
            command.at!,
            trajectorySnapshotOf(records).records.length,
          ),
        );
        return 1;
      }
      return _printTrajectory(
        io,
        command.json
            ? [
                for (final record in snapshot.records)
                  trajectoryJsonLine(record),
              ]
            : trajectoryLines(snapshot, width: io.columns),
      );
    case 'cost':
      return _printTrajectory(
        io,
        trajectoryCostLines(trajectorySnapshotOf(records)),
      );
    case 'inspect':
      final snapshot = trajectorySnapshotOf(records);
      final index = int.parse(command.positionals.first);
      final lines = trajectoryInspectLines(snapshot, index);
      if (lines == null) {
        io.writeln(trajectoryRangeError(index, snapshot.records.length));
        return 1;
      }
      return _printTrajectory(
        io,
        command.json && snapshot.records.isNotEmpty
            ? [trajectoryJsonLine(snapshot.records[index - 1])]
            : lines,
      );
    case 'tail':
      io.writeln('trajectory: following records — Ctrl+C to stop');
      final tailer = TrajectoryTailer(width: io.columns);
      final metadata = await session.getMetadata();
      for (final line in tailer.tail(records)) {
        io.write('$line\n');
      }
      while (true) {
        await Future<void>.delayed(trajectoryPollInterval);
        final List<SessionRecord> fresh;
        try {
          fresh = await (await repo.open(metadata)).getBranch();
        } on Object catch (error) {
          io.writeln('trajectory: tail failed: $error');
          return 1;
        }
        for (final line in tailer.tail(fresh)) {
          io.write('$line\n');
        }
      }
  }
  return 0;
}

/// Prints trajectory payload lines to stdout (newline-terminated).
int _printTrajectory(CliIO io, List<String> lines) {
  for (final line in lines) {
    io.write('$line\n');
  }
  return 0;
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

/// The messaging fabric of the launch cwd — the same
/// `<sessionRoot>/<cwd slug>/messages` root the CLI boots its agent with,
/// so extension mail lands in the inboxes `/agents` and the attach flows
/// already see.
FileMessagingRepository _projectMessagingRepository({
  required LocalExecutionEnv env,
  required String sessionRoot,
  required String? homeDir,
}) => FileMessagingRepository(
  env: env,
  root: '$sessionRoot/${encodeSessionCwd(env.cwd)}/messages',
  decodeSessionCwd: decodeSessionCwd,
  homeDir: homeDir,
);

/// `/browser connect` handle: runs the bridge server inside this process
/// over the launch-cwd messaging fabric (the DIP adapter — lib/ stays
/// dart:io-free).
final class _FaBrowserBridgeHandle implements BrowserBridgeHandle {
  _FaBrowserBridgeHandle({
    required LocalExecutionEnv env,
    required String sessionRoot,
    required String homeDir,
    required String faVersion,
  }) : _messaging = _projectMessagingRepository(
         env: env,
         sessionRoot: sessionRoot,
         homeDir: homeDir,
       ),
       _projectRoot = env.cwd,
       _version = faVersion;

  final MessagingRepository _messaging;
  final String _projectRoot;
  final String _version;
  BridgeServer? _server;
  _FaBrowserController? _controller;
  var _attached = false;

  /// The browser-tools controller seam over this handle's bridge server.
  BrowserController get browserController =>
      _controller ??= _FaBrowserController(this);

  /// Whether a PAIRED extension is connected (mailbox registered —
  /// mid-handshake sockets don't count).
  bool get hasPairedClient => (_server?.clients ?? const <BridgeConnection>[])
      .any((client) => client.mailboxId != null);

  /// The MOST RECENT paired connection (insertion order; with several
  /// paired extensions the newest handshake wins — a deliberate silent
  /// choice, see [_FaBrowserController] docs).
  BridgeConnection? get _activeClient {
    final clients = _server?.clients ?? const <BridgeConnection>[];
    if (clients.isEmpty) return null;
    return clients.lastWhere(
      (client) => client.mailboxId != null,
      orElse: () => clients.last,
    );
  }

  /// Connect/disconnect seam: forwards the paired-client truth value to
  /// the controller's availability hook on flips only.
  void _onClientsChanged() {
    final attached = hasPairedClient;
    if (attached == _attached) return;
    _attached = attached;
    _controller?.onAvailabilityChanged?.call(attached);
  }

  @override
  Future<BrowserBridgeSession> connect({int port = bridgeDefaultPort}) async {
    final existing = _server;
    if (existing != null && existing.running) {
      return BrowserBridgeSession(
        url: existing.url,
        token: existing.mintToken(),
        alreadyRunning: true,
      );
    }
    final token = await BridgeTokenFile(_projectRoot).ensure();
    final server = BridgeServer(
      messaging: _messaging,
      root: _projectRoot,
      port: port,
      token: token,
      version: _version,
      onClientsChanged: _onClientsChanged,
    );
    await server.start();
    _server = server;
    return BrowserBridgeSession(
      url: server.url,
      token: server.mintToken(),
      alreadyRunning: false,
    );
  }

  @override
  Future<BrowserBridgeStatus> status() async {
    final server = _server;
    final mailboxes = await _messaging.directory();
    return BrowserBridgeStatus(
      running: server?.running ?? false,
      url: (server?.running ?? false) ? server!.url : null,
      extensions: [
        for (final client in server?.clients ?? const <BridgeConnection>[])
          ?client.mailboxId,
      ],
      mailboxes: [
        for (final mailbox in mailboxes) (id: mailbox.id, cwd: mailbox.cwd),
      ],
    );
  }
}

/// The [BrowserController] over this process' bridge server: every op
/// dispatches to the most recent PAIRED extension (deterministic: newest
/// handshake wins; a deliberate silent choice — several paired extensions
/// are not a supported steering surface, restart the bridge to reset).
/// No paired extension: every op fails fast with `no_target`. Dispatch
/// errors and timeouts surface as [BrowserToolException] with the wire
/// code intact.
final class _FaBrowserController implements BrowserController {
  _FaBrowserController(this._handle);

  final _FaBrowserBridgeHandle _handle;

  @override
  void Function(bool attached)? onAvailabilityChanged;

  @override
  bool get attached => _handle.hasPairedClient;

  Future<Map<String, dynamic>> _dispatch(
    String op,
    Map<String, dynamic> args,
  ) async {
    final connection = _handle._activeClient;
    if (connection == null) {
      throw BrowserToolException(
        'no_target',
        'no browser extension connected — run /browser connect and pair',
      );
    }
    final result = await connection.dispatch(op, args);
    if (result['ok'] == true) {
      return result['result'] as Map<String, dynamic>? ?? const {};
    }
    throw BrowserToolException(
      result['code'] as String? ?? 'no_target',
      result['error'] as String? ?? 'browser op failed',
    );
  }

  @override
  Future<BrowserNavigation> navigate(String url, {int? tabId}) async {
    final r = await _dispatch('navigate', {'url': url, 'tabId': ?tabId});
    return (
      tabId: r['tabId'] as int,
      url: r['url'] as String,
      title: r['title'] as String? ?? '',
    );
  }

  @override
  Future<List<BrowserTab>> listTabs() async {
    final r = await _dispatch('tabs', const {});
    return [
      for (final tab in (r['tabs'] as List? ?? const []).cast<Map>())
        (
          id: tab['id'] as int,
          url: tab['url'] as String? ?? '',
          title: tab['title'] as String? ?? '',
          active: tab['active'] as bool? ?? false,
          groupId: tab['groupId'] as int?,
        ),
    ];
  }

  @override
  Future<void> switchTab(int tabId) =>
      _dispatch('switch_tab', {'tabId': tabId});

  @override
  Future<void> click(String selector, {int? tabId}) =>
      _dispatch('click', {'selector': selector, 'tabId': ?tabId});

  @override
  Future<void> type(
    String selector,
    String text, {
    bool submit = false,
    int? tabId,
  }) => _dispatch('type', {
    'selector': selector,
    'text': text,
    if (submit) 'submit': true,
    'tabId': ?tabId,
  });

  @override
  Future<void> pressKey(String key, {String? selector, int? tabId}) =>
      _dispatch('press_key', {
        'key': key,
        'selector': ?selector,
        'tabId': ?tabId,
      });

  @override
  Future<void> select(String selector, String value, {int? tabId}) => _dispatch(
    'select',
    {'selector': selector, 'value': value, 'tabId': ?tabId},
  );

  @override
  Future<BrowserDom> readDom({
    String? selector,
    int? maxNodes,
    bool includeShadow = false,
    int? tabId,
  }) async {
    final r = await _dispatch('read_dom', {
      'selector': ?selector,
      'maxNodes': ?maxNodes,
      if (includeShadow) 'includeShadow': true,
      'tabId': ?tabId,
    });
    return (
      dom: r['dom'] as String? ?? '',
      nodeCount: r['nodeCount'] as int? ?? 0,
      truncated: r['truncated'] as bool? ?? false,
    );
  }

  @override
  Future<Object?> evalCode(String code, {int? tabId}) async {
    final r = await _dispatch('eval', {'code': code, 'tabId': ?tabId});
    return r['result'];
  }

  @override
  Future<Uint8List> screenshot({int? tabId}) async {
    final r = await _dispatch('screenshot', {'tabId': ?tabId});
    return base64Decode(r['pngBase64'] as String);
  }

  @override
  Future<BrowserWaitResult> waitFor({
    String? selector,
    String? text,
    required int timeoutMs,
    int? tabId,
  }) async {
    final r = await _dispatch('wait_for', {
      'selector': ?selector,
      'text': ?text,
      'timeoutMs': timeoutMs,
      'tabId': ?tabId,
    });
    return (
      found: r['found'] as bool? ?? true,
      waitedMs: r['waitedMs'] as int? ?? 0,
    );
  }

  @override
  Future<void> taskEnd() => _dispatch('task_end', const {});
}

Future<void> _runApp(List<String> args) async {
  final packageVersion = _packageVersion();
  _applyProviderFilterEnv();
  // `fa serve [--a2a|--bridge] [--port N] [--token T]` — the parser does
  // not know the serve forms, so they are intercepted before CliArgs
  // parsing: serve-specific flags are stripped from the parsed args and
  // kept for the late interception below (after model/key resolution).
  final serve = splitServeA2aArgs(args);
  final serveMarkerCount =
      (serve.serveA2a ? 1 : 0) + (serve.serveBridge ? 1 : 0);
  if (serveMarkerCount != 1 && args.contains('serve')) {
    _fail(
      'usage: fa serve --a2a [--port N] [--token T] | '
      'fa serve --bridge [--port N] [--token T]',
    );
  }

  late final CliArgs parsed;
  try {
    parsed = switch (parseCliArgs(serve.cliArgs)) {
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
  // `fa trajectory <verb> [sessionId] [--json] [--at N]` — read-only
  // trajectory views over a stored session; intercepted before prompt
  // resolution so the verb words never become a prompt.
  final trajectory = parsed.trajectory;
  if (trajectory != null) {
    exit(await _runTrajectoryCommand(trajectory, parsed));
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

  late final ({
    CliArgs args,
    String provider,
    EnvProviderPreconfig? faPreconfig,
  })
  cliStartup;
  try {
    cliStartup = resolveEffectiveCliArgs(parsed, saved);
  } on ConfigException catch (error) {
    _fail(error.message);
  }
  final effective = cliStartup.args;
  var provider = cliStartup.provider;
  final faPreconfig = cliStartup.faPreconfig;

  final cwd = effective.cwd ?? Directory.current.path;
  final sessionRoot = effective.sessionRoot ?? _defaultSessionRoot();
  // The execution env shared by the CLI config (tools, session storage),
  // the presence store (live-session heartbeats) and the per-folder model
  // state IO. Mutable cwd: a resumed session re-points it (see _loadSession).
  final cliEnv = LocalExecutionEnv(cwd: cwd);

  // Per-folder model memory: restore the model/provider triple last used
  // in THIS folder — a `/model` switch in another workspace must not leak
  // in across restarts. Explicit per-launch declarations win: --model,
  // --provider, --base-url, or an FA_PROVIDER_* env preconfig.
  final folderState = await loadFolderModelState(
    cliEnv,
    sessionsRoot: sessionRoot,
    cwd: cwd,
  );
  final applyFolderState =
      folderState != null &&
      folderModelStateApplies(
        modelExplicit: parsed.model != null,
        providerExplicit: parsed.providerExplicit,
        baseUrlExplicit: parsed.baseUrl != null,
        hasProviderPreconfig: faPreconfig != null,
      );
  if (applyFolderState) {
    provider = folderState.providerKind;
  }
  final baseUrl = applyFolderState ? folderState.baseUrl : effective.baseUrl;

  final model = applyFolderState
      ? buildCliDefaultModel(
          provider,
          modelId: folderState.modelId,
          baseUrl: folderState.baseUrl,
        )
      : _buildModel(effective);

  // Initial cube (fa_cube Phase 1): --cube-config path > --cube name > the
  // project `.fah/config.yaml` `cube:` section > the saved user `cube:`
  // section (each config section only when enabled). A broken manifest is
  // a hard error — a requested cube must never fail open into an
  // unconfined run.
  String? cubeSource;
  CubeSpec? cubeSpec;
  try {
    cubeSource = resolveStartupCubeSource(
      flagConfigPath: parsed.cubeConfigPath,
      flagName: parsed.cubeName,
      project: loadProjectCubeSettings(cwd),
      user: saved.cube,
    );
    final isPath = cubeSource?.contains('/') ?? false;
    cubeSpec = await CubeResolver.resolve(
      env: cliEnv,
      path: isPath ? cubeSource : null,
      name: isPath ? null : cubeSource,
      homeDir: home,
    );
  } on ConfigException catch (error) {
    _fail(error.message);
  }

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
  await keyCache.preload(secureKeyPreloadNames(saved, baseUrl: baseUrl));

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
      : collectRoleSecrets(rolesConfig, keyCache);
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
  late final String apiKey;
  try {
    // The FA_PROVIDER_* declaration carries its own key resolution (the
    // apiKeyEnvVar ref, or its _BASE64 twin): the env value IS the source
    // of truth for the booted session — store and config never override
    // it. Empty means a keyless endpoint (no ref declared — the spec's
    // env names are never probed).
    apiKey = faPreconfig != null
        ? faPreconfig.apiKey
        : startupApiKey(
            provider,
            keyCache,
            baseUrl: baseUrl,
            customProviders: saved.customProviders,
            defaultRoleResolved: defaultRoleResolved,
            interactive: headlessPrompt == null,
          );
  } on ConfigException catch (error) {
    _fail(error.message);
  }

  // Redact the API keys this CLI knows about from tool results and the
  // provider context, so they cannot leak into the LLM conversation or the
  // session files (assembled by [buildSecretRedactor]).
  // The layered redaction pipeline (issue #24): assembled from the
  // `redact:` config (null = defaults) BEFORE the secret redactor so the
  // redactor's dual registration feeds the pipeline's registered layer.
  final redactionPipeline = buildRedactionPipeline(effective.redact);
  final redactor = buildSecretRedactor(
    roleSecrets: roleSecrets,
    keys: keyCache,
    pipeline: redactionPipeline,
  );
  // The FA_PROVIDER_* key ref may name ANY env var (not one of the
  // well-known catalog names) — redact it under its own name so the ref'd
  // value can never reach the transcript. A keyless declaration (no ref)
  // carries no secret.
  if (faPreconfig case final preconfig? when preconfig.apiKey.isNotEmpty) {
    redactor.register(preconfig.apiKeyEnvVar!, preconfig.apiKey);
    redactionPipeline?.registerSecret(preconfig.apiKey);
  }
  // Whether the redactor is attached to the agent. A keyless startup leaves
  // it detached; a `/provider` token arriving at runtime attaches it then.
  var redactorAttached = !redactor.isEmpty;

  final webSearch = webSearchSecrets();

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

  // The process's single hub client instance: registered as the `hub`
  // plugin when enabled, and read by the settings-hub DAP / Hub flow's
  // snapshot seam below. Constructing it has no side effects — the client
  // connects only in `start()` (driven by the plugin host).
  final hubPlugin = HubPlugin();
  final resolved = await _resolvePlugins(effective, cliEnv, hubPlugin);

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
  if (serve.serveA2a) {
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
  // `fa serve --bridge [--port N] [--token T]` — mount the loopback
  // browser bridge over this project's messaging fabric. The token comes
  // from --token or `.fah/bridge/token` (mint-if-absent, mode 0600).
  if (serve.serveBridge) {
    final port = _serveFlagInt(args, '--port', bridgeDefaultPort);
    final tokenFlag = _serveFlagStr(args, '--token');
    await runBridgeServer(
      messaging: _projectMessagingRepository(
        env: cliEnv,
        sessionRoot: sessionRoot,
        homeDir: home,
      ),
      root: cwd,
      port: port,
      token: tokenFlag,
      version: packageVersion,
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
  // The RUNTIME `tools:` availability scope: the `--tools` flag wins over
  // the `FA_TOOLS` env twin (the flag is already parsed into
  // effective.tools). A malformed env spec is a hard startup error — a
  // typo must never silently enable a tool the user meant to disable.
  ToolsConfig? runtimeTools;
  try {
    final flagTools = effective.tools;
    runtimeTools = flagTools != null && !flagTools.isEmpty
        ? flagTools
        : toolsSpecFromEnv(Platform.environment);
  } on ConfigException catch (error) {
    _fail('invalid --tools/FA_TOOLS spec: ${error.message}');
  }

  // Per-folder model memory: mirror the active triple into the folder's
  // state file (the LIVE cwd — a resumed session re-points `cliEnv.cwd`),
  // so the next `fa` in that folder restores this model, not the global
  // last-switch. Declared before `cli` because the model/provider change
  // callbacks below call it; `cli` is `late final` and only reached from
  // the closures after the assignment.
  Future<void> persistFolderModelState() async {
    await saveFolderModelState(
      cliEnv,
      sessionsRoot: sessionRoot,
      cwd: cliEnv.cwd,
      providerKind: cli.providerKind,
      modelId: cli.agent.state.model.id,
      baseUrl: cli.agent.state.model.baseUrl,
    );
  }

  // The loopback browser-bridge handle: shared by `/browser connect` and
  // the browser tools' controller (the controller resolves lazily).
  final bridgeHandle = _FaBrowserBridgeHandle(
    env: cliEnv,
    sessionRoot: sessionRoot,
    homeDir: home,
    faVersion: packageVersion,
  );

  // The execution env shared by the CLI config (tools, session storage)
  // and the presence store (live-session heartbeats) — see `cliEnv` above.
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
      redactionPipeline: redactionPipeline,
      // Shared by the env config and the presence store below.
      env: cliEnv,
      // fa_cube sandbox profile (Phase 1): clamps fs + shell ops to the
      // cube's policies; `/cube` inspects and switches it live. The OS
      // name feeds the backend description (lib/src stays dart:io-free).
      cubeSpec: cubeSpec,
      cubeSource: cubeSource,
      osName: Platform.operatingSystem,
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
      // The same launch-pin rule the boot restore used: explicit
      // --model/--provider/--base-url or an FA_PROVIDER_* preconfig wins
      // over per-folder memory, including later session switches.
      folderModelStateApplies: applyFolderState || folderState == null,
      // Live-session presence: the running CLI heartbeats its session so
      // the Fa app (sharing the sessions root on macOS) marks it live and
      // can attach. Null where the root is process-local (tests).
      presenceStore: FileSessionPresenceStore(env: cliEnv, root: sessionRoot),
      processId: pid,
      sessionName: effective.session,
      visionConfig: visionConfig,
      transcribeConfig: transcribeConfig,
      webSearchConfig: WebSearchConfig(secrets: webSearch),
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
      // `/browser connect` + the browser tools' controller: one handle
      // owning the loopback bridge over the launch-cwd fabric (both
      // implemented above).
      browserBridgeHandle: bridgeHandle,
      browserController: bridgeHandle.browserController,
      plugins: resolved.plugins,
      pluginConfig: resolved.config,
      promptTemplateDirs: promptTemplateDirs,
      initialMode: effective.mode!,
      systemPrompt: flagSystemPrompt,
      promptOverrides: promptOverrides,
      approvalMode:
          approvalModeFromLabel(saved.approvalMode) ?? ApprovalMode.yolo,
      alwaysAllowTools: saved.allowedTools.toSet(),
      runtimeTools: runtimeTools,
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
      // Project-level .fah/config.yaml memory: wins over the user one.
      memoryConfig: loadProjectMemoryConfig(cwd) ?? saved.memory,
      // The saved cube default (the `cube:` section): the settings-hub
      // Cube sandbox flow rewrites it — persisted via persistConfig.
      cubeSettings: saved.cube,
      onCubeSettingsChanged: () async => persistConfig(),
      // DAP / Hub settings flow: the snapshot seam resolves the effective
      // config (env > `hub:` section > `~/.dap/config.json` > defaults)
      // through the hub client and overlays the live plugin status — local
      // reads only, never a network dial. A missing/failed probe keeps the
      // flow honest about the state.
      dapHubState: () async {
        // Single parse source: the same loaded packages.yaml map the
        // plugin system consumes (loadPackagesConfig already flattened
        // the yaml tree to plain Dart values).
        final hubSection = resolved.config['hub'];
        final settings = resolveDapSettings(
          config: HubConfig.fromMap(
            hubSection is Map<String, dynamic> ? hubSection : const {},
            Platform.environment,
          ),
          environment: Platform.environment,
        );
        try {
          final status = await hubPlugin.status();
          return DapHubSnapshot(
            supported: true,
            url: status.url ?? settings.url,
            name: status.name ?? settings.name,
            agentId: status.agentId,
            channels: status.channels,
            connected: status.connected,
          );
        } on Object {
          // The plugin never started (opted out, or the connect failed):
          // report the resolved config without a live connection.
          return DapHubSnapshot(
            supported: true,
            url: settings.url,
            name: settings.name,
            channels: const [],
            connected: false,
          );
        }
      },
      onDapHubConfigChanged: ({url, name}) =>
          persistDapConfig(url: url, name: name, file: defaultDapConfigFile()),
      onModelChanged: (_) async {
        await persistConfig();
        await persistFolderModelState();
      },
      // `/provider` switches: redact an explicitly passed session token so
      // it cannot leak into tool results or session files, then persist the
      // new provider/model/baseUrl triple (never the key itself).
      onProviderChanged: (kind, key) async {
        if (key.isNotEmpty) {
          redactor.register('/provider token', key);
          redactionPipeline?.registerSecret(key);
          // A keyless startup never attached the redactor; a runtime token
          // still gets masked from here on.
          if (!redactorAttached) {
            attachSecretRedactor(cli.agent, redactor);
            redactorAttached = true;
          }
        }
        await persistConfig();
        await persistFolderModelState();
      },
      // `/key set` stored a secret: mask it from here on (same lazy attach).
      onSecretStored: (name, value) {
        redactor.register(name, value);
        redactionPipeline?.registerSecret(value);
        if (!redactorAttached && !redactor.isEmpty) {
          attachSecretRedactor(cli.agent, redactor);
          redactorAttached = true;
        }
      },
      // `request_secret` tool granted a secret: same redactor lazy attach.
      onSecretGranted: (name, value) {
        redactor.register(name, value);
        redactionPipeline?.registerSecret(value);
        if (!redactorAttached && !redactor.isEmpty) {
          attachSecretRedactor(cli.agent, redactor);
          redactorAttached = true;
        }
      },
      onModeChanged: (_) async => persistConfig(),
      onApprovalChanged: () async => persistConfig(),
      // Global `tools:` toggles (`/tools <id> global`): the CLI owns the
      // live scope; persistConfig writes it back (see below).
      onToolsConfigChanged: () async => persistConfig(),
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
        // The provider/model triple is per-folder now (folder_model_state):
        // keep the LOADED seed in the global config so a `/model` or
        // `/provider` switch in one workspace never leaks into the others
        // across restarts — the switch persists through the folder's state
        // file instead, and explicit --model/--provider/--base-url still
        // win per launch.
        providerKind: saved.providerKind,
        modelId: saved.modelId,
        baseUrl: saved.baseUrl,
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
        // The saved cube default (the live value the Cube sandbox flow
        // rewrites; `saved.cube` keeps the section when nothing changed).
        cube: cli.config.cubeSettings ?? saved.cube,
        // The live global `tools:` scope (read at boot, updated by
        // `/tools <id> global`); null until the first availability
        // rebuild, in which case the loaded section is kept as-is
        // (project/runtime scopes stay live and are never persisted).
        tools: cli.globalTools ?? saved.tools,
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
