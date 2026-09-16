// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../web_interpreters_stub.dart'
    if (dart.library.html) '../web_interpreters_web.dart';

import 'paths.dart';

/// A neutral command result: plain text the shell wraps into bytes.
typedef InterpreterOutcome = ({String stdout, String stderr, int exitCode});

/// The error/exit pair a utility driver turns into a `_StageResult`.
typedef CommandError = ({String message, int exitCode});

InterpreterOutcome _unavailable(String name) =>
    (stdout: '', stderr: '$name: command not found\n', exitCode: 127);

/// The parsed `sqlite3` command line (pure): `--version`, options, the
/// database path, and the SQL (joined positionals or stdin).
typedef SqliteArgs = ({
  bool wantVersion,
  String? dbPath,
  String sql,
  CommandError? error,
});

SqliteArgs parseSqliteArgs(List<String> args, {required String? stdin}) {
  if (args.contains('--version') || args.contains('-version')) {
    return (wantVersion: true, dbPath: null, sql: '', error: null);
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
      return (
        wantVersion: false,
        dbPath: null,
        sql: '',
        error: (message: 'sqlite3: unsupported option $arg\n', exitCode: 1),
      );
    } else {
      positionals.add(arg);
    }
  }

  final dbPath = positionals.isNotEmpty ? positionals[0] : null;
  final sql = positionals.length > 1
      ? positionals.sublist(1).join(' ')
      : (stdin ?? '');
  return (wantVersion: false, dbPath: dbPath, sql: sql, error: null);
}

/// Reads the database file the invocation names (`:memory:` names no file).
Future<Uint8List?> _readSqliteDb(
  MemoryFileSystem fs,
  String cwd,
  String? dbPath,
) async {
  if (dbPath == null || dbPath == ':memory:') return null;
  final read = await fs.readBinaryFile(resolveSandboxPath(dbPath, cwd));
  return read.isOk ? read.valueOrNull : null;
}

/// Persists the exported database back after every invocation so it
/// survives across exec calls (sql.js keeps it in memory only).
Future<void> _writeBackSqliteDb(
  MemoryFileSystem fs,
  String cwd,
  String? dbPath,
  Uint8List? dbBytes,
) async {
  if (dbPath == null || dbPath == ':memory:' || dbBytes == null) return;
  await fs.writeBinaryFile(resolveSandboxPath(dbPath, cwd), dbBytes);
}

/// Shapes a sql.js run: a non-empty stderr is a SQL error with exit 1.
InterpreterOutcome _sqliteOutcome(SqliteRunResult r) {
  final hasError = r.stderr.isNotEmpty;
  return (
    stdout: r.stdout.isEmpty ? '' : '${r.stdout}\n',
    stderr: hasError ? 'Error: ${r.stderr}\n' : '',
    exitCode: hasError ? 1 : 0,
  );
}

/// Runs `sqlite3` against the in-memory filesystem: reads the database
/// file, executes via the browser-hosted sql.js, and serializes the
/// database back after every invocation so it persists across exec calls.
Future<InterpreterOutcome> runSqliteCommand(
  MemoryFileSystem fs,
  String cwd,
  List<String> args,
  String? stdin,
) async {
  final parsed = parseSqliteArgs(args, stdin: stdin);
  // `--version` wins over later option errors, exactly as the original
  // version check ran before the option loop.
  if (parsed.wantVersion) {
    final version = await WebInterpreters.sqliteVersion();
    return _versionBanner('sqlite3', version, '$version (Fa sandbox sql.js)\n');
  }
  final error = parsed.error;
  if (error != null) {
    return (stdout: '', stderr: error.message, exitCode: error.exitCode);
  }
  final dbBytes = await _readSqliteDb(fs, cwd, parsed.dbPath);
  final result = await WebInterpreters.runSqlite(parsed.sql, dbBytes);
  if (!result.available) return _unavailable('sqlite3');
  await _writeBackSqliteDb(fs, cwd, parsed.dbPath, result.dbBytes);
  return _sqliteOutcome(result);
}

/// The shared usage error of the snippet interpreters (exit 2).
InterpreterOutcome _usage(String usage) =>
    (stdout: '', stderr: usage, exitCode: 2);

/// Shapes a version probe: a `null` version means the browser engine is
/// absent; otherwise [banner] goes out on stdout.
InterpreterOutcome _versionBanner(
  String name,
  String? version,
  String banner,
) => version == null
    ? _unavailable(name)
    : (stdout: banner, stderr: '', exitCode: 0);

/// Shapes a snippet run: unavailable → 127, a non-empty stderr → exit 1;
/// otherwise stdout/stderr each gain the terminal newline the shell emits.
InterpreterOutcome _snippetOutcome(String name, InterpreterResult r) {
  if (!r.available) return _unavailable(name);
  final hasError = r.stderr.isNotEmpty;
  return (
    stdout: r.stdout.isEmpty ? '' : '${r.stdout}\n',
    stderr: r.stderr.isEmpty ? '' : '${r.stderr}\n',
    exitCode: hasError ? 1 : 0,
  );
}

/// Runs `python`/`python3`: `--version`/`-V`, inline `-c`, or a script file.
Future<InterpreterOutcome> runPythonCommand(
  MemoryFileSystem fs,
  String cwd,
  List<String> args,
) async {
  if (args.contains('--version') || args.contains('-V')) {
    final version = await WebInterpreters.pythonVersion();
    return _versionBanner('python3', version, 'Python $version\n');
  }
  final code = await interpreterCode(fs, cwd, args, flag: '-c');
  if (code == null) {
    return _usage(
      'usage: python3 [--version] [-c code] [script.py] [args...]\n',
    );
  }
  return _snippetOutcome('python3', await WebInterpreters.runPython(code));
}

/// Runs `qjs`/`js`: `--version`/`-v`, inline `-e`, or a script file.
Future<InterpreterOutcome> runQjsCommand(
  MemoryFileSystem fs,
  String cwd,
  List<String> args,
) async {
  if (args.contains('--version') || args.contains('-v')) {
    final version = await WebInterpreters.qjsVersion();
    return _versionBanner('qjs', version, '$version\n');
  }
  final code = await interpreterCode(fs, cwd, args, flag: '-e');
  if (code == null) {
    return _usage('usage: qjs [--version] [-e code] [script.js] [args...]\n');
  }
  return _snippetOutcome('qjs', await WebInterpreters.runQjs(code));
}

/// Extracts the code to run: inline via [flag], or a script file's content.
Future<String?> interpreterCode(
  MemoryFileSystem fs,
  String cwd,
  List<String> args, {
  required String flag,
}) async {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == flag) {
      if (i + 1 < args.length) return args[i + 1];
      return null;
    }
    if (args[i].startsWith('-')) continue;
    final resolved = resolveSandboxPath(args[i], cwd);
    final read = await fs.readTextFile(resolved);
    if (read.isErr) return null;
    return read.valueOrNull!;
  }
  return null;
}
