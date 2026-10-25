// Tier-4 CRAP sweep helpers for WasiSandboxShell (gh-1848): the pieces
// carved out of `_resolve`, `startShellJob`, `_runPipelineStage`, and
// `_statBuiltin` moved here verbatim so the primary file stays under the
// 2800-line guard (gh-1232) — the wasm_shell_stages.dart pattern; same
// library scope, so the private shell members stay reachable.

part of 'wasm_shell.dart';

/// Parsed `stat` argv under construction: the `-c`/`--format` template
/// and the file operands.
final class _StatArgs {
  String? format;
  final files = <String>[];
}

/// A fully parsed `stat` invocation: an error line (`-c` without its
/// operand, or no operand at all), the selected format, and the files.
final class _StatInvocation {
  const _StatInvocation.error(this.error) : format = null, files = const [];

  const _StatInvocation({this.format, required this.files}) : error = null;

  final String? error;
  final String? format;
  final List<String> files;
}

extension _WasiShellTier4 on WasiSandboxShell {
  /// The shared aborted-shell error for a cancelled token (startShellJob).
  ExecutionError? _cancelledJobError(CancelToken? token) =>
      token != null && token.isCancelled
      ? const ExecutionError(ExecutionErrorCode.aborted, 'aborted')
      : null;

  /// Wraps a non-null job-log warning callback into the ceiling's
  /// `onWarn` shape, prefixed with the job id.
  static void Function(String)? _jobLogWarn(
    void Function(String)? warn,
    String id,
  ) => warn == null ? null : (message) => warn('background job $id: $message');

  /// Builds the job-log ceiling for one background job, degrading a bad
  /// `jobLogMaxBytes` to a plain Err. Issue #919 (review round 3): built
  /// BEFORE the eager log open — a bad ceiling used to throw out of
  /// _wireJob after the open succeeded, leaking the RAF fd (no job existed
  /// to run closeLog).
  Result<JobLogCeiling, ExecutionError> _jobLogCeiling(
    String id,
    String logPath,
    ShellExecOptions? options,
  ) {
    final warn = options?.onJobLogWarning;
    try {
      return Ok(
        JobLogCeiling(
          maxBytes: options?.jobLogMaxBytes ?? defaultJobLogMaxBytes,
          probe: () => diskFreeBytes(io.File(logPath).parent.path),
          onWarn: _jobLogWarn(warn, id),
        ),
      );
    } on ArgumentError catch (error) {
      return Err(
        ExecutionError(
          ExecutionErrorCode.spawnError,
          'invalid jobLogMaxBytes: ${error.message}',
          cause: error,
        ),
      );
    }
  }

  /// Builds the log ceiling, then eagerly opens the log file — in that
  /// order, so a ceiling error can never leak an opened fd (issue #919).
  Future<
    Result<
      ({JobLogCeiling ceiling, io.RandomAccessFile logFile}),
      ExecutionError
    >
  >
  _buildJobLog(String id, String logPath, ShellExecOptions? options) async {
    final ceiling = _jobLogCeiling(id, logPath, options);
    if (ceiling.isErr) return Err(ceiling.errorOrNull!);
    final logOpen = await _openJobLog(logPath);
    if (logOpen.isErr) return Err(logOpen.errorOrNull!);
    return Ok((ceiling: ceiling.valueOrNull!, logFile: logOpen.valueOrNull!));
  }

  /// Expands a pipeline stage's words: `$VAR`/`$(...)` substitution plus
  /// sandbox-fs glob expansion (gh-1393 WS-1).
  Future<Result<Stage, ExecutionError>> _expandStage(
    Stage stage,
    ShellExecOptions? options,
    int depth,
  ) {
    final stageEnv = _effectiveEnv(options);
    final cwd = _effectiveCwd(options);
    return expandShellStage(
      stage,
      stageEnv,
      (source) => _scriptRunner.substitute(source, options, depth),
      expandGlobs: (word) => expandGlobPattern(word, cwd, _globListDir),
    );
  }

  /// Resolves the input source for one stage. A heredoc/here-string body
  /// (gh-1086) lands in a temp file — stdin flows by sandbox path here —
  /// and outranks a `< file` redirect / pipe input by POSIX last-wins
  /// (the collector already cleared [StageRedirects.stdinFile]).
  /// `< /dev/null` (gh-1393 WS-1) is an empty stream, not a file: since
  /// the null sink no longer materializes `/dev/null`, an empty pipe file
  /// stands in (EOF, never ENOENT, never inherited pipe input).
  Future<String?> _stageInputSource(
    StageRedirects redirects,
    String? inputSource,
    int index,
    ShellExecOptions? options,
    List<io.File> tempFiles,
    String pipeDir,
  ) async {
    if (redirects.stdinBody != null) {
      await _writePipeFile(
        utf8.encode(redirects.stdinBody!),
        'heredoc_$index',
        tempFiles,
        pipeDir,
      );
      return '$pipeDir/pipe_heredoc_$index';
    }
    final stdinFile = redirects.stdinFile;
    if (stdinFile == null) return inputSource;
    final resolved = _resolveSandboxPath(stdinFile, _effectiveCwd(options));
    if (isNullDevicePath(resolved)) {
      await _writePipeFile(const [], 'devnull_$index', tempFiles, pipeDir);
      return '$pipeDir/pipe_devnull_$index';
    }
    return resolved;
  }

  /// Whether stderr folds into stdout's destination (`2>&1` with no
  /// stdout file — the pipe/capture case merges the bytes here).
  static bool _foldsStderrIntoStdout(StageRedirects redirects) =>
      redirects.dupStderrIntoStdout && redirects.stdoutFile == null;

  /// Whether stdout folds into stderr's destination (`>&2`/`1>&2` with
  /// no stderr file).
  static bool _foldsStdoutIntoStderr(StageRedirects redirects) =>
      redirects.dupStdoutIntoStderr && redirects.stderrFile == null;

  /// Stores one stage's folded output into its redirect targets, the
  /// accumulator, or the execution's pipe file. An unwritable redirect
  /// target is a normal failed command (issue #1156 E2: clean
  /// sandbox-path stderr + exit 1), never a raw throw.
  Future<Result<StageResult, ExecutionError>> _finishStage({
    required StageResult data,
    required StageRedirects redirects,
    required int index,
    required bool isLast,
    required ShellExecOptions? options,
    required List<io.File> tempFiles,
    required String pipeDir,
  }) async {
    // fd duplication (issue #1156 AC2/AC2b): `2>&1` folds stderr into
    // stdout's destination, `>&2`/`1>&2` the reverse. When the destination
    // is the pipe/capture the bytes merge here; a file destination is
    // handled by the writers below (POSIX append — one shared open file
    // description).
    var outBytes = data.stdout;
    var errBytes = stripSigpipeNoise(data.stderr);
    if (_foldsStderrIntoStdout(redirects)) {
      outBytes = [...outBytes, ...errBytes];
      errBytes = const <int>[];
    } else if (_foldsStdoutIntoStderr(redirects)) {
      errBytes = [...errBytes, ...outBytes];
      outBytes = const <int>[];
    }

    try {
      await _writeStageStdout(
        outBytes,
        errBytes,
        redirects,
        index: index,
        isLast: isLast,
        options: options,
        tempFiles: tempFiles,
        pipeDir: pipeDir,
      );
      // WASI guests surface SIGPIPE as stderr noise (issue #337 AC5); it
      // carries no information the caller can act on, so translate it out.
      // Only the bare `<tool>: stdout: Broken pipe` shape is stripped - a
      // python `BrokenPipeError: [Errno 32] Broken pipe` traceback stays.
      await _storeStageStderr(
        errBytes,
        outBytes,
        redirects,
        isLast: isLast,
        options: options,
      );
      return Ok(
        StageResult(
          stdout: outBytes,
          stderr: errBytes,
          exitCode: data.exitCode,
        ),
      );
    } on _RedirectWriteError catch (error) {
      _lastStageExitCode = 1;
      _lastStderr = (_lastStderr ?? '') + error.message;
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode(error.message),
          exitCode: 1,
        ),
      );
    }
  }

  /// The module+argv for a command backed by an eagerly compiled single
  /// binary, or null.
  ({WasmModule? module, List<String> argv})? _resolveSingle(String command) =>
      switch (command) {
        'rg' => (module: rg, argv: const ['rg']),
        'find' => (module: find, argv: const ['find']),
        'sed' => (module: sed, argv: const ['sed']),
        'awk' => (module: awk, argv: const ['awk']),
        _ => null,
      };

  /// The module+argv for an archive tool (`zip` serves both `zip` and
  /// `unzip` through the multicall binary), or null.
  ({WasmModule? module, List<String> argv})? _resolveArchive(String command) =>
      switch (command) {
        'tar' => (module: tar, argv: const ['tar']),
        'gzip' => (module: gzip, argv: const ['gzip']),
        'zip' => (module: zip, argv: const ['zip']),
        'unzip' => (module: zip, argv: const ['zip_util']),
        _ => null,
      };

  /// The module+argv for a heavy interpreter that compiles lazily on
  /// first use (issue #640), or null.
  ({WasmModule? module, List<String> argv})? _resolveInterpreter(
    String command,
  ) => switch (command) {
    'python' || 'python3' => (module: python, argv: const ['python']),
    'qjs' || 'js' => (module: qjs, argv: const ['qjs']),
    _ => null,
  };

  /// The module+argv for a lazily compiled engine, or null.
  ({WasmModule? module, List<String> argv})? _resolveEngine(String command) =>
      switch (command) {
        'sqlite3' => (module: sqlite3, argv: const ['sqlite3']),
        'lua' => (module: lua, argv: const ['lua']),
        _ => null,
      };

  /// The registered module+argv for [command], or null when it is not a
  /// known WASM command (the caller falls back to the coreutils applet).
  ({WasmModule? module, List<String> argv})? _resolveRegistered(
    String command,
  ) =>
      _resolveSingle(command) ??
      _resolveArchive(command) ??
      _resolveInterpreter(command) ??
      _resolveEngine(command);

  /// The `-c`/`--format` operand for the flag at [i], or null when the
  /// argv ends first (GNU: "option requires an argument").
  static String? _statFormatOperand(List<String> args, int i) {
    if (i + 1 >= args.length) return null;
    return args[i + 1];
  }

  /// Applies one non-flag stat argv word to [parsed]: `--format=…` sets
  /// the template, any other non-flag word is a file operand.
  static void _statConsumeWord(String arg, _StatArgs parsed) {
    if (arg.startsWith('--format=')) {
      parsed.format = arg.substring('--format='.length);
    } else if (!arg.startsWith('-')) {
      parsed.files.add(arg);
    }
  }

  /// Consumes the `-c`/`--format` flag at [i]; returns the index of the
  /// operand (the last word consumed), or -1 when it is missing.
  static int _statConsumeFormatFlag(
    List<String> args,
    int i,
    _StatArgs parsed,
  ) {
    final operand = _statFormatOperand(args, i);
    if (operand == null) return -1;
    parsed.format = operand;
    return i + 1;
  }

  /// Consumes the stat argv word at [i] into [parsed]; returns the index
  /// of the last word consumed (-1 when a `-c`/`--format` flag lacks its
  /// operand).
  static int _statConsumeArg(List<String> args, int i, _StatArgs parsed) {
    final arg = args[i];
    if (arg == '-c' || arg == '--format') {
      return _statConsumeFormatFlag(args, i, parsed);
    }
    _statConsumeWord(arg, parsed);
    return i;
  }

  /// Parses stat argv into the format template and file operands; the
  /// error form covers `-c`/`--format` without an operand and an operand-
  /// less invocation.
  static _StatInvocation _parseStatArgs(List<String> args) {
    final parsed = _StatArgs();
    for (var i = 0; i < args.length; i++) {
      i = _statConsumeArg(args, i, parsed);
      if (i < 0) {
        return const _StatInvocation.error(
          'stat: option requires an argument -- c\n',
        );
      }
    }
    if (parsed.files.isEmpty) {
      return const _StatInvocation.error('stat: missing operand\n');
    }
    return _StatInvocation(format: parsed.format, files: parsed.files);
  }

  /// The `-c`/`--format` rendering of one stat: the spec placeholders
  /// filled from the file's stat.
  static String _statRendered(
    String format,
    String resolved,
    io.FileStat stat,
  ) => format
      .replaceAll('%s', '${stat.size}')
      .replaceAll('%n', resolved)
      .replaceAll('%F', _statTypeName(stat.type))
      .replaceAll('%Y', '${stat.modified.millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('%y', stat.modified.toIso8601String());

  /// The default (no `-c`) stat block for one file.
  static void _statDefaultBlock(
    String resolved,
    io.FileStat stat,
    StringBuffer out,
  ) {
    out
      ..write('  File: $resolved\n')
      ..write('  Size: ${stat.size}\n')
      ..write('  Type: ${_statTypeName(stat.type)}\n')
      ..write('Modify: ${stat.modified.toIso8601String()}\n')
      ..write('Change: ${stat.changed.toIso8601String()}\n');
  }

  /// Stats one operand, appending its rendered block to [out]. Returns
  /// the GNU error line when the operand cannot be stated.
  Future<String?> _statOne(
    String file,
    String? format,
    String cwd,
    StringBuffer out,
  ) async {
    final resolved = _resolveSandboxPath(file, cwd);
    io.FileStat stat;
    try {
      stat = await io.FileStat.stat(_hostPath(resolved));
    } on Object {
      return 'stat: cannot stat \'$file\': No such file or directory\n';
    }
    if (stat.type == io.FileSystemEntityType.notFound) {
      return 'stat: cannot stat \'$file\': No such file or directory\n';
    }
    if (format != null) {
      out.write('${_statRendered(format, resolved, stat)}\n');
      return null;
    }
    _statDefaultBlock(resolved, stat, out);
    return null;
  }

  /// The `stat` builtin: optional `-c`/`--format` template, then one
  /// rendered block per operand.
  Future<Result<StageResult, ExecutionError>> _statBuiltin(
    Stage stage,
    ShellExecOptions? options,
  ) async {
    final parsed = _parseStatArgs(stage.args);
    if (parsed.error != null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode(parsed.error!),
          exitCode: 1,
        ),
      );
    }
    final cwd = _effectiveCwd(options);
    final out = StringBuffer();
    for (final file in parsed.files) {
      final error = await _statOne(file, parsed.format, cwd, out);
      if (error != null) {
        return Ok(
          StageResult(
            stdout: const [],
            stderr: utf8.encode(error),
            exitCode: 1,
          ),
        );
      }
    }
    return Ok(
      StageResult(
        stdout: utf8.encode(out.toString()),
        stderr: const [],
        exitCode: 0,
      ),
    );
  }

  static String _statTypeName(io.FileSystemEntityType type) {
    return switch (type) {
      io.FileSystemEntityType.file => 'regular file',
      io.FileSystemEntityType.directory => 'directory',
      io.FileSystemEntityType.link => 'symbolic link',
      _ => 'unknown',
    };
  }
}
