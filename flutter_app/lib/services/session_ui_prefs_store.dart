// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Persisted per-parent expand/collapse state of the sessions tree (issue
/// #426), stored as versioned JSON at [fileName] in the root of the
/// sandbox filesystem ([ExecutionEnv.cwd]) — same pattern as
/// [SessionNamesStore] / the launcher layout: read once at load, written
/// on every mutation, best effort on both ends. A missing, unreadable, or
/// corrupt file yields an empty store; the tree then falls back to its
/// defaults (small groups open, large ones collapsed).
///
/// Only EXPLICIT user toggles are stored: a parent id sits in
/// [expandedParents] or [collapsedParents] exactly while the user's
/// choice overrides the [sessionTreeAutoExpandChildren] default. Parents
/// never touched render by default and appear in neither set.
class SessionUiPrefsStore {
  SessionUiPrefsStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): mutations
  /// update the in-memory sets but nothing is written anywhere.
  SessionUiPrefsStore.inMemory() : _env = null;

  /// The sandbox-root file this store persists to.
  static const String fileName = 'session_ui_prefs.json';

  /// The document schema version; a mismatch silently resets the store.
  static const int version = 1;

  final ExecutionEnv? _env;

  /// Parent session ids the user explicitly expanded.
  final Set<String> _expanded = {};

  /// Parent session ids the user explicitly collapsed.
  final Set<String> _collapsed = {};

  /// Unmodifiable views for renderers (rows computation).
  Set<String> get expandedParents => Set.unmodifiable(_expanded);
  Set<String> get collapsedParents => Set.unmodifiable(_collapsed);

  /// Records the user's expand ([open]) / collapse choice for [parentId],
  /// replacing the previous choice. Persistence is best effort.
  Future<void> setExpanded(String parentId, bool open) async {
    final add = open ? _expanded : _collapsed;
    final remove = open ? _collapsed : _expanded;
    final moved = remove.remove(parentId);
    if (!add.contains(parentId)) {
      add.add(parentId);
    } else if (!moved) {
      return; // no-op toggle: same set, same membership
    }
    await _save();
  }

  /// Loads the store from [env]'s sandbox root.
  static Future<SessionUiPrefsStore> load(ExecutionEnv env) async {
    final store = SessionUiPrefsStore._(env);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    final env = _env;
    if (env == null) return;
    try {
      final text =
          (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != version) return;
      for (final entry in {
        'expanded': _expanded,
        'collapsed': _collapsed,
      }.entries) {
        final raw = decoded['${entry.key}Parents'];
        if (raw is! List) continue;
        entry.value
          ..clear()
          ..addAll({
            for (final id in raw)
              if (id is String && id.isNotEmpty) id,
          });
      }
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
        jsonEncode({
          'version': version,
          'expandedParents': _expanded.toList(),
          'collapsedParents': _collapsed.toList(),
        }),
      );
    } on Object {
      // Best effort: a failed write must not break the sidebar.
    }
  }
}
