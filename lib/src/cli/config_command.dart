/// `fa config check|path|get|set` (issue #29 S3): headless read/write
/// access to the user + project config pair, on top of the pure
/// [ConfigService]. The fa-self-config skill drives these verbs instead
/// of hand-editing YAML, and the parity contract keeps every documented
/// verb working (see `test/skills/cli_parity_test.dart`).
///
/// All file access goes through [env]; output goes through [CliIO] so the
/// verbs are testable without a terminal.
library;

import '../config/config_service.dart';
import '../env/execution_env.dart';
import '../exceptions.dart';
import 'agent_cli.dart';
import 'cli_args.dart';

/// Runs one `fa config <verb>` command and returns the process exit code.
///
/// Exit codes: 0 success; 1 the command failed (invalid config, unknown
/// key, write refused) — the message is printed, nothing thrown, so a
/// scripting agent always gets a clean textual answer.
Future<int> runConfigServiceCommand(
  ConfigCliCommand cmd, {
  required CliIO io,
  required ExecutionEnv env,
  required String? homeDir,
}) async {
  final service = ConfigService(env: env, homeDir: homeDir);
  try {
    switch (cmd.verb) {
      case 'check':
        return await _check(service, io);
      case 'path':
        return await _path(service, io);
      case 'get':
        return await _get(service, io, cmd.key!);
      case 'set':
        return await _set(service, io, cmd.key!, cmd.value!, cmd.scope);
    }
  } on ConfigException catch (error) {
    io.writeln('error: ${error.message}');
    return 1;
  }
  // Unreachable: the parser admits exactly the four verbs above.
  return 1;
}

Future<int> _check(ConfigService service, CliIO io) async {
  final report = await service.check();
  for (final error in report.errors) {
    io.writeln('error: $error');
  }
  for (final warning in report.warnings) {
    io.writeln('warning: $warning');
  }
  for (final note in report.notes) {
    io.writeln('note: $note');
  }
  io.writeln(report.ok ? 'config check: ok' : 'config check: failed');
  return report.ok ? 0 : 1;
}

Future<int> _path(ConfigService service, CliIO io) async {
  for (final info in await service.paths()) {
    io.writeln('${info.label}: ${info.path}');
  }
  return 0;
}

Future<int> _get(ConfigService service, CliIO io, String key) async {
  final result = await service.get(key);
  if (!result.found) {
    io.writeln('not set: $key');
    return 1;
  }
  io.writeln(result.display ?? '');
  return 0;
}

Future<int> _set(
  ConfigService service,
  CliIO io,
  String key,
  String value,
  ConfigScope? scope,
) async {
  final result = await service.set(key, value, scope: scope);
  io.writeln(
    'set ${result.key} = ${result.newDisplay} '
    '(${result.scope}: ${result.file})',
  );
  return 0;
}
