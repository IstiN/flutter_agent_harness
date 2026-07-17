// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Result of running a snippet in a browser-hosted interpreter.
typedef InterpreterResult = ({bool available, String stdout, String stderr});

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

  /// QuickJS version string, or null when unavailable.
  static Future<String?> qjsVersion() => Future.value(null);

  /// Python version string, or null when unavailable.
  static Future<String?> pythonVersion() => Future.value(null);
}
