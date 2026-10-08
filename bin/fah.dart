/// The `fah` executable: a terminal coding agent on top of
/// `flutter_agent_harness`.
///
/// Usage:
///
/// ```sh
/// dart run bin/fah.dart [--model <id>] [--provider <kind>] [--base-url <url>]
///                       [--cwd <dir>] [--session-root <dir>]
/// dart run bin/fah.dart [options] "summarize the changelog"   # headless
/// dart run bin/fah.dart --prompt-file prompt.md               # from file
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
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http; // the auto-update probe client
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/boot_update.dart';
import 'package:flutter_agent_harness/src/cli/ext_cli.dart';
import 'package:flutter_agent_harness/src/cli/jsr_cli.dart';
import 'package:flutter_agent_harness/src/cli/session_tree.dart';
import 'package:flutter_agent_harness/src/cli/session_repair_command.dart';
import 'package:flutter_agent_harness/src/cli/tui_key_hints.dart';
import 'package:flutter_agent_harness/src/cli/trajectory_tui.dart';
import 'package:flutter_agent_harness/src/hub/hub_teardown_error.dart';
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
        envClientSecret,
        envMasterSecret,
        persistDapConfig,
        readDapConfig,
        resolveDapSettings;
import 'fah_dap_command.dart';
import 'fah_hub_plugin.dart';
import 'fah_hub_serve.dart';
import 'hub_fabric_repository.dart';
import 'package:flutter_agent_harness/src/hub/hub_boot_credential.dart';
import 'self_manage.dart';
import 'serve_a2a.dart';
import 'serve_bridge.dart';
import 'fah_boot_restore.dart';
import 'fah_wire_serve.dart';
import 'package:flutter_agent_harness/src/cli/provider_export.dart';

part 'fah_util.dart';
part 'fah_model.dart';
part 'fah_io.dart';
part 'fah_trajectory.dart';
part 'fah_runapp.dart';
part 'fah_wire_host.dart';

Future<void> main(List<String> args) async {
  // Provider forensics composition root (gh-1395 review round 1): the
  // pure barrel carries only the contracts; the io seams (env knob
  // lookup, [conn-trace] stderr lines, the observed dart:io client, the
  // sentinel's disk sink) install here — the ONE dart:io boundary.
  installProviderStallForensics();
  // Session segment rotation warnings (fa gh-1077): the session layer has
  // no console dependency — the CLI surfaces hard-cap truncations and
  // rotation fallbacks on stderr.
  JsonlSessionStorage.onRotationWarning = stderr.writeln;
  await runZoned(
    () => _runApp(args),
    zoneSpecification: ZoneSpecification(
      handleUncaughtError: (self, parent, zone, error, stackTrace) {
        // fa_hub_client can fail a LEAKED waiter (no listener left) with
        // StateError('connection closed') when the socket drops — e.g. a
        // flush() waiter abandoned after _send threw on a dead socket.
        // The error lands here as an unhandled async error no call-site
        // try/catch can reach; the fabric already fell back to files, so
        // log it and keep running instead of crashing the CLI.
        if (isHubConnectionTeardown(error)) {
          stderr.writeln(
            'fa: hub connection closed mid-operation — '
            'continuing on the file fabric',
          );
          return;
        }
        _handleUncaughtError(error, stackTrace);
      },
    ),
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

String _defaultSessionRoot() {
  final home = _homeDir();
  if (Platform.isMacOS) {
    // Share sessions with the app only when macOS materialized its App
    // Group container (i.e. the entitled app is installed). Probing must
    // NOT create the container ourselves: under a fake HOME (integration
    // tests) that would silently relocate the sessions they then read.
    final container = '$home/Library/Group Containers/group.dev.fa1.shared';
    final groupDir = '$container/fa/sessions';
    if (Directory(container).existsSync() && _isDirWritable(groupDir)) {
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

/// This host's machine name for `name@machine` addressing (issue #27
/// phase 2). Null when the platform cannot name the host — suffixed
/// addresses then never resolve locally.
String? _localMachineName() {
  try {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? null : name;
  } on Object {
    return null;
  }
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

/// Truthy env-var check for opt-in flags (`1`/`true`/`yes`/`on`).
bool _envTruthy(String name) {
  final value = Platform.environment[name]?.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes' || value == 'on';
}

/// Tri-state env-var check: `1/true/yes/on` → true, `0/false/no/off` →
/// false, unset or unrecognized (e.g. `auto`) → null. Strict sets — any
/// other garbage must not silently force the flag on.
bool? _envTristate(String name) {
  final raw = Platform.environment[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return null;
  const on = {'1', 'true', 'yes', 'on'};
  const off = {'0', 'false', 'no', 'off'};
  if (on.contains(raw)) return true;
  if (off.contains(raw)) return false;
  return null;
}

/// The executable used to wake asleep cross-session mailboxes: this
/// process's own path when it is a compiled snapshot, or null to fall back
/// to `fa` on PATH (a `dart run` VM cannot be re-spawned with session
/// args).
String? wakeExecutable() {
  final exe = Platform.script.toFilePath();
  final base = exe.split(Platform.pathSeparator).last.toLowerCase();
  if (base == 'dart' || base == 'dart.exe') return null;
  return exe;
}
