/// Test helpers for js_ext suites: an [ExecutionEnv] over [MemoryFileSystem]
/// with a SCRIPTED [Shell] (delegation wrapper — [MemoryExecutionEnv] cannot
/// take a custom shell from outside its library, the same shape
/// extension_host_test uses).
library;

import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';

/// A [Shell] answering each `exec` with the next scripted response, recording
/// every command. An empty script fails the call (never hangs, never fakes).
final class ScriptedShell implements Shell {
  /// Queued responses, popped front-first per exec call.
  final List<ShellExecResult> responses;

  /// Every command received, in order.
  final List<String> commands = [];

  ScriptedShell([List<ShellExecResult>? responses])
    : responses = responses ?? [];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    if (responses.isEmpty) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.shellUnavailable,
          'scripted shell has no response left for: $command',
        ),
      );
    }
    final result = responses.removeAt(0);
    options?.onStdout?.call(result.stdout);
    options?.onStderr?.call(result.stderr);
    return Ok(result);
  }
}

/// In-memory [ExecutionEnv] whose exec goes to an injected [ScriptedShell].
final class ScriptedShellEnv implements ExecutionEnv {
  ScriptedShellEnv({this.cwd = '/proj', ScriptedShell? shell})
    : _fs = MemoryFileSystem(cwd: cwd),
      shell = shell ?? ScriptedShell();

  @override
  final String cwd;

  final MemoryFileSystem _fs;

  /// The scripted shell; tests push responses and read [ScriptedShell.commands].
  final ScriptedShell shell;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _fs.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _fs.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _fs.readTextFile(path);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _fs.readBinaryFile(path);
  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _fs.readTextLines(path, maxLines: maxLines);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _fs.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _fs.writeFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _fs.appendFile(path, content);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _fs.fileInfo(path);
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _fs.listDir(path);
  @override
  Future<Result<bool, FileError>> exists(String path) => _fs.exists(path);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _fs.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _fs.remove(path, recursive: recursive, force: force);
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => shell.exec(command, options: options);
}
