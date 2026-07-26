// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// User-given titles for chat sessions, persisted as JSON at
/// `session_names.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — on web that file rides the IndexedDB snapshot of
/// the persistent env, on IO it is a plain file in the app-sandboxed
/// documents directory (same pattern as [SessionKeysStore]).
///
/// The session repository (`JsonlSessionRepo`) has no header-update API, so
/// renames live in this app-side overlay keyed by session id; sessions
/// without an entry keep their derived `session <id8>` name. Renaming with
/// an empty title clears the entry.
///
/// Written on every [rename]; read once at load. A missing, unreadable, or
/// corrupt file yields an empty store (never crashes boot).
class SessionNamesStore extends ChangeNotifier {
  SessionNamesStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  SessionNamesStore.inMemory([Map<String, String>? initial]) : _env = null {
    if (initial != null) _names.addAll(initial);
  }

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'session_names.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  final ExecutionEnv? _env;
  final Map<String, String> _names = {};

  /// Loads the store persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty store.
  static Future<SessionNamesStore> load(ExecutionEnv env) async {
    final store = SessionNamesStore._(env);
    await store._load();
    return store;
  }

  /// The custom title for session [id], or `null` when none is set (the UI
  /// falls back to the derived name).
  String? titleFor(String id) => _names[id];

  /// Sets the custom title for session [id]; a null or empty/blank title
  /// clears the entry instead. Persistence is best effort.
  Future<void> rename(String id, [String? title]) async {
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty) {
      if (_names.remove(id) == null) return;
    } else {
      if (_names[id] == trimmed) return;
      _names[id] = trimmed;
    }
    notifyListeners();
    await _save();
  }

  Future<void> _load() async {
    final env = _env;
    if (env == null) return;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != _version) return;
      final names = decoded['names'];
      if (names is! Map) return;
      _names
        ..clear()
        ..addAll({
          for (final entry in names.entries)
            if (entry.value is String && (entry.value as String).isNotEmpty)
              entry.key as String: entry.value as String,
        });
    } on Object {
      // Corrupt or incompatible file → empty store, never crash boot.
    }
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'names': _names}),
      );
    } on Object {
      // Best effort: a failed write must not break the sidebar.
    }
  }
}
