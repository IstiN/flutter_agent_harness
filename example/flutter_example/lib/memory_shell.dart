// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'shell_parser.dart';

/// A pure-Dart [Shell] that operates on a [MemoryFileSystem].
///
/// This is the web fallback for the WASM-backed `WasiSandboxShell`: the
/// vendored `package:wasm_run` cannot be compiled for the web (its
/// flutter_rust_bridge bindings import `dart:ffi` unconditionally), so no
/// WASM runtime is available in the browser. This shell implements the
/// command subset the agent relies on day to day — pipelines, `&&`/`||`/`;`,
/// redirects, `cd`/`export` state that persists across [exec] calls, and the
/// common POSIX utilities — directly in Dart over the in-memory filesystem.
///
/// Commands that genuinely need the WASM binaries or a network stack
/// (`git`, `curl`, `jq`, `rg`, `sed`, `awk`, `tar`, ...) report
/// "command not found" (exit code 127), which the agent can react to.
final class MemoryShell implements Shell {
  /// Creates a shell without a filesystem. Call [attach] before [exec]; this
  /// indirection lets the shell and the [MemoryExecutionEnv] that owns it
  /// reference each other.
  MemoryShell();

  late final MemoryFileSystem _fs;

  /// Binds the shell to [fs]. Must be called exactly once before use.
  void attach(MemoryFileSystem fs) {
    _fs = fs;
  }

  String _currentDir = '/';
  final Map<String, String> _shellEnv = {};

  String? _lastStdout;
  String? _lastStderr;

  /// Commands available in the sandbox, used by `which`/`command -v` and to
  /// decide between execution and "command not found".
  static const Set<String> _availableCommands = {
    'basename',
    'cat',
    'cd',
    'command',
    'cp',
    'dirname',
    'echo',
    'env',
    'export',
    'false',
    'grep',
    'head',
    'ls',
    'mkdir',
    'mv',
    'pwd',
    'rm',
    'rmdir',
    'sort',
    'tail',
    'test',
    'touch',
    'tr',
    'true',
    'unset',
    'wc',
    'which',
    'whoami',
    '[',
  };

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }

    late final ShellCommand parsed;
    try {
      parsed = parseCommandLine(command);
    } on ShellParseException catch (e) {
      return Err(ExecutionError(ExecutionErrorCode.unknown, 'parse error: $e'));
    }

    var exitCode = 0;
    for (var i = 0; i < parsed.statements.length; i++) {
      final statement = parsed.statements[i];
      if (statement.operator == StatementOperator.and && exitCode != 0) {
        continue;
      }
      if (statement.operator == StatementOperator.or && exitCode == 0) {
        continue;
      }

      final result = await _runPipeline(statement.pipeline, options);
      exitCode = result.exitCode;

      if (token != null && token.isCancelled) {
        return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
      }
    }

    return Ok(
      ShellExecResult(
        stdout: _lastStdout ?? '',
        stderr: _lastStderr ?? '',
        exitCode: exitCode,
      ),
    );
  }

  Future<_StageResult> _runPipeline(
    Pipeline pipeline,
    ShellExecOptions? options,
  ) async {
    _lastStdout = '';
    _lastStderr = '';

    List<int>? pipeInput;
    var stageResult = const _StageResult(stdout: [], stderr: [], exitCode: 0);

    for (var i = 0; i < pipeline.stages.length; i++) {
      // Expand `$VAR` references at execution time so earlier statements in
      // the same command line (e.g. `export A=1 && echo $A`) are visible.
      final stage = _expandStage(pipeline.stages[i], _effectiveEnv(options));
      final cwd = options?.cwd ?? _currentDir;

      String? stdoutFile;
      String? stderrFile;
      var appendStdout = false;
      var appendStderr = false;
      String? stdinFile;

      for (final redirect in stage.redirects) {
        if (redirect.fd == 0 && redirect.kind == RedirectKind.read) {
          stdinFile = redirect.target;
        } else if (redirect.fd == 1 || redirect.fd == -1) {
          stdoutFile = redirect.target;
          appendStdout = redirect.kind == RedirectKind.append;
        } else if (redirect.fd == 2 || redirect.fd == -1) {
          stderrFile = redirect.target;
          appendStderr = redirect.kind == RedirectKind.append;
        }
      }

      String? stdinText;
      if (stdinFile != null) {
        final read = await _fs.readTextFile(
          _resolveSandboxPath(stdinFile, cwd),
        );
        if (read.isErr) {
          stageResult = _StageResult(
            stdout: const [],
            stderr: utf8.encode('sh: $stdinFile: No such file or directory\n'),
            exitCode: 1,
          );
          _lastStdout = '';
          _lastStderr = utf8.decode(stageResult.stderr);
          pipeInput = null;
          continue;
        }
        stdinText = read.valueOrNull;
      } else if (pipeInput != null) {
        stdinText = utf8.decode(pipeInput, allowMalformed: true);
      }

      stageResult = await _runCommand(
        stage.command,
        stage.args,
        options,
        cwd,
        stdinText,
      );

      if (stdoutFile != null) {
        await _writeRedirect(stdoutFile, stageResult.stdout, appendStdout, cwd);
        _lastStdout = '';
      } else {
        _lastStdout = utf8.decode(stageResult.stdout, allowMalformed: true);
        if (_lastStdout!.isNotEmpty) options?.onStdout?.call(_lastStdout!);
      }

      if (stderrFile != null) {
        await _writeRedirect(stderrFile, stageResult.stderr, appendStderr, cwd);
        _lastStderr = '';
      } else {
        _lastStderr = utf8.decode(stageResult.stderr, allowMalformed: true);
        if (_lastStderr!.isNotEmpty) options?.onStderr?.call(_lastStderr!);
      }

      pipeInput = stageResult.stdout;
    }

    return stageResult;
  }

  Future<void> _writeRedirect(
    String target,
    List<int> bytes,
    bool append,
    String cwd,
  ) async {
    final path = _resolveSandboxPath(target, cwd);
    if (append) {
      await _fs.appendFile(path, utf8.decode(bytes, allowMalformed: true));
    } else {
      await _fs.writeBinaryFile(path, Uint8List.fromList(bytes));
    }
  }

  Future<_StageResult> _runCommand(
    String command,
    List<String> args,
    ShellExecOptions? options,
    String cwd,
    String? stdinText,
  ) async {
    if (!_availableCommands.contains(command)) {
      return _StageResult(
        stdout: const [],
        stderr: utf8.encode('$command: command not found\n'),
        exitCode: 127,
      );
    }
    final ctx = _Context(
      args: args,
      options: options,
      stdin: stdinText,
      cwd: cwd,
    );
    return switch (command) {
      'true' => _ok,
      'false' => const _StageResult(stdout: [], stderr: [], exitCode: 1),
      'echo' => _echo(args),
      'cat' => _cat(ctx),
      'ls' => _ls(ctx),
      'mkdir' => _mkdir(ctx),
      'rmdir' => _rmdir(ctx),
      'touch' => _touch(ctx),
      'cp' => _cp(ctx),
      'mv' => _mv(ctx),
      'rm' => _rm(ctx),
      'pwd' => _text('${ctx.cwd}\n'),
      'cd' => _cd(ctx),
      'grep' => _grep(ctx),
      'head' => _headTail(ctx, head: true),
      'tail' => _headTail(ctx, head: false),
      'wc' => _wc(ctx),
      'sort' => _sort(ctx),
      'tr' => _tr(ctx),
      'which' => _which(args),
      'command' => _command(args),
      'test' || '[' => _test(command, ctx),
      'env' => _env(ctx),
      'export' => _export(args),
      'unset' => _unset(args),
      'whoami' => _text('${_effectiveEnv(ctx.options)['USER']}\n'),
      'basename' => _basename(ctx),
      'dirname' => _dirname(ctx),
      _ => _StageResult(
        stdout: const [],
        stderr: utf8.encode('$command: command not found\n'),
        exitCode: 127,
      ),
    };
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static const _StageResult _ok = _StageResult(
    stdout: [],
    stderr: [],
    exitCode: 0,
  );

  _StageResult _text(String out, {int exitCode = 0}) => _StageResult(
    stdout: utf8.encode(out),
    stderr: const [],
    exitCode: exitCode,
  );

  _StageResult _error(String message, {int exitCode = 1}) => _StageResult(
    stdout: const [],
    stderr: utf8.encode(message),
    exitCode: exitCode,
  );

  /// Normalizes a sandbox path: collapses `.` and `..` segments and always
  /// returns an absolute path starting at the sandbox root `/`.
  String _normalizeSandboxPath(String path) {
    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return '/${segments.join('/')}';
  }

  /// Resolves [path] against [cwd] inside the sandbox, returning an absolute
  /// sandbox path.
  String _resolveSandboxPath(String path, String cwd) {
    if (path.startsWith('/')) return _normalizeSandboxPath(path);
    return _normalizeSandboxPath('$cwd/$path');
  }

  /// Effective environment visible to commands and variable expansion:
  /// sandbox defaults, persistent `export`ed variables, and any per-call
  /// overrides (later wins).
  Map<String, String> _effectiveEnv(ShellExecOptions? options) {
    final cwd = options?.cwd ?? _currentDir;
    return <String, String>{
      'HOME': '/',
      'PATH': '/bin',
      'PWD': cwd,
      'SHELL': '/bin/sh',
      'TERM': 'dumb',
      'USER': 'fah',
      ..._shellEnv,
      ...?options?.env,
    };
  }

  /// Expands `$NAME` and `${NAME}` references in [input] using [env]. Unknown
  /// variables expand to the empty string; other `$` forms are kept literal.
  String _expandVars(String input, Map<String, String> env) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < input.length) {
      final ch = input[i];
      if (ch != '\$') {
        buffer.write(ch);
        i++;
        continue;
      }
      if (i + 1 >= input.length) {
        buffer.write('\$');
        i++;
        continue;
      }
      final next = input[i + 1];
      if (next == '{') {
        final end = input.indexOf('}', i + 2);
        if (end == -1) {
          buffer.write('\${');
          i += 2;
          continue;
        }
        buffer.write(env[input.substring(i + 2, end)] ?? '');
        i = end + 1;
        continue;
      }
      final code = next.codeUnitAt(0);
      final isVarStart =
          (code >= 65 && code <= 90) ||
          (code >= 97 && code <= 122) ||
          code == 95;
      if (!isVarStart) {
        buffer.write('\$');
        i++;
        continue;
      }
      var j = i + 1;
      while (j < input.length) {
        final c = input.codeUnitAt(j);
        final isVarChar =
            (c >= 65 && c <= 90) ||
            (c >= 97 && c <= 122) ||
            (c >= 48 && c <= 57) ||
            c == 95;
        if (!isVarChar) break;
        j++;
      }
      buffer.write(env[input.substring(i + 1, j)] ?? '');
      i = j;
    }
    return buffer.toString();
  }

  /// Applies `$VAR` expansion to a parsed [stage] using [env], honoring the
  /// per-word `expandable` flags set by the parser for single quotes and
  /// `\$` escapes.
  Stage _expandStage(Stage stage, Map<String, String> env) {
    final expandedCommand = stage.isExpandable(0)
        ? _expandVars(stage.command, env)
        : stage.command;
    final expandedArgs = <String>[
      for (var k = 0; k < stage.args.length; k++)
        stage.isExpandable(k + 1)
            ? _expandVars(stage.args[k], env)
            : stage.args[k],
    ];
    final expandedRedirects = <Redirect>[
      for (final redirect in stage.redirects)
        Redirect(
          kind: redirect.kind,
          fd: redirect.fd,
          target: redirect.expandable
              ? _expandVars(redirect.target, env)
              : redirect.target,
        ),
    ];
    return Stage(
      command: expandedCommand,
      args: expandedArgs,
      redirects: expandedRedirects,
    );
  }

  /// Reads the input for a command: the files in [paths] concatenated, or the
  /// stdin text when [paths] is empty. Returns `null` and reports the failing
  /// file through [onError] when a file cannot be read.
  Future<String?> _readInput(
    List<String> paths,
    _Context ctx,
    void Function(String path) onError,
  ) async {
    if (paths.isEmpty) return ctx.stdin ?? '';
    final buffer = StringBuffer();
    for (final arg in paths) {
      if (arg == '-') {
        buffer.write(ctx.stdin ?? '');
        continue;
      }
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final result = await _fs.readTextFile(resolved);
      if (result.isErr) {
        onError(arg);
        return null;
      }
      buffer.write(result.valueOrNull);
    }
    return buffer.toString();
  }

  /// Splits flags from positional arguments; `--` ends flag parsing and a
  /// lone `-` is treated as a positional (stdin for filters).
  ({List<String> flags, List<String> paths}) _splitArgs(List<String> args) {
    final flags = <String>[];
    final paths = <String>[];
    var noMoreFlags = false;
    for (final arg in args) {
      if (arg == '--' && !noMoreFlags) {
        noMoreFlags = true;
      } else if (!noMoreFlags && arg.startsWith('-') && arg != '-') {
        flags.add(arg);
      } else {
        paths.add(arg);
      }
    }
    return (flags: flags, paths: paths);
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  _StageResult _echo(List<String> args) {
    var newline = true;
    var interpretEscapes = false;
    var i = 0;
    while (i < args.length) {
      if (args[i] == '-n') {
        newline = false;
      } else if (args[i] == '-e') {
        interpretEscapes = true;
      } else if (args[i] == '-E') {
        interpretEscapes = false;
      } else {
        break;
      }
      i++;
    }
    var out = args.sublist(i).join(' ');
    if (interpretEscapes) out = _interpretEchoEscapes(out);
    return _text(newline ? '$out\n' : out);
  }

  String _interpretEchoEscapes(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      if (input[i] == '\\' && i + 1 < input.length) {
        final next = input[i + 1];
        final escape = switch (next) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          '\\' => '\\',
          '0' => '\x00',
          _ => null,
        };
        if (escape != null) {
          buffer.write(escape);
          i++;
          continue;
        }
      }
      buffer.write(input[i]);
    }
    return buffer.toString();
  }

  Future<_StageResult> _cat(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    final number = split.flags.contains('-n');
    String? errorPath;
    final input = await _readInput(
      split.paths,
      ctx,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error('cat: $errorPath: No such file or directory\n');
    }
    if (!number) return _text(input);
    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final numbered = [
      for (var i = 0; i < lines.length; i++) '     ${i + 1}\t${lines[i]}',
    ].join('\n');
    return _text(numbered.isEmpty ? '' : '$numbered\n');
  }

  Future<_StageResult> _ls(_Context ctx) async {
    var showAll = false;
    var long = false;
    final paths = <String>[];
    for (final arg in ctx.args) {
      if (arg.startsWith('-') && arg != '-') {
        if (arg.contains('a')) showAll = true;
        if (arg.contains('l')) long = true;
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('.');

    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;
    var first = true;
    for (final arg in paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        err.write('ls: cannot access $arg: No such file or directory\n');
        exitCode = 1;
        continue;
      }
      final fileInfo = info.valueOrNull!;
      if (fileInfo.kind == FileKind.file) {
        out.writeln(long ? _longLine(fileInfo) : fileInfo.name);
        continue;
      }
      if (paths.length > 1) {
        if (!first) out.writeln();
        out.writeln('$arg:');
      }
      first = false;
      final entries = await _fs.listDir(resolved);
      if (entries.isErr) {
        err.write('ls: cannot open directory $arg\n');
        exitCode = 1;
        continue;
      }
      for (final entry in entries.valueOrNull!) {
        if (!showAll && entry.name.startsWith('.')) continue;
        out.writeln(long ? _longLine(entry) : entry.name);
      }
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

  String _longLine(FileInfo info) {
    final perms = info.kind == FileKind.directory ? 'drwxr-xr-x' : '-rw-r--r--';
    final size = info.size.toString().padLeft(8);
    return '$perms 1 fah fah $size Jan  1 00:00 ${info.name}';
  }

  Future<_StageResult> _mkdir(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    final parents = split.flags.any((f) => f.contains('p'));
    if (split.paths.isEmpty) {
      return _error('mkdir: missing operand\n');
    }
    for (final arg in split.paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final exists = await _fs.exists(resolved);
      if (exists.valueOrNull ?? false) {
        if (parents) continue;
        return _error('mkdir: cannot create directory $arg: File exists\n');
      }
      final result = await _fs.createDir(resolved, recursive: parents);
      if (result.isErr) {
        return _error(
          'mkdir: cannot create directory $arg: No such file or directory\n',
        );
      }
    }
    return _ok;
  }

  Future<_StageResult> _rmdir(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    if (split.paths.isEmpty) {
      return _error('rmdir: missing operand\n');
    }
    for (final arg in split.paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr || info.valueOrNull!.kind != FileKind.directory) {
        return _error('rmdir: failed to remove $arg: Not a directory\n');
      }
      final result = await _fs.remove(resolved);
      if (result.isErr) {
        return _error('rmdir: failed to remove $arg: Directory not empty\n');
      }
    }
    return _ok;
  }

  Future<_StageResult> _touch(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    if (split.paths.isEmpty) {
      return _error('touch: missing file operand\n');
    }
    for (final arg in split.paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final exists = await _fs.exists(resolved);
      if (!(exists.valueOrNull ?? false)) {
        await _fs.writeFile(resolved, '');
      }
    }
    return _ok;
  }

  Future<_StageResult> _cp(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    final recursive = split.flags.any(
      (f) => f.contains('r') || f.contains('R'),
    );
    if (split.paths.length < 2) {
      return _error('cp: missing file operand\n');
    }
    final destArg = split.paths.last;
    final sources = split.paths.sublist(0, split.paths.length - 1);
    final destResolved = _resolveSandboxPath(destArg, ctx.cwd);
    final destInfo = await _fs.fileInfo(destResolved);
    final destIsDir =
        destInfo.isOk && destInfo.valueOrNull!.kind == FileKind.directory;
    if (sources.length > 1 && !destIsDir) {
      return _error('cp: target $destArg: Not a directory\n');
    }
    for (final srcArg in sources) {
      final srcResolved = _resolveSandboxPath(srcArg, ctx.cwd);
      final srcInfo = await _fs.fileInfo(srcResolved);
      if (srcInfo.isErr) {
        return _error('cp: cannot stat $srcArg: No such file or directory\n');
      }
      final target = destIsDir
          ? _normalizeSandboxPath('$destResolved/${srcInfo.valueOrNull!.name}')
          : destResolved;
      final copyError = await _copyRecursive(
        srcResolved,
        target,
        srcInfo.valueOrNull!,
        recursive,
        srcArg,
      );
      if (copyError != null) return _error(copyError);
    }
    return _ok;
  }

  Future<String?> _copyRecursive(
    String src,
    String dest,
    FileInfo srcInfo,
    bool recursive,
    String srcArg,
  ) async {
    if (srcInfo.kind == FileKind.directory) {
      if (!recursive) {
        return 'cp: -r not specified; omitting directory $srcArg\n';
      }
      await _fs.createDir(dest);
      final entries = await _fs.listDir(src);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
        final error = await _copyRecursive(
          '$src/${entry.name}',
          '$dest/${entry.name}',
          entry,
          recursive,
          srcArg,
        );
        if (error != null) return error;
      }
      return null;
    }
    final data = await _fs.readBinaryFile(src);
    if (data.isErr) {
      return 'cp: cannot stat $srcArg: No such file or directory\n';
    }
    await _fs.writeBinaryFile(dest, data.valueOrNull!);
    return null;
  }

  Future<_StageResult> _mv(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    if (split.paths.length < 2) {
      return _error('mv: missing file operand\n');
    }
    final destArg = split.paths.last;
    final sources = split.paths.sublist(0, split.paths.length - 1);
    final destResolved = _resolveSandboxPath(destArg, ctx.cwd);
    final destInfo = await _fs.fileInfo(destResolved);
    final destIsDir =
        destInfo.isOk && destInfo.valueOrNull!.kind == FileKind.directory;
    if (sources.length > 1 && !destIsDir) {
      return _error('mv: target $destArg: Not a directory\n');
    }
    for (final srcArg in sources) {
      final srcResolved = _resolveSandboxPath(srcArg, ctx.cwd);
      final srcInfo = await _fs.fileInfo(srcResolved);
      if (srcInfo.isErr) {
        return _error('mv: cannot stat $srcArg: No such file or directory\n');
      }
      final target = destIsDir
          ? _normalizeSandboxPath('$destResolved/${srcInfo.valueOrNull!.name}')
          : destResolved;
      final moveError = await _moveRecursive(srcResolved, target);
      if (moveError != null) return _error(moveError);
    }
    return _ok;
  }

  Future<String?> _moveRecursive(String src, String dest) async {
    final info = await _fs.fileInfo(src);
    if (info.isErr) return 'mv: cannot stat $src\n';
    if (info.valueOrNull!.kind == FileKind.directory) {
      await _fs.createDir(dest);
      final entries = await _fs.listDir(src);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
        final error = await _moveRecursive(
          '$src/${entry.name}',
          '$dest/${entry.name}',
        );
        if (error != null) return error;
      }
    } else {
      final data = await _fs.readBinaryFile(src);
      if (data.isErr) return 'mv: cannot read $src\n';
      await _fs.writeBinaryFile(dest, data.valueOrNull!);
    }
    await _fs.remove(src, recursive: true, force: true);
    return null;
  }

  Future<_StageResult> _rm(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    final recursive = split.flags.any(
      (f) => f.contains('r') || f.contains('R'),
    );
    final force = split.flags.any((f) => f.contains('f'));
    if (split.paths.isEmpty) {
      if (force) return _ok;
      return _error('rm: missing operand\n');
    }
    for (final arg in split.paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        if (force) continue;
        return _error('rm: cannot remove $arg: No such file or directory\n');
      }
      if (info.valueOrNull!.kind == FileKind.directory && !recursive) {
        return _error('rm: cannot remove $arg: Is a directory\n');
      }
      await _fs.remove(resolved, recursive: recursive, force: force);
    }
    return _ok;
  }

  Future<_StageResult> _cd(_Context ctx) async {
    final target = ctx.args.isEmpty ? '/' : ctx.args.first;
    final resolved = _resolveSandboxPath(target, ctx.cwd);
    final info = await _fs.fileInfo(resolved);
    if (info.isErr || info.valueOrNull!.kind != FileKind.directory) {
      return _error('cd: $target: No such file or directory\n');
    }
    _currentDir = resolved;
    return _ok;
  }

  Future<_StageResult> _grep(_Context ctx) async {
    final flags = <String>{};
    String? pattern;
    final files = <String>[];
    var noMoreFlags = false;

    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '--' && !noMoreFlags) {
        noMoreFlags = true;
        continue;
      }
      if (!noMoreFlags && arg == '-e') {
        if (i + 1 >= ctx.args.length) {
          return _error(
            'grep: option requires an argument -- e\n',
            exitCode: 2,
          );
        }
        pattern = ctx.args[++i];
        continue;
      }
      if (!noMoreFlags && arg.startsWith('-') && arg.length > 1) {
        flags.addAll(arg.substring(1).split(''));
        continue;
      }
      if (pattern == null) {
        pattern = arg;
      } else {
        files.add(arg);
      }
    }

    if (pattern == null) {
      return _error('grep: missing pattern\n', exitCode: 2);
    }

    final ignoreCase = flags.contains('i');
    final invert = flags.contains('v');
    final lineNumber = flags.contains('n');
    final countOnly = flags.contains('c');
    final filesOnly = flags.contains('l');
    final quiet = flags.contains('q');

    var source = pattern;
    if (flags.contains('F')) source = RegExp.escape(source);
    if (flags.contains('w')) source = '\\b(?:$source)\\b';
    if (flags.contains('x')) source = '^(?:$source)\$';
    final RegExp regex;
    try {
      regex = RegExp(source, caseSensitive: !ignoreCase);
    } on Object catch (e) {
      return _error('grep: invalid pattern: $e\n', exitCode: 2);
    }

    bool matches(String line) {
      final found = regex.hasMatch(line);
      return invert ? !found : found;
    }

    final out = StringBuffer();
    final err = StringBuffer();
    var anyMatch = false;
    var hadError = false;

    void grepContent(String content, String? label) {
      final lines = content.split('\n');
      if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
      var count = 0;
      var reportedFile = false;
      for (var i = 0; i < lines.length; i++) {
        if (!matches(lines[i])) continue;
        anyMatch = true;
        count++;
        if (quiet) return;
        if (filesOnly) {
          if (label != null && !reportedFile) {
            out.writeln(label);
            reportedFile = true;
          }
          return;
        }
        if (countOnly) continue;
        if (label != null) out.write('$label:');
        if (lineNumber) out.write('${i + 1}:');
        out.writeln(lines[i]);
      }
      if (countOnly && !quiet && !filesOnly) {
        if (label != null) out.write('$label:');
        out.writeln(count);
      }
    }

    if (files.isEmpty) {
      grepContent(ctx.stdin ?? '', null);
    } else {
      final labelPrefix = files.length > 1;
      for (final arg in files) {
        final resolved = _resolveSandboxPath(arg, ctx.cwd);
        final content = await _fs.readTextFile(resolved);
        if (content.isErr) {
          hadError = true;
          err.write('grep: $arg: No such file or directory\n');
          continue;
        }
        grepContent(content.valueOrNull!, labelPrefix ? arg : null);
      }
    }

    return _StageResult(
      stdout: quiet ? const [] : utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: hadError ? 2 : (anyMatch ? 0 : 1),
    );
  }

  Future<_StageResult> _headTail(_Context ctx, {required bool head}) async {
    final name = head ? 'head' : 'tail';
    var count = 10;
    final paths = <String>[];
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-n' && i + 1 < ctx.args.length) {
        count = int.tryParse(ctx.args[++i]) ?? count;
      } else if (RegExp(r'^-\d+$').hasMatch(arg)) {
        count = int.parse(arg.substring(1));
      } else if (arg.startsWith('-n')) {
        count = int.tryParse(arg.substring(2)) ?? count;
      } else if (arg.startsWith('-') && arg != '-') {
        return _error('$name: unrecognized option $arg\n', exitCode: 2);
      } else {
        paths.add(arg);
      }
    }
    String? errorPath;
    final input = await _readInput(paths, ctx, (path) => errorPath = path);
    if (input == null) {
      return _error(
        '$name: cannot open $errorPath for reading: No such file or directory\n',
      );
    }
    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final selected = head
        ? lines.take(count)
        : lines.skip(lines.length > count ? lines.length - count : 0);
    final out = selected.join('\n');
    return _text(out.isEmpty ? '' : '$out\n');
  }

  Future<_StageResult> _wc(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    final showLines =
        split.flags.isEmpty || split.flags.any((f) => f.contains('l'));
    final showWords =
        split.flags.isEmpty || split.flags.any((f) => f.contains('w'));
    final showBytes =
        split.flags.isEmpty || split.flags.any((f) => f.contains('c'));

    final out = StringBuffer();
    var totalLines = 0;
    var totalWords = 0;
    var totalBytes = 0;

    void wcContent(String content, String? label) {
      final lines = content.isEmpty ? 0 : '\n'.allMatches(content).length;
      final words = content
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length;
      final bytes = utf8.encode(content).length;
      totalLines += lines;
      totalWords += words;
      totalBytes += bytes;
      final parts = <String>[
        if (showLines) '$lines',
        if (showWords) '$words',
        if (showBytes) '$bytes',
        ?label,
      ];
      out.writeln(parts.join(' '));
    }

    if (split.paths.isEmpty) {
      wcContent(ctx.stdin ?? '', null);
    } else {
      for (final arg in split.paths) {
        final content = await _fs.readTextFile(
          _resolveSandboxPath(arg, ctx.cwd),
        );
        if (content.isErr) {
          return _error('wc: $arg: No such file or directory\n');
        }
        wcContent(content.valueOrNull!, arg);
      }
      if (split.paths.length > 1) {
        final parts = <String>[
          if (showLines) '$totalLines',
          if (showWords) '$totalWords',
          if (showBytes) '$totalBytes',
          'total',
        ];
        out.writeln(parts.join(' '));
      }
    }
    return _text(out.toString());
  }

  Future<_StageResult> _sort(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    final reverse = split.flags.any((f) => f.contains('r'));
    final unique = split.flags.any((f) => f.contains('u'));
    final numeric = split.flags.any((f) => f.contains('n'));
    String? errorPath;
    final input = await _readInput(
      split.paths,
      ctx,
      (path) => errorPath = path,
    );
    if (input == null) {
      return _error(
        'sort: cannot read: $errorPath: No such file or directory\n',
      );
    }
    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (numeric) {
      lines.sort((a, b) {
        final na = num.tryParse(a.trim()) ?? 0;
        final nb = num.tryParse(b.trim()) ?? 0;
        return na.compareTo(nb);
      });
    } else {
      lines.sort();
    }
    if (reverse) {
      final reversed = lines.reversed.toList();
      lines
        ..clear()
        ..addAll(reversed);
    }
    if (unique) {
      final seen = <String>{};
      lines.retainWhere(seen.add);
    }
    final out = lines.join('\n');
    return _text(out.isEmpty ? '' : '$out\n');
  }

  _StageResult _tr(_Context ctx) {
    var delete = false;
    String? set1;
    String? set2;
    for (final arg in ctx.args) {
      if (arg == '-d') {
        delete = true;
      } else if (set1 == null) {
        set1 = arg;
      } else {
        set2 ??= arg;
      }
    }

    if (set1 == null) {
      return _error('tr: missing operand\n', exitCode: 2);
    }
    if (!delete && set2 == null) {
      return _error('tr: missing operand after "$set1"\n', exitCode: 2);
    }

    final input = ctx.stdin ?? '';
    final expanded1 = _expandTrSet(set1);
    final expanded2 = delete ? null : _expandTrSet(set2!);

    String output;
    if (delete) {
      final chars = expanded1.toSet();
      output = input.split('').where((c) => !chars.contains(c)).join();
    } else {
      final map = <String, String>{};
      for (var i = 0; i < expanded1.length; i++) {
        map[expanded1[i]] = i < expanded2!.length
            ? expanded2[i]
            : expanded2.last;
      }
      output = input
          .split('')
          .map((c) => map.containsKey(c) ? map[c]! : c)
          .join();
    }
    return _text(output);
  }

  /// Expands POSIX character classes (`[:lower:]`) and ranges (`a-z`) used by
  /// the `tr` command.
  List<String> _expandTrSet(String set) {
    final result = <String>[];
    var i = 0;
    while (i < set.length) {
      if (set.startsWith('[:lower:]', i)) {
        result.addAll('abcdefghijklmnopqrstuvwxyz'.split(''));
        i += 9;
        continue;
      }
      if (set.startsWith('[:upper:]', i)) {
        result.addAll('ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''));
        i += 9;
        continue;
      }
      if (set.startsWith('[:digit:]', i)) {
        result.addAll('0123456789'.split(''));
        i += 9;
        continue;
      }
      if (set.startsWith('[:alnum:]', i)) {
        result.addAll(
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
              .split(''),
        );
        i += 9;
        continue;
      }
      if (set.startsWith('[:space:]', i)) {
        result.addAll(' \t\n\r\f\v'.split(''));
        i += 9;
        continue;
      }
      if (i + 2 < set.length && set[i + 1] == '-') {
        final start = set.codeUnitAt(i);
        final end = set.codeUnitAt(i + 2);
        for (var c = start; c <= end; c++) {
          result.add(String.fromCharCode(c));
        }
        i += 3;
        continue;
      }
      result.add(set[i]);
      i++;
    }
    return result;
  }

  _StageResult _which(List<String> args) {
    if (args.isEmpty) {
      return _error('which: missing argument\n');
    }
    final name = args.first;
    if (_availableCommands.contains(name)) {
      return _text('/bin/$name\n');
    }
    return _error('which: $name: not found\n');
  }

  _StageResult _command(List<String> args) {
    if (args.length >= 2 && args[0] == '-v') {
      final name = args[1];
      if (_availableCommands.contains(name)) {
        return _text('/bin/$name\n');
      }
      return _error('command: $name: not found\n');
    }
    return _error('command: unsupported usage\n');
  }

  Future<_StageResult> _test(String command, _Context ctx) async {
    final rawArgs = ctx.args.toList();
    if (command == '[') {
      if (rawArgs.isEmpty || rawArgs.last != ']') {
        return _error('[[: missing `]]\n', exitCode: 2);
      }
      rawArgs.removeLast();
    }
    if (rawArgs.isEmpty) {
      return _error('test: missing expression\n', exitCode: 2);
    }
    try {
      final value = await _evalTest(rawArgs, ctx);
      return _StageResult(
        stdout: const [],
        stderr: const [],
        exitCode: value ? 0 : 1,
      );
    } on FormatException catch (e) {
      return _error('test: integer expected: $e\n', exitCode: 2);
    }
  }

  Future<bool> _evalTest(List<String> args, _Context ctx) async {
    if (args.isEmpty) return false;
    if (args.first == '!') {
      return !(await _evalTest(args.sublist(1), ctx));
    }
    if (args.length == 1) return args.first.isNotEmpty;
    if (args.length == 2) {
      final op = args[0];
      final value = args[1];
      switch (op) {
        case '-e':
          return (await _fs.exists(
                _resolveSandboxPath(value, ctx.cwd),
              )).valueOrNull ??
              false;
        case '-f':
          final info = await _fs.fileInfo(_resolveSandboxPath(value, ctx.cwd));
          return info.isOk && info.valueOrNull!.kind == FileKind.file;
        case '-d':
          final info = await _fs.fileInfo(_resolveSandboxPath(value, ctx.cwd));
          return info.isOk && info.valueOrNull!.kind == FileKind.directory;
        case '-s':
          final info = await _fs.fileInfo(_resolveSandboxPath(value, ctx.cwd));
          return info.isOk &&
              info.valueOrNull!.kind == FileKind.file &&
              info.valueOrNull!.size > 0;
        case '-z':
          return value.isEmpty;
        case '-n':
          return value.isNotEmpty;
        default:
          throw const FormatException('unary operator expected');
      }
    }
    if (args.length == 3) {
      final left = args[0];
      final op = args[1];
      final right = args[2];
      switch (op) {
        case '=':
        case '==':
          return left == right;
        case '!=':
          return left != right;
        case '-eq':
          return int.parse(left) == int.parse(right);
        case '-ne':
          return int.parse(left) != int.parse(right);
        case '-lt':
          return int.parse(left) < int.parse(right);
        case '-le':
          return int.parse(left) <= int.parse(right);
        case '-gt':
          return int.parse(left) > int.parse(right);
        case '-ge':
          return int.parse(left) >= int.parse(right);
        default:
          throw FormatException('unknown operator: $op');
      }
    }
    throw const FormatException('too many arguments');
  }

  _StageResult _env(_Context ctx) {
    final env = _effectiveEnv(ctx.options);
    for (final arg in ctx.args) {
      final idx = arg.indexOf('=');
      if (idx > 0 && !arg.startsWith('-')) {
        env[arg.substring(0, idx)] = arg.substring(idx + 1);
      } else {
        return _error('env: running commands is not supported\n');
      }
    }
    final names = env.keys.toList()..sort();
    return _text('${names.map((n) => '$n=${env[n]}').join('\n')}\n');
  }

  _StageResult _export(List<String> args) {
    if (args.isEmpty) {
      final names = _shellEnv.keys.toList()..sort();
      final lines = names
          .map((n) => 'declare -x $n="${_shellEnv[n]}"')
          .toList();
      return _text(lines.isEmpty ? '' : '${lines.join('\n')}\n');
    }
    for (final arg in args) {
      final idx = arg.indexOf('=');
      if (idx > 0) {
        _shellEnv[arg.substring(0, idx)] = arg.substring(idx + 1);
      } else {
        _shellEnv.putIfAbsent(arg, () => '');
      }
    }
    return _ok;
  }

  _StageResult _unset(List<String> args) {
    for (final arg in args) {
      _shellEnv.remove(arg);
    }
    return _ok;
  }

  _StageResult _basename(_Context ctx) {
    if (ctx.args.isEmpty) {
      return _error('basename: missing operand\n');
    }
    var path = ctx.args.first;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    var base = path.split('/').last;
    if (ctx.args.length > 1) {
      final suffix = ctx.args[1];
      if (base.endsWith(suffix) && base.length > suffix.length) {
        base = base.substring(0, base.length - suffix.length);
      }
    }
    return _text('$base\n');
  }

  _StageResult _dirname(_Context ctx) {
    if (ctx.args.isEmpty) {
      return _error('dirname: missing operand\n');
    }
    var path = ctx.args.first;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final idx = path.lastIndexOf('/');
    if (idx < 0) return _text('.\n');
    if (idx == 0) return _text('/\n');
    return _text('${path.substring(0, idx)}\n');
  }
}

/// Per-stage execution context passed to command implementations.
final class _Context {
  const _Context({
    required this.args,
    required this.options,
    required this.stdin,
    required this.cwd,
  });

  final List<String> args;
  final ShellExecOptions? options;
  final String? stdin;
  final String cwd;
}

/// Raw result of a single pipeline stage.
final class _StageResult {
  const _StageResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final List<int> stdout;
  final List<int> stderr;
  final int exitCode;
}
