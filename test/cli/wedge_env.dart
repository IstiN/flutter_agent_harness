import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Delegating [ExecutionEnv] for the issue #2248 CLI suites: injects
/// session-IO failures (fail or hang, the wedge shapes) on `.jsonl`
/// appends and fa.log sink failures on the diagnostic log, while every
/// other op passes through to an in-memory delegate.
///
/// Same delegation shape as `RenameGateEnv` (agent_cli_test_support).
final class WedgeEnv
    implements ExecutionEnv, RenamableFileSystem, RangedReadFileSystem {
  WedgeEnv(this._delegate);

  final MemoryExecutionEnv _delegate;

  /// When set, every `.jsonl` append fails with this [FileError] (the
  /// AC1 wrapped-OSError shape).
  FileError? failSessionAppendsWith;

  /// When true, every `.jsonl` append never completes (the AC2 hang).
  bool hangSessionAppends = false;

  /// How many more fa.log appends fail before they succeed (AC4). The
  /// failure carries [failLogMessage].
  int failNextLogAppends = 0;
  String failLogMessage = 'simulated fs down';

  /// When set, fa.log appends from this CALL INDEX onward never complete
  /// (the fail→ok→hang shape of RC round-1: a flaky fs that fails once,
  /// succeeds once, then hangs mid-flush).
  int? hangLogAppendsFrom;

  /// listDir calls for these paths never complete until [listDirGate]
  /// completes (the boot-not-gated probe: gate a container SUBDIR so the
  /// walk pends while boot proceeds).
  Set<String> gatedListDirPaths = {};
  final Completer<void> listDirGate = Completer<void>();

  int _logAppendCalls = 0;

  int sessionAppendCalls = 0;

  bool _isSessionJsonl(String path) => path.endsWith('.jsonl');
  bool _isDiagLog(String path) => path.endsWith('/.fah/logs/fa.log');

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    if (_isSessionJsonl(path)) {
      sessionAppendCalls++;
      final failure = failSessionAppendsWith;
      if (failure != null) return Future.value(Err(failure));
      if (hangSessionAppends) {
        return Completer<Result<void, FileError>>().future;
      }
    }
    if (_isDiagLog(path)) {
      final index = _logAppendCalls++;
      final hangFrom = hangLogAppendsFrom;
      if (hangFrom != null && index >= hangFrom) {
        return Completer<Result<void, FileError>>().future;
      }
      if (failNextLogAppends > 0) {
        failNextLogAppends--;
        return Future.value(
          Err(FileError(FileErrorCode.unknown, failLogMessage, path: path)),
        );
      }
    }
    return _delegate.appendFile(path, content);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) {
    if (gatedListDirPaths.contains(path) && !listDirGate.isCompleted) {
      return listDirGate.future.then((_) => _delegate.listDir(path));
    }
    return _delegate.listDir(path);
  }

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) => _delegate.readRange(path, start, end);

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) =>
      _delegate.renamePath(from, to);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}
