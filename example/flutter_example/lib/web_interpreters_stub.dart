// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

/// Result of running a snippet in a browser-hosted interpreter.
typedef InterpreterResult = ({bool available, String stdout, String stderr});

/// Result of running SQL statements in the browser-hosted sql.js engine.
/// [dbBytes] carries the exported database back to the caller so it can be
/// persisted (sql.js keeps the database in memory only).
typedef SqliteRunResult = ({
  bool available,
  String stdout,
  String stderr,
  Uint8List? dbBytes,
});

/// Result of a `pip` run through the browser-hosted micropip.
typedef PipInterpreterResult = ({
  bool available,
  String stdout,
  String stderr,
  int exitCode,
});

/// Browser-hosted Python (pyodide) and JavaScript (quickjs-emscripten)
/// interpreters, used by [MemoryShell] on the web where no WASI runtime is
/// available. Both load from CDN on first use (nothing is bundled into the
/// app): pyodide from jsdelivr, quickjs-emscripten from npm CDN.
///
/// On non-web platforms this is a stub reporting unavailable.
class WebInterpreters {
  /// Runs QuickJS [code]. Returns `available: false` on non-web platforms.
  static Future<InterpreterResult> runQjs(String code) {
    return Future.value((available: false, stdout: '', stderr: ''));
  }

  /// Runs Python [code]. Returns `available: false` on non-web platforms.
  static Future<InterpreterResult> runPython(String code) {
    return Future.value((available: false, stdout: '', stderr: ''));
  }

  /// Runs `pip` [args] through pyodide's micropip. Returns
  /// `available: false` on non-web platforms.
  static Future<PipInterpreterResult> runPip(List<String> args) {
    return Future.value((
      available: false,
      stdout: '',
      stderr: '',
      exitCode: 127,
    ));
  }

  /// Runs [sql] against [dbBytes] via sql.js. Returns `available: false` on
  /// non-web platforms.
  static Future<SqliteRunResult> runSqlite(String sql, Uint8List? dbBytes) {
    return Future.value((
      available: false,
      stdout: '',
      stderr: '',
      dbBytes: null,
    ));
  }

  /// QuickJS version string, or null when unavailable.
  static Future<String?> qjsVersion() => Future.value(null);

  /// Python version string, or null when unavailable.
  static Future<String?> pythonVersion() => Future.value(null);

  /// SQLite version string, or null when unavailable.
  static Future<String?> sqliteVersion() => Future.value(null);
}
