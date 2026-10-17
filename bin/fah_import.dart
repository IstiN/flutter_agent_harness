part of 'fah.dart';

/// `fa import --harness=<omp|kimi|opencode|claude> (--all | --session=x)`
/// — cross-harness session import (issue #1562). Intercepted like
/// `trajectory`: no agent boot, zero provider/model/key wiring — the
/// imported content cannot trigger a model call during import (GOAL F8).
/// Opens the foreign store read-only, writes new FA sessions only.
Future<int> _runImportCommand(ImportCliCommand command, CliArgs args) async {
  final io = _TerminalCliIO(headless: true);
  final env = LocalExecutionEnv(cwd: args.cwd ?? Directory.current.path);
  final sessionRoot = args.sessionRoot ?? _defaultSessionRoot();
  final home = _homeDir();
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
  final adapter = adapterFor(command.harness);
  if (adapter == null) {
    // kimi/opencode: pinned surface, format pending the discovery spike
    // (GOAL AC7/K1) — the expected store path is named either way.
    stderr.writeln(
      'import: harness "${command.harness}" is not importable yet — '
      'its format is pending the discovery spike '
      '(expected store: ${expectedStoreRoot(command.harness, home)})',
    );
    return 2;
  }
  final result = await runImport(
    adapter: adapter,
    fs: env,
    repo: repo,
    cwd: env.cwd,
    selector: command.all
        ? const ImportSelector.all()
        : ImportSelector.one(command.session!),
    limits: const ImportLimits(),
    homeDir: home,
    tempDir: Directory.systemTemp.path,
    // AC11: ids/counts are the command's PRODUCT — stdout, never the
    // diagnostics stream (in headless mode `writeln` is stderr).
    onLine: (line) => io.write('$line\n'),
  );
  return result.exitCode;
}
