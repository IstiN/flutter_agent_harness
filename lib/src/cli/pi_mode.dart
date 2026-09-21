/// The pi benchmark mode (issue #679): `fa --pi` runs pi-mono's exact
/// benchmark configuration — a 4-tool surface (read, write, edit, bash),
/// a bare prompt profile, and honest token parity against the reference.
///
/// This module is the pure decision layer: mode resolution (flag > env >
/// config, card AC3) and the pi tool-availability override. The wiring
/// lives in the CLI host (`agent_cli_prompt.dart` for the bare prompt
/// composition, `agent_cli_tools.dart` for the runtime availability
/// scope); the executable resolves the mode in `bin/fah.dart`.
///
/// Pure Dart: no `dart:io`.
library;

import '../exceptions.dart';
import '../tools/availability.dart';

/// The pi benchmark tool surface (issue #679): exactly pi's four tools -
/// read, write, edit, bash (ls/grep live under bash in pi's benchmark
/// shape). Everything else - subagents, memory, web, messaging,
/// scheduling, checkpoint/rewind, lsp, generate_*, MCP, plugins - is off.
const piToolIds = <String>{'read', 'write', 'edit', 'bash'};

/// The `FA_PI_MODE=1` env twin of the `--pi` flag. The flag wins (AC3:
/// flag > env > config).
const piModeEnvVar = 'FA_PI_MODE';

/// Values accepted for the config `agent.mode` key. `omp` joins this set
/// with issue #680 (it shares the same settings slot).
const harnessModeValues = <String>{'default', 'pi'};

/// Truthy env values accepted for [piModeEnvVar] (mirrors the executable's
/// `_envTruthy` set; pure Dart so the resolver stays testable).
const _truthyEnvValues = {'1', 'true', 'yes', 'on'};

/// Resolves the active harness mode: `--pi` flag > `FA_PI_MODE` env >
/// config `agent.mode` (issue #679 AC3).
///
/// Returns `'pi'` when the pi benchmark mode is active, `null` for the
/// legacy default mode. [flag] is the parsed `--pi` flag (absent when the
/// caller has no argv access); [env] the process environment snapshot;
/// [configMode] the parsed `agent.mode` value (`null` when absent;
/// `'default'` is the explicit off). An unknown config value throws
/// [ConfigException] — a typo must never silently boot a benchmark run
/// with the wrong tool surface.
String? resolveHarnessMode({
  bool? flag,
  Map<String, String> env = const {},
  String? configMode,
}) {
  if (flag ?? false) return 'pi';
  final envValue = env[piModeEnvVar]?.trim().toLowerCase();
  if (envValue != null && _truthyEnvValues.contains(envValue)) return 'pi';
  if (configMode == null) return null;
  if (!harnessModeValues.contains(configMode)) {
    throw ConfigException(
      'unknown "agent.mode" value: $configMode '
      '(expected ${(harnessModeValues.toList()..sort()).join('|')})',
    );
  }
  return configMode == 'pi' ? 'pi' : null;
}

/// pi's runtime availability scope: every known tool id off except
/// [piToolIds]. Applied as the DEEPEST scope in `rebuildToolAvailability`,
/// so it pins the surface exactly — `--tools` and `FA_TOOLS` cannot widen
/// a benchmark run.
ToolsConfig piToolsOverride() => ToolsConfig(
  tools: {for (final id in knownToolIds) id: piToolIds.contains(id)},
);
