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
        'usage: /jsr <widget:test|widget:screenshot> <path> [flags...] '
        '(same flags as fa jsr):\n'
        '$jsrUsage\n'
        'note: /jsr splits arguments on whitespace — for exact argv '
        '(quoted JSON payloads) use `fa jsr` from a shell',
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
      // null when the session has no env accessor: the harness cannot see
      // PATH, so it does not claim flutter is missing — the child owns
      // that failure (I2), bin/fah.dart's envVarValue always binds this.
      pathEnv: config.envVarValue?.call('PATH'),
      pathListSeparator: (config.osName ?? '').toLowerCase() == 'windows'
          ? ';'
          : ':',
      windowsQuoting: (config.osName ?? '').toLowerCase() == 'windows',
    );
    if (code != 0) {
      io.writeln('/jsr: exited with code $code');
    }
  }
}
