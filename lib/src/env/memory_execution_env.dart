/// Pure-Dart in-memory [ExecutionEnv] implementation.
///
/// This is the default environment for tests and web consumers: it keeps the
/// whole filesystem in memory and implements the [FileSystem] never-throw
/// invariant trivially. [MemoryExecutionEnv] adds a [Shell]; by default the
/// shell is [UnavailableShell], which reports
/// [ExecutionErrorCode.shellUnavailable] (the correct answer on web).
library;

import 'execution_env.dart';

/// In-memory [FileSystem] with POSIX-style (`/`-separated) paths.
///
/// Paths are normalized (`.`/`..` resolved, duplicate slashes collapsed) and
/// relative paths are resolved against [cwd]. Writes and appends create
/// parent directories automatically, matching the `dart:io` implementation.
final class MemoryFileSystem implements FileSystem {
  /// Creates a [MemoryFileSystem] rooted at [cwd] (default `/`).
  MemoryFileSystem({this.cwd = '/'}) {
    _dirs.add('/');
  }

  @override
  final String cwd;

  final Map<String, _MemoryFile> _files = {};
  final Set<String> _dirs = {};

  String _normalize(String path) {
    var p = path;
    if (!p.startsWith('/')) p = '$cwd/$p';
    final segments = <String>[];
    for (final segment in p.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(segment);
    }
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  String _parentOf(String path) {
    final index = path.lastIndexOf('/');
    return index <= 0 ? '/' : path.substring(0, index);
  }

  void _ensureParents(String path) {
    var dir = _parentOf(path);
    final created = <String>[];
    while (!_dirs.contains(dir)) {
      created.add(dir);
      dir = _parentOf(dir);
    }
    _dirs.addAll(created);
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) async {
    return Ok(_normalize(path));
  }

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) async {
    return Ok(_normalize(parts.join('/')));
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final resolved = _normalize(path);
    if (_dirs.contains(resolved)) {
      return Err(
        FileError(FileErrorCode.isDirectory, 'Is a directory', path: resolved),
      );
    }
    final file = _files[resolved];
    if (file == null) {
      return Err(
        FileError(FileErrorCode.notFound, 'No such file', path: resolved),
      );
    }
    return Ok(file.content);
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    if (maxLines != null && maxLines <= 0) return const Ok([]);
    final result = await readTextFile(path);
    if (result.isErr) return Err(result.errorOrNull!);
    var content = result.valueOrNull!;
    if (content.endsWith('\n')) {
      content = content.substring(0, content.length - 1);
    }
    final lines = content.isEmpty ? <String>[] : content.split('\n');
    if (maxLines != null && lines.length > maxLines) {
      return Ok(lines.sublist(0, maxLines));
    }
    return Ok(lines);
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    final resolved = _normalize(path);
    _ensureParents(resolved);
    _files[resolved] = _MemoryFile(
      content,
      DateTime.now().millisecondsSinceEpoch,
    );
    return const Ok(null);
  }

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async {
    final resolved = _normalize(path);
    _ensureParents(resolved);
    final existing = _files[resolved];
    _files[resolved] = _MemoryFile(
      (existing?.content ?? '') + content,
      DateTime.now().millisecondsSinceEpoch,
    );
    return const Ok(null);
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async {
    final resolved = _normalize(path);
    final file = _files[resolved];
    if (file != null) {
      return Ok(
        FileInfo(
          name: resolved.split('/').last,
          path: resolved,
          kind: FileKind.file,
          size: file.content.length,
          mtimeMs: file.mtimeMs,
        ),
      );
    }
    if (_dirs.contains(resolved)) {
      return Ok(
        FileInfo(
          name: resolved == '/' ? '/' : resolved.split('/').last,
          path: resolved,
          kind: FileKind.directory,
          size: 0,
          mtimeMs: 0,
        ),
      );
    }
    return Err(
      FileError(
        FileErrorCode.notFound,
        'No such file or directory',
        path: resolved,
      ),
    );
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final resolved = _normalize(path);
    if (_files.containsKey(resolved)) {
      return Err(
        FileError(
          FileErrorCode.notDirectory,
          'Not a directory',
          path: resolved,
        ),
      );
    }
    if (!_dirs.contains(resolved)) {
      return Err(
        FileError(FileErrorCode.notFound, 'No such directory', path: resolved),
      );
    }
    final prefix = resolved == '/' ? '/' : '$resolved/';
    final children = <String>{};
    for (final dir in _dirs) {
      if (dir.startsWith(prefix) && dir != resolved) {
        children.add(dir.substring(prefix.length).split('/').first);
      }
    }
    for (final file in _files.keys) {
      if (file.startsWith(prefix)) {
        children.add(file.substring(prefix.length).split('/').first);
      }
    }
    final infos = <FileInfo>[];
    for (final name in children) {
      final childPath = '$prefix$name';
      final info = await fileInfo(childPath);
      if (info.isOk) infos.add(info.valueOrNull!);
    }
    infos.sort((a, b) => a.name.compareTo(b.name));
    return Ok(infos);
  }

  @override
  Future<Result<bool, FileError>> exists(String path) async {
    final resolved = _normalize(path);
    return Ok(_files.containsKey(resolved) || _dirs.contains(resolved));
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async {
    final resolved = _normalize(path);
    if (!recursive) {
      final parent = _parentOf(resolved);
      if (!_dirs.contains(parent)) {
        return Err(
          FileError(
            FileErrorCode.notFound,
            'Parent directory missing',
            path: resolved,
          ),
        );
      }
    }
    _dirs.add(resolved);
    _ensureParents(resolved);
    return const Ok(null);
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    final resolved = _normalize(path);
    final isFile = _files.containsKey(resolved);
    final isDir = _dirs.contains(resolved);
    if (!isFile && !isDir) {
      if (force) return const Ok(null);
      return Err(
        FileError(
          FileErrorCode.notFound,
          'No such file or directory',
          path: resolved,
        ),
      );
    }
    if (isFile) {
      _files.remove(resolved);
      return const Ok(null);
    }
    final prefix = '$resolved/';
    final hasChildren =
        _dirs.any((d) => d.startsWith(prefix)) ||
        _files.keys.any((f) => f.startsWith(prefix));
    if (hasChildren && !recursive) {
      return Err(
        FileError(FileErrorCode.invalid, 'Directory not empty', path: resolved),
      );
    }
    _dirs.removeWhere((d) => d == resolved || d.startsWith(prefix));
    _files.removeWhere((f, _) => f.startsWith(prefix));
    return const Ok(null);
  }
}

final class _MemoryFile {
  _MemoryFile(this.content, this.mtimeMs);

  final String content;
  final int mtimeMs;
}

/// A [Shell] that reports [ExecutionErrorCode.shellUnavailable] for every
/// command — the correct behavior on platforms without a process shell
/// (web, or any sandboxed environment).
final class UnavailableShell implements Shell {
  /// Creates an [UnavailableShell].
  const UnavailableShell();

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'No shell is available in this environment',
      ),
    );
  }
}

/// In-memory [ExecutionEnv]: [MemoryFileSystem] plus a [Shell].
///
/// The default shell is [UnavailableShell]; pass a custom [shell] to test
/// shell-consuming code without spawning real processes.
final class MemoryExecutionEnv extends MemoryFileSystem
    implements ExecutionEnv {
  /// Creates a [MemoryExecutionEnv] rooted at [cwd].
  MemoryExecutionEnv({super.cwd, this._shell = const UnavailableShell()});

  final Shell _shell;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) {
    return _shell.exec(command, options: options);
  }
}
