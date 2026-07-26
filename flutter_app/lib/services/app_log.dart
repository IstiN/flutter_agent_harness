// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// A tiny process-wide debug log: a ring buffer of the last [maxLines]
/// timestamped, tagged lines plus best-effort persistence to
/// `logs/app.log` under [ExecutionEnv.cwd] (envelope-less append, the file
/// is rewritten with its tail when it grows past ~1 MB).
///
/// `main.dart` tees `debugPrint` into [AppLog.i], and subsystems log
/// directly with a tag (`AppLog.i('home', '…')`). The settings screen's
/// "Copy debug logs" row copies [dump] to the clipboard so a user can send
/// diagnostics without any tooling.
///
/// Everything is fire-and-forget: logging must never throw, and a failed
/// persistence write is silently dropped (the ring buffer still has the
/// lines).
abstract final class AppLog {
  /// How many lines the in-memory ring buffer keeps.
  static const int maxLines = 2000;

  /// Where the log persists, relative to [ExecutionEnv.cwd].
  static const String filePath = 'logs/app.log';

  /// The persisted file is trimmed to its tail once it passes this size.
  static const int maxFileBytes = 1024 * 1024;

  static final List<String> _lines = <String>[];
  static ExecutionEnv? _env;
  static int _fileBytes = 0;
  static Future<void> _writes = Future<void>.value();

  /// Starts persisting new lines to [env] (`logs/app.log` under its cwd).
  /// Called once from `main.dart` after the platform env exists.
  static void attach(ExecutionEnv env) {
    _env = env;
    // Size the cap tracker from the existing file, best effort.
    _enqueue(() async {
      final existing = (await env.readTextFile(
        '${env.cwd}/$filePath',
      )).valueOrNull;
      _fileBytes = existing == null ? 0 : utf8.encode(existing).length;
    });
  }

  /// Appends one line: `<iso timestamp> [<tag>] <message>`.
  static void i(String tag, String message) {
    final line = '${DateTime.now().toUtc().toIso8601String()} [$tag] $message';
    _lines.add(line);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    _persist('$line\n');
  }

  /// The buffered lines as one block of text (what gets copied/shared).
  static String dump() => _lines.join('\n');

  /// Clears the buffer and drops the env binding — tests only.
  @visibleForTesting
  static void reset() {
    _lines.clear();
    _env = null;
    _fileBytes = 0;
    _writes = Future<void>.value();
  }

  /// Waits for the queued persistence writes — tests only.
  @visibleForTesting
  static Future<void> flush() => _writes;

  static void _persist(String text) {
    final env = _env;
    if (env == null) return;
    final path = '${env.cwd}/$filePath';
    _enqueue(() async {
      await env.appendFile(path, text);
      _fileBytes += utf8.encode(text).length;
      if (_fileBytes > maxFileBytes) {
        final content = (await env.readTextFile(path)).valueOrNull ?? '';
        final tail = content.length > maxFileBytes ~/ 2
            ? content.substring(content.length - maxFileBytes ~/ 2)
            : content;
        await env.writeFile(path, tail);
        _fileBytes = utf8.encode(tail).length;
      }
    });
  }

  /// Serializes the async file work; errors are swallowed (best effort).
  static void _enqueue(Future<void> Function() work) {
    _writes = _writes.then((_) async {
      try {
        await work();
      } on Object {
        // Best effort — logging must never break the app.
      }
    });
  }
}
