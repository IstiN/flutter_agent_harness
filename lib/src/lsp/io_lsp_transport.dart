/// `dart:io`-backed [LspTransport]: spawns a language server process and
/// wires its stdin/stdout to the pure-Dart LSP client.
///
/// **This library is not web-safe.** It is exported only from
/// `lib/io.dart`; the core library never imports it.
library;

import 'dart:async';
import 'dart:io';

import 'lsp_config.dart';
import 'lsp_transport.dart';

/// An [LspTransport] over a spawned process's stdio.
final class IoLspTransport implements LspTransport {
  IoLspTransport._(this._process);

  /// Spawns [command] with [args] in [cwd]. Throws
  /// [LspServerUnavailableException] when the executable cannot be started
  /// (e.g. not on `PATH`) so the `lsp` tool degrades to a clean error
  /// result instead of crashing.
  static Future<IoLspTransport> spawn({
    required String command,
    required List<String> args,
    required String cwd,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        command,
        args,
        workingDirectory: cwd,
        mode: ProcessStartMode.normal,
      );
    } on Object catch (error) {
      throw LspServerUnavailableException(
        'cannot start LSP server `$command`: $error. '
        'Is it installed and on PATH?',
        cause: error,
      );
    }
    return IoLspTransport._(process);
  }

  final Process _process;

  @override
  Stream<List<int>> get messages => _process.stdout;

  @override
  void write(List<int> data) {
    try {
      _process.stdin.add(data);
    } on Object {
      // The process is gone; the exit watcher reports the failure.
    }
  }

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() {
    try {
      _process.kill();
    } on Object {
      // Already gone.
    }
  }
}

/// The process-capable [LspTransportFactory] for CLI/desktop hosts: spawns
/// `config.command config.args...` in the workspace root.
Future<LspTransport> ioLspTransportFactory(LspServerConfig config, String cwd) {
  return IoLspTransport.spawn(
    command: config.command,
    args: config.args,
    cwd: cwd,
  );
}
