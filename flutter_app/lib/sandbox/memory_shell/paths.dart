// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Normalizes a sandbox path: collapses `.` and `..` segments and always
/// returns an absolute path starting at the sandbox root `/`.
String normalizeSandboxPath(String path) {
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
String resolveSandboxPath(String path, String cwd) {
  if (path.startsWith('/')) return normalizeSandboxPath(path);
  return normalizeSandboxPath('$cwd/$path');
}

/// Splits flags from positional arguments; `--` ends flag parsing and a
/// lone `-` is treated as a positional (stdin for filters).
({List<String> flags, List<String> paths}) splitArgs(List<String> args) {
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

/// Reads the input for a command: the files in [paths] concatenated, or the
/// stdin text when [paths] is empty. Returns `null` and reports the failing
/// file through [onError] when a file cannot be read.
Future<String?> readCommandInput(
  MemoryFileSystem fs,
  String cwd,
  List<String> paths,
  String? stdin,
  void Function(String path) onError,
) async {
  if (paths.isEmpty) return stdin ?? '';
  final buffer = StringBuffer();
  for (final arg in paths) {
    if (arg == '-') {
      buffer.write(stdin ?? '');
      continue;
    }
    final resolved = resolveSandboxPath(arg, cwd);
    final result = await fs.readTextFile(resolved);
    if (result.isErr) {
      onError(arg);
      return null;
    }
    buffer.write(result.valueOrNull);
  }
  return buffer.toString();
}
