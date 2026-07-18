// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'sandbox_builtins.dart';
import 'shell_parser.dart';
import 'web_git.dart';
import 'web_interpreters_stub.dart'
    if (dart.library.html) 'web_interpreters_web.dart';

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
/// On top of the core POSIX utilities, the following are implemented in
/// pure Dart and work in the browser: `curl`/`wget`/`jq`/`yq`/`diff`/`patch`,
/// plus `nslookup`/`dig` (DNS-over-HTTPS via cloudflare-dns.com) and `whois`
/// (RDAP over HTTPS via rdap.org) — all shared with the WASM shell via
/// `sandbox_builtins.dart` — `sed`, `awk`, `find`, `xargs`, `printf`,
/// `realpath`, `tar`/`gzip`/`gunzip`/`zip`/`unzip`/`xz -d`/`bzip2 -d`
/// (+`unxz`/`bunzip2`) and `file` (via `package:archive`), `tree`,
/// `base64`, `md5sum`/`sha*sum` (via `package:crypto`, matching the uutils
/// applets on iOS), and `rg` (an alias of the Dart `grep`
/// implementation, mirroring iOS where `grep` maps to `rg` with grep
/// semantics). `python3`/`qjs`/`sqlite3` run in browser-hosted interpreters
/// loaded from CDNs (pyodide, quickjs-emscripten, sql.js) and `pip`/`pip3`
/// install pure-Python wheels via pyodide's micropip; `lua` has no
/// browser build. All report "command not found" (127). `git` works locally via
/// dart_git; remote clone/push is not supported in the browser (CORS).
/// `ssh`/`scp`/`sftp` are registered (so `which` finds them) but always fail
/// with exit code 127 — browsers cannot open raw TCP connections.
/// Everything else reports exit code 127, which the agent can react to.
final class MemoryShell implements Shell {
  /// Creates a shell without a filesystem. Call [attach] before [exec]; this
  /// indirection lets the shell and the [MemoryExecutionEnv] that owns it
  /// reference each other.
  ///
  /// [httpClient] backs the `curl`/`wget` builtins; tests can inject a
  /// `MockClient` from `package:http/testing.dart`.
  MemoryShell({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  late final MemoryFileSystem _fs;
  late final WebGitCommands _gitCommands;

  /// Binds the shell to [fs]. Must be called exactly once before use.
  void attach(MemoryFileSystem fs) {
    _fs = fs;
    _gitCommands = WebGitCommands(fs);
  }

  String _currentDir = '/';
  final Map<String, String> _shellEnv = {};

  String? _lastStdout;
  String? _lastStderr;

  /// Commands available in the sandbox, used by `which`/`command -v` and to
  /// decide between execution and "command not found".
  static const Set<String> _availableCommands = {
    'awk',
    'base64',
    'basename',
    'bunzip2',
    'bzip2',
    'cat',
    'cd',
    'command',
    'cp',
    'curl',
    'diff',
    'dig',
    'dirname',
    'echo',
    'env',
    'export',
    'false',
    'file',
    'find',
    'git',
    'grep',
    'gunzip',
    'gzip',
    'head',
    'jq',
    'js',
    'ls',
    'lua',
    'md5sum',
    'mkdir',
    'mv',
    'nslookup',
    'patch',
    'pip',
    'pip3',
    'printf',
    'pwd',
    'python',
    'python3',
    'qjs',
    'realpath',
    'rg',
    'rm',
    'rmdir',
    'scp',
    'sed',
    'sftp',
    'sha1sum',
    'sha224sum',
    'sha256sum',
    'sha384sum',
    'sha512sum',
    'sort',
    'sqlite3',
    'ssh',
    'tail',
    'tar',
    'test',
    'touch',
    'tr',
    'tree',
    'true',
    'unset',
    'unxz',
    'unzip',
    'wc',
    'wget',
    'which',
    'whoami',
    'whois',
    'xargs',
    'xz',
    'yq',
    'zip',
    '[',
  };

  /// Checksum commands dispatched to [_hashsum].
  static const _hashCommands = {
    'md5sum',
    'sha1sum',
    'sha224sum',
    'sha256sum',
    'sha384sum',
    'sha512sum',
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
      'git' => _git(ctx),
      'curl' => _curl(ctx),
      'wget' => _wget(ctx),
      'jq' => _jq(ctx),
      'yq' => _yq(ctx),
      'diff' => _diff(ctx),
      'dig' => _dig(ctx),
      'patch' => _patch(ctx),
      'nslookup' => _nslookup(ctx),
      'whois' => _whois(ctx),
      'tree' => _toStage(_builtinsFor(ctx).tree(ctx.args)),
      'file' => _toStage(_builtinsFor(ctx).file(ctx.args)),
      'xz' || 'unxz' => _xz(ctx, decompress: command == 'unxz'),
      'bzip2' || 'bunzip2' => _bzip2(ctx, decompress: command == 'bunzip2'),
      'base64' => _toStage(
        _builtinsFor(ctx).base64(ctx.args, stdin: ctx.stdin),
      ),
      _ when _hashCommands.contains(command) => _hashsum(command, ctx),
      'rg' => _grep(ctx),
      'sed' => _sed(ctx),
      'awk' => _awk(ctx),
      'find' => _find(ctx),
      'xargs' => _xargs(ctx),
      'printf' => _printf(ctx),
      'realpath' => _realpath(ctx),
      'tar' => _tar(ctx),
      'gzip' => _gzip(ctx, decompress: false),
      'gunzip' => _gzip(ctx, decompress: true),
      'zip' => _zip(ctx),
      'unzip' => _toStage(_builtinsFor(ctx).unzip(ctx.args)),
      'sqlite3' => _runSqlite(ctx),
      'python' || 'python3' => _runPython(ctx),
      'pip' || 'pip3' => _runPip(ctx),
      'qjs' || 'js' => _runQjs(ctx),
      'lua' => _interpreterUnavailable('lua'),
      'whoami' => _text('${_effectiveEnv(ctx.options)['USER']}\n'),
      'basename' => _basename(ctx),
      'dirname' => _dirname(ctx),
      'ssh' || 'scp' || 'sftp' => _sshUnavailable(command),
      _ => _StageResult(
        stdout: const [],
        stderr: utf8.encode('$command: command not found\n'),
        exitCode: 127,
      ),
    };
  }

  Future<_StageResult> _git(_Context ctx) async {
    final result = await _gitCommands.run(
      ctx.args,
      cwd: ctx.cwd,
      env: _effectiveEnv(ctx.options),
    );
    return _StageResult(
      stdout: utf8.encode(result.stdout),
      stderr: utf8.encode(result.stderr),
      exitCode: result.exitCode,
    );
  }

  // ---------------------------------------------------------------------------
  // Shared network/JSON builtins (curl, wget, jq, yq)
  // ---------------------------------------------------------------------------

  /// Wires the shared [SandboxBuiltins] to the in-memory filesystem, resolving
  /// paths against the stage's working directory.
  SandboxBuiltins _builtinsFor(_Context ctx) {
    return SandboxBuiltins(
      httpClient: _httpClient,
      readTextFile: (path) async {
        final result = await _fs.readTextFile(
          _resolveSandboxPath(path, ctx.cwd),
        );
        return result.valueOrNull;
      },
      writeBinaryFile: (path, bytes) async {
        await _fs.writeBinaryFile(
          _resolveSandboxPath(path, ctx.cwd),
          Uint8List.fromList(bytes),
        );
      },
      readBinaryFile: (path) async => (await _fs.readBinaryFile(
        _resolveSandboxPath(path, ctx.cwd),
      )).valueOrNull,
      listDirectory: (path) async => (await _fs.listDir(
        _resolveSandboxPath(path, ctx.cwd),
      )).valueOrNull?.map(_dirEntry).toList(),
      removeFile: (path) async {
        await _fs.remove(_resolveSandboxPath(path, ctx.cwd));
      },
      makeDirectory: (path) async {
        await _fs.createDir(_resolveSandboxPath(path, ctx.cwd));
      },
    );
  }

  Future<_StageResult> _toStage(Future<SandboxBuiltinResult> future) async {
    final r = await future;
    return _StageResult(
      stdout: r.stdout,
      stderr: r.stderr,
      exitCode: r.exitCode,
    );
  }

  static SandboxDirEntry _dirEntry(FileInfo e) =>
      (name: e.name, isDirectory: e.kind == FileKind.directory);

  Future<_StageResult> _curl(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).curl(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _wget(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).wget(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _jq(_Context ctx) {
    return _toStage(_builtinsFor(ctx).jq(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _yq(_Context ctx) {
    return _toStage(_builtinsFor(ctx).yq(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _diff(_Context ctx) {
    return _toStage(_builtinsFor(ctx).diff(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _patch(_Context ctx) {
    return _toStage(_builtinsFor(ctx).patch(ctx.args, stdin: ctx.stdin));
  }

  Future<_StageResult> _nslookup(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).nslookup(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _dig(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).dig(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _whois(_Context ctx) {
    return _toStage(
      _builtinsFor(ctx).whois(ctx.args, timeout: ctx.options?.timeout),
    );
  }

  Future<_StageResult> _xz(_Context ctx, {required bool decompress}) =>
      _toStage(_builtinsFor(ctx).xz(ctx.args, decompress: decompress));

  Future<_StageResult> _bzip2(_Context ctx, {required bool decompress}) =>
      _toStage(_builtinsFor(ctx).bzip2(ctx.args, decompress: decompress));

  Future<_StageResult> _hashsum(String command, _Context ctx) =>
      _toStage(_builtinsFor(ctx).hashsum(command, ctx.args, stdin: ctx.stdin));

  // ---------------------------------------------------------------------------
  // sqlite3 (sql.js in the browser)
  // ---------------------------------------------------------------------------

  Future<_StageResult> _runSqlite(_Context ctx) async {
    final args = ctx.args;
    if (args.contains('--version') || args.contains('-version')) {
      final version = await WebInterpreters.sqliteVersion();
      if (version == null) return _interpreterUnavailable('sqlite3');
      return _text('$version (fah-sandbox sql.js)\n');
    }

    final positionals = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-cmd' && i + 1 < args.length) {
        // Accepted for parity with the WASM sqlite3; init commands are not
        // needed because the full SQL arrives as one argument or via stdin.
        i++;
      } else if (arg == '-csv' || arg == '-list' || arg == '-readonly') {
        // Output stays in the default `|`-separated list mode.
      } else if (arg.startsWith('-') && arg != '-') {
        return _error('sqlite3: unsupported option $arg\n', exitCode: 1);
      } else {
        positionals.add(arg);
      }
    }

    final dbPath = positionals.isNotEmpty ? positionals[0] : null;
    var sql = positionals.length > 1
        ? positionals.sublist(1).join(' ')
        : ctx.stdin;
    sql ??= '';

    Uint8List? dbBytes;
    String? resolvedDb;
    if (dbPath != null && dbPath != ':memory:') {
      resolvedDb = _resolveSandboxPath(dbPath, ctx.cwd);
      final read = await _fs.readBinaryFile(resolvedDb);
      if (read.isOk) dbBytes = read.valueOrNull;
    }

    final result = await WebInterpreters.runSqlite(sql, dbBytes);
    if (!result.available) return _interpreterUnavailable('sqlite3');

    // sql.js is in-memory: serialize the database back to the sandbox file
    // after every invocation so it persists across exec calls.
    if (resolvedDb != null && result.dbBytes != null) {
      await _fs.writeBinaryFile(resolvedDb, result.dbBytes!);
    }

    final hasError = result.stderr.isNotEmpty;
    return _StageResult(
      stdout: utf8.encode(result.stdout.isEmpty ? '' : '${result.stdout}\n'),
      stderr: utf8.encode(hasError ? 'Error: ${result.stderr}\n' : ''),
      exitCode: hasError ? 1 : 0,
    );
  }

  // ---------------------------------------------------------------------------
  // Text stream utilities (sed, awk, printf)
  // ---------------------------------------------------------------------------

  _StageResult _printf(_Context ctx) {
    if (ctx.args.isEmpty) {
      return _error('usage: printf format [arguments...]\n');
    }
    final format = _unescapePrintf(ctx.args.first);
    final args = ctx.args.sublist(1);
    final out = StringBuffer();
    var argIndex = 0;
    // The format string is reused until every argument is consumed (POSIX).
    while (true) {
      final consumedBefore = argIndex;
      for (var i = 0; i < format.length; i++) {
        final ch = format[i];
        if (ch == '%' && i + 1 < format.length) {
          final spec = format[i + 1];
          if (spec == '%') {
            out.write('%');
            i++;
            continue;
          }
          final arg = argIndex < args.length ? args[argIndex] : '';
          switch (spec) {
            case 's':
              argIndex++;
              out.write(arg);
            case 'd' || 'i':
              argIndex++;
              out.write(int.tryParse(arg) ?? 0);
            case 'c':
              argIndex++;
              if (arg.isNotEmpty) out.write(arg[0]);
            default:
              out.write('%');
              out.write(spec);
          }
          i++;
          continue;
        }
        out.write(ch);
      }
      if (argIndex >= args.length || argIndex == consumedBefore) break;
    }
    return _text(out.toString());
  }

  /// Interprets the backslash escapes printf understands in its format
  /// string (`\n`, `\t`, `\r`, `\\`, `\0`).
  String _unescapePrintf(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      if (input[i] == '\\' && i + 1 < input.length) {
        final escape = switch (input[i + 1]) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          '0' => '\x00',
          '\\' => '\\',
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

  Future<_StageResult> _sed(_Context ctx) async {
    var quiet = false;
    var inPlace = false;
    final scripts = <String>[];
    final files = <String>[];

    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-n' || arg == '--quiet' || arg == '--silent') {
        quiet = true;
      } else if (arg == '-i' || arg.startsWith('-i')) {
        inPlace = true;
      } else if (arg == '-e') {
        if (i + 1 >= ctx.args.length) {
          return _error('sed: option requires an argument -- e\n', exitCode: 1);
        }
        scripts.add(ctx.args[++i]);
      } else if (arg.startsWith('-e')) {
        scripts.add(arg.substring(2));
      } else if (arg == '-E' || arg == '-r') {
        // Extended regex is the only syntax this subset supports anyway.
      } else if (arg == '--') {
        // End of options.
      } else if (arg.startsWith('-') && arg != '-') {
        return _error('sed: unsupported option $arg\n', exitCode: 1);
      } else if (scripts.isEmpty && files.isEmpty) {
        scripts.add(arg);
      } else {
        files.add(arg);
      }
    }

    if (scripts.isEmpty) {
      return _error(
        'usage: sed [-n] [-i] [-e script] [script] [file...]\n',
        exitCode: 1,
      );
    }
    if (inPlace && files.isEmpty) {
      return _error('sed: -i requires file arguments\n', exitCode: 1);
    }

    final commands = <_SedCommand>[];
    for (final script in scripts) {
      final command = _SedCommand.tryParse(script);
      if (command == null) {
        return _error('sed: unsupported script: $script\n', exitCode: 1);
      }
      commands.add(command);
    }

    if (inPlace) {
      for (final arg in files) {
        final resolved = _resolveSandboxPath(arg, ctx.cwd);
        final read = await _fs.readTextFile(resolved);
        if (read.isErr) {
          return _error('sed: $arg: No such file or directory\n');
        }
        final result = _runSed(read.valueOrNull!, commands, quiet: false);
        await _fs.writeFile(resolved, result);
      }
      return _ok;
    }

    String? errorPath;
    final input = await _readInput(files, ctx, (path) => errorPath = path);
    if (input == null) {
      return _error('sed: $errorPath: No such file or directory\n');
    }
    return _text(_runSed(input, commands, quiet: quiet));
  }

  /// Applies [commands] to [input] line by line; auto-prints each line
  /// unless [quiet] (`-n`) is set. Always ends the output with a newline
  /// when the input was non-empty, mirroring GNU sed.
  String _runSed(
    String input,
    List<_SedCommand> commands, {
    bool quiet = false,
  }) {
    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final out = StringBuffer();
    final ranges = <_SedCommand, bool>{};
    for (var n = 0; n < lines.length; n++) {
      var line = lines[n];
      final lineNo = n + 1;
      final isLast = n == lines.length - 1;
      for (final command in commands) {
        final selected = command.select(lineNo, isLast, line, ranges);
        if (!selected) continue;
        switch (command.kind) {
          case _SedKind.substitute:
            line = command.applySubstitute(line);
          case _SedKind.print:
            out.writeln(line);
        }
      }
      if (!quiet) out.writeln(line);
    }
    return out.toString();
  }

  Future<_StageResult> _awk(_Context ctx) async {
    String? fieldSeparator;
    final positionals = <String>[];
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-F') {
        if (i + 1 >= ctx.args.length) {
          return _error('awk: option requires an argument -- F\n', exitCode: 2);
        }
        fieldSeparator = ctx.args[++i];
      } else if (arg.startsWith('-F')) {
        fieldSeparator = arg.substring(2);
      } else if (arg.startsWith('-') && arg != '-') {
        return _error('awk: unsupported option $arg\n', exitCode: 2);
      } else {
        positionals.add(arg);
      }
    }
    if (fieldSeparator == r'\t') fieldSeparator = '\t';

    if (positionals.isEmpty) {
      return _error('usage: awk [-F sep] program [file...]\n', exitCode: 2);
    }
    final program = positionals.first;
    final files = positionals.sublist(1);

    var body = program.trim();
    RegExp? pattern;
    if (body.startsWith('/')) {
      final end = body.indexOf('/', 1);
      if (end <= 1) {
        return _error('awk: bad pattern in program\n', exitCode: 2);
      }
      try {
        pattern = RegExp(body.substring(1, end));
      } on Object catch (e) {
        return _error('awk: bad pattern: $e\n', exitCode: 2);
      }
      body = body.substring(end + 1).trim();
    }
    // A pattern without an action prints the whole record.
    var printExpr = r'$0';
    if (body.isNotEmpty) {
      if (!body.startsWith('{') || !body.endsWith('}')) {
        return _error('awk: unsupported program: $program\n', exitCode: 2);
      }
      final action = body.substring(1, body.length - 1).trim();
      if (action != 'print' && !action.startsWith('print ')) {
        return _error('awk: unsupported action: $action\n', exitCode: 2);
      }
      printExpr = action == 'print' ? r'$0' : action.substring(6).trim();
    }

    String? errorPath;
    final input = await _readInput(files, ctx, (path) => errorPath = path);
    if (input == null) {
      return _error('awk: cannot open $errorPath: No such file or directory\n');
    }

    final lines = input.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final out = StringBuffer();
    for (var n = 0; n < lines.length; n++) {
      final line = lines[n];
      if (pattern != null && !pattern.hasMatch(line)) continue;
      final trimmed = line.trim();
      final fields = fieldSeparator != null
          ? line.split(fieldSeparator)
          : (trimmed.isEmpty ? <String>[] : trimmed.split(RegExp(r'\s+')));
      final record = _AwkRecord(line: line, fields: fields, nr: n + 1);
      final values = [
        for (final expr in _awkSplitTopLevel(printExpr)) _awkEval(expr, record),
      ];
      out.writeln(values.join(' '));
    }
    return _text(out.toString());
  }

  /// Splits a print list on top-level commas (commas join fields with OFS,
  /// a single space here).
  List<String> _awkSplitTopLevel(String expr) {
    final parts = <String>[];
    var depth = 0;
    var inString = false;
    var start = 0;
    for (var i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (ch == '"') inString = !inString;
      if (inString) continue;
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == ',' && depth == 0) {
        parts.add(expr.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(expr.substring(start));
    return parts;
  }

  /// Evaluates a tiny awk expression: an additive chain of terms (`$N`,
  /// `$0`, `NR`, `NF`, numbers, "strings") or their concatenation.
  String _awkEval(String expr, _AwkRecord record) {
    final tokens = _awkTokens(expr);
    if (tokens.isEmpty) return '';
    if (tokens.any((t) => t == '+' || t == '-')) {
      var total = 0.0;
      var op = '+';
      for (final token in tokens) {
        if (token == '+' || token == '-') {
          op = token;
          continue;
        }
        final value = _awkTermValue(token, record);
        final number = value is num ? value : num.tryParse('$value') ?? 0;
        total = op == '+' ? total + number : total - number;
      }
      return total == total.roundToDouble()
          ? total.toInt().toString()
          : total.toString();
    }
    return tokens.map((t) => '${_awkTermValue(t, record)}').join();
  }

  List<String> _awkTokens(String expr) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var inString = false;
    void flush() {
      if (buffer.isEmpty) return;
      tokens.add(buffer.toString());
      buffer.clear();
    }

    for (var i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (ch == '"') {
        buffer.write(ch);
        inString = !inString;
        continue;
      }
      if (!inString && (ch == '+' || ch == '-' || ch == ' ' || ch == '\t')) {
        flush();
        if (ch == '+' || ch == '-') tokens.add(ch);
        continue;
      }
      buffer.write(ch);
    }
    flush();
    return tokens;
  }

  Object _awkTermValue(String token, _AwkRecord record) {
    final term = token.trim();
    if (term.length >= 2 && term.startsWith('"') && term.endsWith('"')) {
      return term.substring(1, term.length - 1);
    }
    if (term == 'NR') return record.nr;
    if (term == 'NF') return record.fields.length;
    if (term.startsWith(r'$')) {
      final index = int.tryParse(term.substring(1));
      if (index == null) return '';
      if (index == 0) return record.line;
      return index <= record.fields.length ? record.fields[index - 1] : '';
    }
    final number = num.tryParse(term);
    if (number != null) return number;
    return term;
  }

  // ---------------------------------------------------------------------------
  // Filesystem utilities (find, realpath)
  // ---------------------------------------------------------------------------

  Future<_StageResult> _find(_Context ctx) async {
    final paths = <String>[];
    String? namePattern;
    String? type;
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-name' && i + 1 < ctx.args.length) {
        namePattern = ctx.args[++i];
      } else if (arg == '-type' && i + 1 < ctx.args.length) {
        type = ctx.args[++i];
      } else if (arg.startsWith('-')) {
        return _error('find: unsupported option $arg\n', exitCode: 1);
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('.');

    final nameRegex = namePattern == null ? null : _globToRegex(namePattern);
    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;

    Future<void> walk(String resolved, String display, FileInfo info) async {
      final typeOk =
          type == null ||
          (type == 'f' && info.kind == FileKind.file) ||
          (type == 'd' && info.kind == FileKind.directory);
      final nameOk = nameRegex == null || nameRegex.hasMatch(info.name);
      if (typeOk && nameOk) out.writeln(display);
      if (info.kind != FileKind.directory) return;
      final entries = await _fs.listDir(resolved);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
        final childResolved = resolved == '/'
            ? '/${entry.name}'
            : '$resolved/${entry.name}';
        final childDisplay = display == '/'
            ? '/${entry.name}'
            : '$display/${entry.name}';
        await walk(childResolved, childDisplay, entry);
      }
    }

    for (final arg in paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        err.write('find: $arg: No such file or directory\n');
        exitCode = 1;
        continue;
      }
      await walk(resolved, arg, info.valueOrNull!);
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

  /// Converts a `find -name` glob (`*`, `?`) into an anchored [RegExp].
  RegExp _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '*') {
        buffer.write('.*');
      } else if (ch == '?') {
        buffer.write('.');
      } else {
        buffer.write(RegExp.escape(ch));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  Future<_StageResult> _realpath(_Context ctx) async {
    final split = _splitArgs(ctx.args);
    if (split.paths.isEmpty) {
      return _error('realpath: missing operand\n');
    }
    final out = StringBuffer();
    for (final arg in split.paths) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final exists = await _fs.exists(resolved);
      if (!(exists.valueOrNull ?? false)) {
        return _error('realpath: $arg: No such file or directory\n');
      }
      out.writeln(resolved);
    }
    return _text(out.toString());
  }

  // ---------------------------------------------------------------------------
  // xargs
  // ---------------------------------------------------------------------------

  Future<_StageResult> _xargs(_Context ctx) async {
    var batchSize = 0;
    var utilityArgs = const <String>[];
    for (var i = 0; i < ctx.args.length; i++) {
      final arg = ctx.args[i];
      if (arg == '-n' && i + 1 < ctx.args.length) {
        batchSize = int.tryParse(ctx.args[++i]) ?? 0;
      } else if (arg.startsWith('-n') &&
          int.tryParse(arg.substring(2)) != null) {
        batchSize = int.parse(arg.substring(2));
      } else {
        utilityArgs = ctx.args.sublist(i);
        break;
      }
    }

    final tokens = (ctx.stdin ?? '')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final command = utilityArgs.isEmpty ? 'echo' : utilityArgs.first;
    final prefixArgs = utilityArgs.isEmpty
        ? const <String>[]
        : utilityArgs.sublist(1);

    final batches = <List<String>>[
      if (tokens.isEmpty)
        const <String>[]
      else if (batchSize > 0)
        for (var i = 0; i < tokens.length; i += batchSize)
          tokens.sublist(
            i,
            i + batchSize > tokens.length ? tokens.length : i + batchSize,
          )
      else
        tokens,
    ];

    final out = StringBuffer();
    final err = StringBuffer();
    var exitCode = 0;
    for (final batch in batches) {
      final result = await _runCommand(
        command,
        [...prefixArgs, ...batch],
        ctx.options,
        ctx.cwd,
        null,
      );
      out.write(utf8.decode(result.stdout, allowMalformed: true));
      err.write(utf8.decode(result.stderr, allowMalformed: true));
      if (result.exitCode != 0) exitCode = result.exitCode;
    }
    return _StageResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: exitCode,
    );
  }

  // ---------------------------------------------------------------------------
  // Archives (tar, gzip, zip) via package:archive
  // ---------------------------------------------------------------------------

  Future<_StageResult> _tar(_Context ctx) async {
    if (ctx.args.isEmpty) {
      return _error('tar: no operation specified\n', exitCode: 2);
    }
    var index = 0;
    var flags = '';
    final first = ctx.args.first;
    if (first.startsWith('-')) {
      flags = first.substring(1);
      index = 1;
    } else if (RegExp(r'^[a-zA-Z]+$').hasMatch(first) &&
        first.contains(RegExp(r'[ctx]'))) {
      // Old-style `tar cf ...` without a dash.
      flags = first;
      index = 1;
    }
    final create = flags.contains('c');
    final extract = flags.contains('x');
    final compressed = flags.contains('z');
    if (create == extract) {
      return _error('tar: specify exactly one of -c or -x\n', exitCode: 2);
    }

    String? archiveArg;
    if (flags.contains('f')) {
      if (index >= ctx.args.length) {
        return _error('tar: option requires an argument -- f\n', exitCode: 2);
      }
      archiveArg = ctx.args[index++];
    }
    String? changeDir;
    final members = <String>[];
    for (; index < ctx.args.length; index++) {
      final arg = ctx.args[index];
      if (arg == '-C' && index + 1 < ctx.args.length) {
        changeDir = ctx.args[++index];
      } else {
        members.add(arg);
      }
    }
    if (archiveArg == null) {
      return _error('tar: no archive file specified (use -f)\n', exitCode: 2);
    }
    final archivePath = _resolveSandboxPath(archiveArg, ctx.cwd);

    if (create) {
      if (members.isEmpty) {
        return _error(
          'tar: Cowardly refusing to create an empty archive\n',
          exitCode: 2,
        );
      }
      final archive = Archive();
      for (final member in members) {
        final resolved = _resolveSandboxPath(member, ctx.cwd);
        final info = await _fs.fileInfo(resolved);
        if (info.isErr) {
          return _error(
            'tar: $member: Cannot stat: No such file or directory\n',
            exitCode: 1,
          );
        }
        await _tarAdd(archive, resolved, info.valueOrNull!);
      }
      var bytes = TarEncoder().encode(archive);
      if (compressed) bytes = GZipEncoder().encode(bytes);
      await _fs.writeBinaryFile(archivePath, Uint8List.fromList(bytes));
      return _ok;
    }

    final read = await _fs.readBinaryFile(archivePath);
    if (read.isErr) {
      return _error(
        'tar: $archiveArg: Cannot open: No such file or directory\n',
        exitCode: 1,
      );
    }
    var bytes = read.valueOrNull!;
    if (compressed) {
      try {
        bytes = Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
      } on Object {
        return _error('tar: $archiveArg: not in gzip format\n', exitCode: 1);
      }
    }
    final Archive archive;
    try {
      archive = TarDecoder().decodeBytes(bytes);
    } on Object {
      return _error('tar: $archiveArg: not in tar format\n', exitCode: 1);
    }
    final root = changeDir != null
        ? _resolveSandboxPath(changeDir, ctx.cwd)
        : _resolveSandboxPath('.', ctx.cwd);
    for (final file in archive.files) {
      final name = file.name.startsWith('/')
          ? file.name.substring(1)
          : file.name;
      if (!file.isFile) {
        await _fs.createDir('$root/$name');
        continue;
      }
      await _fs.writeBinaryFile('$root/$name', file.content);
    }
    return _ok;
  }

  /// Adds [resolved] (and its children when it is a directory) to [archive],
  /// stripping the leading `/` from member names like GNU tar does.
  Future<void> _tarAdd(Archive archive, String resolved, FileInfo info) async {
    final name = resolved.startsWith('/') ? resolved.substring(1) : resolved;
    if (info.kind == FileKind.directory) {
      archive.addFile(ArchiveFile('$name/', 0, const <int>[])..isFile = false);
      final entries = await _fs.listDir(resolved);
      for (final entry in entries.valueOrNull ?? <FileInfo>[]) {
        await _tarAdd(archive, '$resolved/${entry.name}', entry);
      }
      return;
    }
    final data = await _fs.readBinaryFile(resolved);
    if (data.isErr) return;
    final bytes = data.valueOrNull!;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  Future<_StageResult> _gzip(_Context ctx, {required bool decompress}) async {
    var unpack = decompress;
    var keep = false;
    final files = <String>[];
    for (final arg in ctx.args) {
      if (arg == '-d' || arg == '--decompress' || arg == '--uncompress') {
        unpack = true;
      } else if (arg == '-k' || arg == '--keep') {
        keep = true;
      } else if (RegExp(r'^-[1-9]$').hasMatch(arg)) {
        // Compression level; irrelevant for the in-memory subset.
      } else if (arg.startsWith('-') && arg != '-') {
        return _error('gzip: unsupported option $arg\n', exitCode: 1);
      } else {
        files.add(arg);
      }
    }
    final name = unpack ? 'gunzip' : 'gzip';
    if (files.isEmpty) {
      return _error('$name: missing operand\n', exitCode: 1);
    }
    for (final arg in files) {
      final resolved = _resolveSandboxPath(arg, ctx.cwd);
      final read = await _fs.readBinaryFile(resolved);
      if (read.isErr) {
        return _error('$name: $arg: No such file or directory\n', exitCode: 1);
      }
      if (!unpack) {
        final encoded = GZipEncoder().encode(read.valueOrNull!);
        await _fs.writeBinaryFile('$resolved.gz', Uint8List.fromList(encoded));
        if (!keep) await _fs.remove(resolved);
        continue;
      }
      if (!resolved.endsWith('.gz')) {
        return _error('gzip: $arg: unknown suffix -- ignored\n', exitCode: 1);
      }
      final List<int> decoded;
      try {
        decoded = GZipDecoder().decodeBytes(read.valueOrNull!);
      } on Object {
        return _error('gzip: $arg: not in gzip format\n', exitCode: 1);
      }
      final dest = resolved.substring(0, resolved.length - 3);
      await _fs.writeBinaryFile(dest, Uint8List.fromList(decoded));
      if (!keep) await _fs.remove(resolved);
    }
    return _ok;
  }

  Future<_StageResult> _zip(_Context ctx) async {
    var recursive = false;
    final positionals = <String>[];
    for (final arg in ctx.args) {
      if (arg.startsWith('-') && arg != '-') {
        if (arg.contains('r') || arg.contains('R')) recursive = true;
        // Other flags (quiet, compression level, ...) are accepted and
        // ignored by this subset.
      } else {
        positionals.add(arg);
      }
    }
    if (positionals.length < 2) {
      return _error(
        'zip error: Nothing to do! (usage: zip [-r] archive.zip file...)\n',
        exitCode: 1,
      );
    }
    final archivePath = _resolveSandboxPath(positionals.first, ctx.cwd);
    final archive = Archive();
    for (final member in positionals.sublist(1)) {
      final resolved = _resolveSandboxPath(member, ctx.cwd);
      final info = await _fs.fileInfo(resolved);
      if (info.isErr) {
        return _error(
          'zip error: Nothing to do! ($member: No such file or directory)\n',
          exitCode: 1,
        );
      }
      final fileInfo = info.valueOrNull!;
      if (fileInfo.kind == FileKind.directory && !recursive) {
        return _error(
          'zip error: Nothing to do! ($member is a directory; use -r)\n',
          exitCode: 1,
        );
      }
      await _tarAdd(archive, resolved, fileInfo);
    }
    final bytes = ZipEncoder().encode(archive);
    await _fs.writeBinaryFile(archivePath, Uint8List.fromList(bytes));
    return _ok;
  }

  Future<_StageResult> _runPython(_Context ctx) async {
    final args = ctx.args;
    if (args.contains('--version') || args.contains('-V')) {
      final version = await WebInterpreters.pythonVersion();
      if (version == null) return _interpreterUnavailable('python3');
      return _text('Python $version\n');
    }

    final code = await _interpreterCode(args, ctx, flag: '-c');
    if (code == null) {
      return _error(
        'usage: python3 [--version] [-c code] [script.py] [args...]\n',
        exitCode: 2,
      );
    }
    final result = await WebInterpreters.runPython(code);
    if (!result.available) return _interpreterUnavailable('python3');
    final hasError = result.stderr.isNotEmpty;
    return _StageResult(
      stdout: utf8.encode(result.stdout.isEmpty ? '' : '${result.stdout}\n'),
      stderr: utf8.encode(result.stderr.isEmpty ? '' : '${result.stderr}\n'),
      exitCode: hasError ? 1 : 0,
    );
  }

  /// pip-lite for the web sandbox: installs pure-Python wheels through
  /// pyodide's micropip (loaded from the CDN on first real use; usage errors
  /// short-circuit before any network). See `sandbox_pip.dart`.
  Future<_StageResult> _runPip(_Context ctx) async {
    final r = await WebInterpreters.runPip(ctx.args);
    if (!r.available) return _interpreterUnavailable('pip');
    return _StageResult(
      stdout: utf8.encode(r.stdout),
      stderr: utf8.encode(r.stderr),
      exitCode: r.exitCode,
    );
  }

  Future<_StageResult> _runQjs(_Context ctx) async {
    final args = ctx.args;
    if (args.contains('--version') || args.contains('-v')) {
      final version = await WebInterpreters.qjsVersion();
      if (version == null) return _interpreterUnavailable('qjs');
      return _text('$version\n');
    }

    final code = await _interpreterCode(args, ctx, flag: '-e');
    if (code == null) {
      return _error(
        'usage: qjs [--version] [-e code] [script.js] [args...]\n',
        exitCode: 2,
      );
    }
    final result = await WebInterpreters.runQjs(code);
    if (!result.available) return _interpreterUnavailable('qjs');
    final hasError = result.stderr.isNotEmpty;
    return _StageResult(
      stdout: utf8.encode(result.stdout.isEmpty ? '' : '${result.stdout}\n'),
      stderr: utf8.encode(result.stderr.isEmpty ? '' : '${result.stderr}\n'),
      exitCode: hasError ? 1 : 0,
    );
  }

  /// Extracts the code to run: inline via [flag], or a script file's content.
  Future<String?> _interpreterCode(
    List<String> args,
    _Context ctx, {
    required String flag,
  }) async {
    for (var i = 0; i < args.length; i++) {
      if (args[i] == flag) {
        if (i + 1 < args.length) return args[i + 1];
        return null;
      }
      if (args[i].startsWith('-')) continue;
      final resolved = _resolveSandboxPath(args[i], ctx.cwd);
      final read = await _fs.readTextFile(resolved);
      if (read.isErr) return null;
      return read.valueOrNull!;
    }
    return null;
  }

  _StageResult _interpreterUnavailable(String name) {
    return _StageResult(
      stdout: const [],
      stderr: utf8.encode('$name: command not found\n'),
      exitCode: 127,
    );
  }

  /// ssh/scp/sftp exist in the web command set (so `which` reports them and
  /// the agent can react) but raw TCP is impossible in a browser, so every
  /// invocation fails with exit code 127.
  _StageResult _sshUnavailable(String name) {
    return _StageResult(
      stdout: const [],
      stderr: utf8.encode(
        '$name: not available in the web sandbox '
        '(browsers cannot open raw TCP connections)\n',
      ),
      exitCode: 127,
    );
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

/// One awk record: the current line, its fields, and its 1-based number.
final class _AwkRecord {
  const _AwkRecord({
    required this.line,
    required this.fields,
    required this.nr,
  });

  final String line;
  final List<String> fields;
  final int nr;
}

/// The sed commands this subset supports.
enum _SedKind { substitute, print }

/// A parsed sed command: an optional address range plus `s/pat/repl/[g]` or
/// `p`. Addresses are 1-based line numbers, `$` (last line), or `/regex/`.
final class _SedCommand {
  const _SedCommand._({
    required this.kind,
    this.startLine,
    this.endLine,
    this.startLast = false,
    this.endLast = false,
    this.startRegex,
    this.endRegex,
    this.pattern,
    this.replacement,
    this.global = false,
  });

  final _SedKind kind;
  final int? startLine;
  final int? endLine;
  final bool startLast;
  final bool endLast;
  final RegExp? startRegex;
  final RegExp? endRegex;
  final RegExp? pattern;
  final String? replacement;
  final bool global;

  /// Parses `[addr[,addr]]cmd`; returns `null` for unsupported scripts.
  static _SedCommand? tryParse(String script) {
    var i = 0;

    ({int? line, bool last, RegExp? regex})? readAddress() {
      if (i >= script.length) return null;
      final ch = script[i];
      if (ch == r'$') {
        i++;
        return (line: null, last: true, regex: null);
      }
      if (ch == '/') {
        final end = script.indexOf('/', i + 1);
        if (end < 0) return null;
        final RegExp regex;
        try {
          regex = RegExp(script.substring(i + 1, end));
        } on Object {
          return null;
        }
        i = end + 1;
        return (line: null, last: false, regex: regex);
      }
      if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) {
        var end = i;
        while (end < script.length &&
            script[end].codeUnitAt(0) >= 48 &&
            script[end].codeUnitAt(0) <= 57) {
          end++;
        }
        final line = int.parse(script.substring(i, end));
        i = end;
        return (line: line, last: false, regex: null);
      }
      return null;
    }

    final start = readAddress();
    ({int? line, bool last, RegExp? regex})? end;
    if (i < script.length && script[i] == ',') {
      i++;
      end = readAddress();
      if (end == null) return null;
    }
    if (i >= script.length) return null;

    final command = script[i];
    if (command == 'p') {
      if (i + 1 != script.length) return null;
      return _SedCommand._(
        kind: _SedKind.print,
        startLine: start?.line,
        endLine: end?.line,
        startLast: start?.last ?? false,
        endLast: end?.last ?? false,
        startRegex: start?.regex,
        endRegex: end?.regex,
      );
    }
    if (command != 's') return null;
    if (i + 1 >= script.length) return null;
    final delimiter = script[i + 1];
    String? scan(int from) {
      final buffer = StringBuffer();
      var j = from;
      while (j < script.length) {
        if (script[j] == '\\' && j + 1 < script.length) {
          buffer
            ..write(script[j])
            ..write(script[j + 1]);
          j += 2;
          continue;
        }
        if (script[j] == delimiter) return buffer.toString();
        buffer.write(script[j]);
        j++;
      }
      return null;
    }

    final patternStart = i + 2;
    final patternSource = scan(patternStart);
    if (patternSource == null) return null;
    // Advance past the pattern and its closing delimiter.
    var j = patternStart;
    while (j < script.length) {
      if (script[j] == '\\' && j + 1 < script.length) {
        j += 2;
        continue;
      }
      if (script[j] == delimiter) break;
      j++;
    }
    if (j >= script.length) return null;
    final replacement = scan(j + 1);
    if (replacement == null) return null;
    j++;
    while (j < script.length) {
      if (script[j] == '\\' && j + 1 < script.length) {
        j += 2;
        continue;
      }
      if (script[j] == delimiter) break;
      j++;
    }
    if (j >= script.length) return null;
    final flags = script.substring(j + 1);
    if (flags.isNotEmpty && flags != 'g') return null;

    final RegExp regex;
    try {
      regex = RegExp(patternSource);
    } on Object {
      return null;
    }
    return _SedCommand._(
      kind: _SedKind.substitute,
      startLine: start?.line,
      endLine: end?.line,
      startLast: start?.last ?? false,
      endLast: end?.last ?? false,
      startRegex: start?.regex,
      endRegex: end?.regex,
      pattern: regex,
      replacement: replacement,
      global: flags == 'g',
    );
  }

  bool _addressMatches(
    int? line,
    bool last,
    RegExp? regex,
    int lineNo,
    bool isLast,
    String text,
  ) {
    if (last) return isLast;
    if (regex != null) return regex.hasMatch(text);
    if (line != null) return lineNo == line;
    return true;
  }

  /// Whether this command applies to [lineNo]; [ranges] tracks open address
  /// ranges across lines.
  bool select(
    int lineNo,
    bool isLast,
    String text,
    Map<_SedCommand, bool> ranges,
  ) {
    final hasStart = startLine != null || startLast || startRegex != null;
    final hasEnd = endLine != null || endLast || endRegex != null;
    if (!hasStart) return true;
    if (!hasEnd) {
      return _addressMatches(
        startLine,
        startLast,
        startRegex,
        lineNo,
        isLast,
        text,
      );
    }
    var active = ranges[this] ?? false;
    if (!active &&
        _addressMatches(
          startLine,
          startLast,
          startRegex,
          lineNo,
          isLast,
          text,
        )) {
      active = true;
      ranges[this] = true;
      // A same-line end (e.g. `2,2`) closes the range immediately.
      if (_addressMatches(endLine, endLast, endRegex, lineNo, isLast, text)) {
        ranges[this] = false;
      }
      return true;
    }
    if (active) {
      if (_addressMatches(endLine, endLast, endRegex, lineNo, isLast, text)) {
        ranges[this] = false;
      }
      return true;
    }
    return false;
  }

  /// Applies the substitution to [line]; `&` and `\N` in the replacement
  /// reference the whole match and capture groups like POSIX sed.
  String applySubstitute(String line) {
    final regex = pattern!;
    final replacement = this.replacement!;

    String expand(Match match) {
      final buffer = StringBuffer();
      for (var i = 0; i < replacement.length; i++) {
        final ch = replacement[i];
        if (ch == '&') {
          buffer.write(match[0]);
          continue;
        }
        if (ch == '\\' && i + 1 < replacement.length) {
          final next = replacement[i + 1];
          final code = next.codeUnitAt(0);
          if (code >= 49 && code <= 57) {
            buffer.write(match[int.parse(next)] ?? '');
          } else if (next == 'n') {
            buffer.write('\n');
          } else if (next == 't') {
            buffer.write('\t');
          } else {
            buffer.write(next);
          }
          i++;
          continue;
        }
        buffer.write(ch);
      }
      return buffer.toString();
    }

    if (global) return line.replaceAllMapped(regex, expand);
    final match = regex.firstMatch(line);
    if (match == null) return line;
    return line.replaceRange(match.start, match.end, expand(match));
  }
}
