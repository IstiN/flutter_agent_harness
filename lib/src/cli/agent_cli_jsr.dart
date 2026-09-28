/// The REPL `/jsr` alias (gh-1033): same delegate as the headless
/// `fa jsr` subcommand — resolve `js_widget_runtime` from the session
/// project, exec its agent CLI, stream the child's output, and report the
/// exit code. Output rides [AgentCli.io] (both channels on the terminal in
/// interactive mode); PATH comes through the config's env-value accessor
/// so lib/ stays dart:io-free.
part of 'agent_cli.dart';

extension AgentCliJsr on AgentCli {
  /// `/jsr widget:test|widget:screenshot <path> [flags...]`.
  Future<void> _jsrSlash(String rest) async {
    final trimmed = rest.trim();
    final parts = trimmed.isEmpty
        ? const <String>[]
        : trimmed.split(_commandWhitespace);
    if (parts.isEmpty || !jsrVerbs.contains(parts.first)) {
      io.writeln(
        'usage: /jsr widget:test <path> [--event ID]... '
        '[--expect-state JSON] [--seed-storage JSON] [--json]\n'
        '       /jsr widget:screenshot <path> [--out png] [--width N] '
        '[--height N] [--theme name] [--scale S] [--freeze-clock]',
      );
      return;
    }
    final command = JsrCliCommand(verb: parts.first, args: parts.sublist(1));
    final code = await runJsrCliCommand(
      command,
      io: SinkJsrCliIo(
        onStdout: io.write,
        onStderr: io.write,
        onNote: io.writeln,
      ),
      env: _env,
      projectDir: _env.cwd,
      pathEnv: config.envVarValue?.call('PATH') ?? '',
      pathListSeparator: (config.osName ?? '').toLowerCase() == 'windows'
          ? ';'
          : ':',
    );
    if (code != 0) {
      io.writeln('/jsr: exited with code $code');
    }
  }
}
