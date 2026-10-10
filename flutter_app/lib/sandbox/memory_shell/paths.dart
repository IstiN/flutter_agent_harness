// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Normalizes a sandbox path: collapses `.` and `..` segments and always
/// returns an absolute path starting at the sandbox root `/`.
String normalizeSandboxPath(String path) => normalizeLexicalPath(path);

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
/// stdin text when [paths] is empty. Returns `null` and reports the failure
/// through [onError] when a file cannot be read.
///
/// gh-1444 AC1: a failed read whose sibling `<path>.pointer` resolves serves
/// the compiled-in builtin body (the seeded `.fah/skills/<name>/SKILL.md.pointer`
/// files are transparent for web-shell reads), and a present-but-invalid
/// pointer is refused LOUDLY through [onError] (E1) — never a silent
/// not-found.
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
    // gh-1444 C1: fs paths and builtin:// URIs are equivalent for reads.
    if (arg.startsWith(builtinSkillPathPrefix)) {
      final embedded = builtinSkillTextAt(arg);
      if (embedded == null) {
        onError(arg);
        return null;
      }
      buffer.write(embedded);
      continue;
    }
    final resolved = resolveSandboxPath(arg, cwd);
    var text = (await fs.readTextFile(resolved)).valueOrNull;
    if (text == null) {
      final followed = await followSkillPointer(resolved, (pointerPath) async {
        if (pointerPath.startsWith(builtinSkillPathPrefix)) {
          return builtinSkillTextAt(pointerPath);
        }
        return (await fs.readTextFile(pointerPath)).valueOrNull;
      });
      if (followed is SkillPointerRefused) {
        onError('$arg: skill pointer refused: ${followed.reason}');
        return null;
      }
      if (followed is SkillPointerResolved) {
        text = followed.text;
      } else {
        onError(arg);
        return null;
      }
    }
    buffer.write(text);
  }
  return buffer.toString();
}
