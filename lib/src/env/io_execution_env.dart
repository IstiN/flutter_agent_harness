/// `dart:io`-backed [ExecutionEnv] for VM, desktop, and mobile targets.
///
/// **This library is not web-safe.** It is the only `dart:io` subtree of the
/// package and is exported only through `lib/io.dart`; the core library
/// (`lib/flutter_agent_harness.dart`) never imports it, so web compilation
/// of the core stays clean.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'execution_env.dart';

FileError _toFileError(Object error, String path) {
  if (error is FileError) return error;
  if (error is PathNotFoundException) {
    return FileError(
      FileErrorCode.notFound,
      error.message,
      path: path,
      cause: error,
    );
  }
  if (error is FileSystemException) {
    final osError = error.osError;
    if (osError != null) {
      // EPERM / EACCES on POSIX; ERROR_ACCESS_DENIED (5) on Windows.
      if (osError.errorCode == 13 ||
          osError.errorCode == 1 ||
          osError.errorCode == 5) {
        return FileError(
          FileErrorCode.permissionDenied,
          error.message,
          path: path,
          cause: error,
        );
      }
      // ENOTDIR on POSIX.
      if (osError.errorCode == 20) {
        return FileError(
          FileErrorCode.notDirectory,
          error.message,
          path: path,
          cause: error,
        );
      }
    }
    return FileError(
      FileErrorCode.unknown,
      error.message,
      path: path,
      cause: error,
    );
  }
  return FileError(
    FileErrorCode.unknown,
    error.toString(),
    path: path,
    cause: error,
  );
}

/// Local-disk [FileSystem] backed by `dart:io`.
///
/// Relative paths resolve against [cwd] (default: the process working
/// directory). All operations uphold the [FileSystem] never-throw invariant.
final class LocalFileSystem implements FileSystem {
  /// Creates a [LocalFileSystem] rooted at [cwd].
  LocalFileSystem({String? cwd}) : cwd = cwd ?? Directory.current.path;

  @override
  final String cwd;

  String _resolve(String path) {
    if (path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) {
      return path;
    }
    return '$cwd/$path';
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) async {
    return Ok(_resolve(path));
  }

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) async {
    return Ok(parts.join('/'));
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final resolved = _resolve(path);
    try {
      final stat = await FileStat.stat(resolved);
      if (stat.type == FileSystemEntityType.directory) {
        return Err(
          FileError(
            FileErrorCode.isDirectory,
            'Is a directory',
            path: resolved,
          ),
        );
      }
      return Ok(await File(resolved).readAsString());
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    final resolved = _resolve(path);
    try {
      final stat = await FileStat.stat(resolved);
      if (stat.type == FileSystemEntityType.directory) {
        return Err(
          FileError(
            FileErrorCode.isDirectory,
            'Is a directory',
            path: resolved,
          ),
        );
      }
      return Ok(await File(resolved).readAsBytes());
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    if (maxLines != null && maxLines <= 0) return const Ok([]);
    final resolved = _resolve(path);
    try {
      final lines = <String>[];
      final stream = File(
        resolved,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in stream) {
        lines.add(line);
        if (maxLines != null && lines.length >= maxLines) break;
      }
      return Ok(lines);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    final resolved = _resolve(path);
    try {
      await Directory(File(resolved).parent.path).create(recursive: true);
      await File(resolved).writeAsString(content);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async {
    final resolved = _resolve(path);
    try {
      await Directory(File(resolved).parent.path).create(recursive: true);
      await File(resolved).writeAsBytes(content);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async {
    final resolved = _resolve(path);
    try {
      await Directory(File(resolved).parent.path).create(recursive: true);
      await File(resolved).writeAsString(content, mode: FileMode.append);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async {
    final resolved = _resolve(path);
    try {
      final stat = await FileStat.stat(resolved);
      final kind = switch (stat.type) {
        FileSystemEntityType.file => FileKind.file,
        FileSystemEntityType.directory => FileKind.directory,
        FileSystemEntityType.link => FileKind.symlink,
        _ => null,
      };
      if (kind == null) {
        return Err(
          FileError(
            FileErrorCode.invalid,
            'Unsupported file type',
            path: resolved,
          ),
        );
      }
      return Ok(
        FileInfo(
          name: resolved.split('/').last,
          path: resolved,
          kind: kind,
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final resolved = _resolve(path);
    try {
      final infos = <FileInfo>[];
      await for (final entity in Directory(resolved).list(followLinks: false)) {
        final info = await fileInfo(entity.path);
        if (info.isOk) infos.add(info.valueOrNull!);
      }
      infos.sort((a, b) => a.name.compareTo(b.name));
      return Ok(infos);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<bool, FileError>> exists(String path) async {
    final resolved = _resolve(path);
    try {
      final type = await FileSystemEntity.type(resolved, followLinks: false);
      return Ok(type != FileSystemEntityType.notFound);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async {
    final resolved = _resolve(path);
    try {
      await Directory(resolved).create(recursive: recursive);
      return const Ok(null);
    } on Object catch (error) {
      return Err(_toFileError(error, resolved));
    }
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    final resolved = _resolve(path);
    try {
      final type = await FileSystemEntity.type(resolved, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (force) return const Ok(null);
        return Err(
          FileError(
            FileErrorCode.notFound,
            'No such file or directory',
            path: resolved,
          ),
        );
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(resolved).delete(recursive: recursive);
      } else {
        await File(resolved).delete();
      }
      return const Ok(null);
    } on Object catch (error) {
      if (error is FileSystemException && !recursive) {
        return Err(
          FileError(
            FileErrorCode.invalid,
            error.message,
            path: resolved,
            cause: error,
          ),
        );
      }
      return Err(_toFileError(error, resolved));
    }
  }
}

/// Minimal local shell backed by `dart:io` `Process`.
///
/// Executes commands via `sh -c` (POSIX) or `cmd /c` (Windows). Streaming
/// callbacks receive output chunks as they arrive; timeout and cancellation
/// kill the process. This is the v1 shell — pi's richer bash-discovery logic
/// is deferred until a tool actually needs it.
final class LocalShell implements Shell {
  /// Creates a [LocalShell].
  const LocalShell();

  /// The child environment: the caller's `options.env` when given (its PATH
  /// wins), else the host's. PATH always gains the common tool directories
  /// (`/opt/homebrew/bin`, `/usr/local/bin` when they exist) — GUI-launched
  /// apps (the packaged macOS app) inherit a minimal PATH that would
  /// otherwise hide user-installed tools (Homebrew python/node).
  static Map<String, String> _environment(ShellExecOptions? options) {
    final given = options?.env;
    final base = <String, String>{
      if (given == null) ...Platform.environment else ...given,
    };
    var current = base['PATH'] ?? '';
    if (current.isEmpty) {
      // An explicit env without a PATH (or a minimal GUI-app PATH): keep
      // the shell itself resolvable, then widen for user tools.
      current = Platform.environment['PATH'] ?? '';
    }
    if (current.isEmpty) current = '/usr/bin:/bin:/usr/sbin:/sbin';
    final parts = current.split(':');
    for (final dir in const ['/opt/homebrew/bin', '/usr/local/bin']) {
      if (!parts.contains(dir) && Directory(dir).existsSync()) parts.add(dir);
    }
    base['PATH'] = parts.join(':');
    return base;
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token?.isCancelled ?? false) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
    final executable = Platform.isWindows ? 'cmd' : 'sh';
    final args = Platform.isWindows ? ['/c', command] : ['-c', command];
    Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: options?.cwd,
        environment: _environment(options),
      );
    } on Object catch (error) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          error.toString(),
          cause: error,
        ),
      );
    }

    final stdout = StringBuffer();
    final stderr = StringBuffer();
    ExecutionError? callbackError;
    void collect(
      StringBuffer target,
      String chunk,
      void Function(String)? callback,
    ) {
      target.write(chunk);
      if (callback == null) return;
      try {
        callback(chunk);
      } on Object catch (error) {
        callbackError = ExecutionError(
          ExecutionErrorCode.callbackError,
          error.toString(),
          cause: error,
        );
        process.kill();
      }
    }

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .forEach((chunk) => collect(stdout, chunk, options?.onStdout));
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) => collect(stderr, chunk, options?.onStderr));

    Timer? timer;
    var timedOut = false;
    final timeout = options?.timeout;
    if (timeout != null) {
      timer = Timer(timeout, () {
        timedOut = true;
        process.kill();
      });
    }
    void onCancel(_) {
      process.kill();
    }

    token?.onCancel.then(onCancel);

    final exitCode = await process.exitCode;
    timer?.cancel();
    await Future.wait([stdoutDone, stderrDone]);

    if (callbackError != null) return Err(callbackError!);
    if (timedOut) {
      return Err(
        ExecutionError(ExecutionErrorCode.timeout, 'timeout: $timeout'),
      );
    }
    if (token?.isCancelled ?? false) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
    return Ok(
      ShellExecResult(
        stdout: stdout.toString(),
        stderr: stderr.toString(),
        exitCode: exitCode,
      ),
    );
  }
}

/// Local [ExecutionEnv]: [LocalFileSystem] plus [LocalShell].
///
/// Exported only from `lib/io.dart`.
final class LocalExecutionEnv implements ExecutionEnv {
  /// Creates a [LocalExecutionEnv] rooted at [cwd].
  ///
  /// A custom [shell] may be provided to swap the default [LocalShell] for a
  /// sandboxed WASM shell on mobile targets.
  LocalExecutionEnv({String? cwd, Shell? shell})
    : _fs = LocalFileSystem(cwd: cwd),
      _shell = shell ?? const LocalShell();

  final LocalFileSystem _fs;
  final Shell _shell;

  @override
  String get cwd => _fs.cwd;

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
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _fs.writeFile(path, content);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _fs.writeBinaryFile(path, content);

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
  }) => _shell.exec(command, options: options);
}
