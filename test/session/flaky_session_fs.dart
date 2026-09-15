import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';

/// In-memory [FileSystem] whose session-file opens/appends transiently
/// fail with an ENOENT-shaped [FileError] for the first N calls of a
/// chosen op (issue #427): the fake stands in for hosts where a session
/// file briefly disappears mid-IO (macOS Group Containers materialization,
/// backup, AV scans). Fully deterministic — no real filesystem involved.
final class FlakySessionFs implements FileSystem, RangedReadFileSystem {
  FlakySessionFs([MemoryFileSystem? delegate])
    : _delegate = delegate ?? MemoryFileSystem();

  final MemoryFileSystem _delegate;

  /// How many more [readTextFile] calls fail before reads succeed.
  int failNextReads = 0;

  /// How many more [writeFile] calls fail before writes succeed.
  int failNextWrites = 0;

  /// How many more [appendFile] calls fail before appends succeed.
  int failNextAppends = 0;

  /// Total calls seen per op, successes and simulated ENOENTs alike —
  /// the retry-cap assertions read these.
  int readCalls = 0;
  int writeCalls = 0;
  int appendCalls = 0;

  static FileError _enoent(String path) => FileError(
    FileErrorCode.notFound,
    'transient ENOENT (simulated)',
    path: path,
  );

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    readCalls++;
    if (failNextReads > 0) {
      failNextReads--;
      return Err(_enoent(path));
    }
    return _delegate.readTextFile(path);
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    writeCalls++;
    if (failNextWrites > 0) {
      failNextWrites--;
      return Err(_enoent(path));
    }
    return _delegate.writeFile(path, content);
  }

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) async {
    appendCalls++;
    if (failNextAppends > 0) {
      failNextAppends--;
      return Err(_enoent(path));
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
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);

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
}
