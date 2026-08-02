/// `dart:io`-backed [McpByteChannel]: spawns a stdio MCP server process and
/// wires its stdin/stdout to the pure-Dart [McpStdioTransport].
///
/// **This library is not web-safe.** It is exported only from
/// `lib/io.dart`; the core library never imports it.
library;

import 'dart:async';
import 'dart:io';

import 'mcp_config.dart';
import 'mcp_transport.dart';

/// A [McpByteChannel] over a spawned process's stdio.
final class IoMcpByteChannel implements McpByteChannel {
  IoMcpByteChannel._(this._process);

  /// Spawns [command] with [args] in [cwd] with extra environment [env].
  /// Throws [McpServerUnavailableException] when the executable cannot be
  /// started (e.g. not on `PATH`) so the server lands in `failed` status
  /// instead of crashing the session.
  static Future<IoMcpByteChannel> spawn({
    required String command,
    required List<String> args,
    required Map<String, String> env,
    required String cwd,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        command,
        args,
        workingDirectory: cwd,
        environment: env,
        mode: ProcessStartMode.normal,
      );
    } on Object catch (error) {
      throw McpServerUnavailableException(
        'cannot start MCP server `$command`: $error. '
        'Is it installed and on PATH?',
        cause: error,
      );
    }
    // stderr is diagnostic noise for the human, not protocol: drain it so a
    // chatty server cannot fill the pipe buffer and wedge itself.
    unawaited(process.stderr.drain<void>());
    return IoMcpByteChannel._(process);
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

/// The process-capable [McpTransportFactory] for CLI/desktop hosts: spawns
/// `command args...` in the workspace root. Remote (HTTP) servers are pure
/// Dart and never come through here — the manager routes them itself.
Future<McpTransport> ioMcpTransportFactory(
  McpServerConfig server,
  String cwd,
) async {
  if (server is! McpStdioServerConfig) {
    throw McpServerUnavailableException(
      'ioMcpTransportFactory only spawns stdio servers, got ${server.name}',
    );
  }
  final channel = await IoMcpByteChannel.spawn(
    command: server.command,
    args: server.args,
    env: server.env,
    cwd: cwd,
  );
  return McpStdioTransport(channel);
}
