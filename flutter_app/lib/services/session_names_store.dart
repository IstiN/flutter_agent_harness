// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:intl/intl.dart';

import 'package:fa/l10n/l10n_ext.dart';

/// The fallback session title shown when the user gave no custom name: a
/// localized date+time derived from the session's creation time ("31 Jul
/// 12:30" en / "31 июля 12:30" ru — month names come from intl, never
/// hand-translated), or the legacy `session <id8>` when the creation time
/// is not reachable (live sessions never persisted yet, tests).
String derivedSessionTitle(
  BuildContext context, {
  required String id,
  DateTime? createdAt,
}) {
  final id8 = id.length > 8 ? id.substring(0, 8) : id;
  final created = createdAt;
  if (created == null) return context.l10n.sidebarSessionTitle(id8);
  try {
    return DateFormat.MMMd(
      context.l10n.localeName,
    ).add_Hm().format(created.toLocal());
  } on Object {
    // Locale date symbols not initialized — degrade to the id8 name, never
    // crash the row.
    return context.l10n.sidebarSessionTitle(id8);
  }
}

/// Pluggable persistence for [SessionNamesStore] — the env file is the
/// default; hosted (relay) mode round-trips names through the SW settings
/// channel (`faSessionNames`) so every surface sees the same titles.
abstract interface class SessionNamesPersistence {
  /// The current authoritative names (sync — the relay snapshot is
  /// in-memory).
  Map<String, String> read();

  /// Persists [names] (the full live map; tombstones for cleared ids are
  /// the implementation's business).
  Future<void> write(Map<String, String> names);
}

/// User-given titles for chat sessions, persisted as JSON at
/// `session_names.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — on web that file rides the IndexedDB snapshot of
/// the persistent env, on IO it is a plain file in the app-sandboxed
/// documents directory (same pattern as [SessionKeysStore]).
///
/// The session repository (`JsonlSessionRepo`) has no header-update API, so
/// renames live in this app-side overlay keyed by session id; sessions
/// without an entry keep their derived name (see [derivedSessionTitle]).
/// Renaming with an empty title clears the entry.
///
/// Written on every [rename]; read once at load. A missing, unreadable, or
/// corrupt file yields an empty store (never crashes boot).
class SessionNamesStore extends ChangeNotifier {
  SessionNamesStore._(this._env) : _persistence = null;

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  SessionNamesStore.inMemory([Map<String, String>? initial])
    : _env = null,
      _persistence = null {
    if (initial != null) _names.addAll(initial);
  }

  /// A store backed by [persistence] instead of the env file — the hosted
  /// (relay) mode: renames round-trip through the SW settings channel so
  /// EVERY surface (panel, desktop app, other tabs) sees them live.
  SessionNamesStore.hosted(SessionNamesPersistence persistence)
    : _env = null,
      _persistence = persistence {
    _names.addAll(persistence.read());
  }

  /// Pluggable persistence for the hosted store.
  final SessionNamesPersistence? _persistence;

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

  /// The process-wide shared store for [env] — ONE instance per env
  /// identity, so every surface (wide sidebar, chat-sheet drawer, launcher)
  /// observes the same renames live. Previously each surface called [load]
  /// and got its own instance backed by the same file: a rename in the
  /// sidebar updated only that instance's memory, and the drawer kept
  /// showing the derived title until a full reload ("renamed to test,
  /// reopened — not applied").
  static Future<SessionNamesStore> shared(ExecutionEnv env) async {
    final cached = _sharedCache[env];
    if (cached != null) return cached;
    final store = await load(env);
    _sharedCache[env] = store;
    return store;
  }

  static final Map<ExecutionEnv, SessionNamesStore> _sharedCache = {};

  /// The custom title for session [id], or `null` when none is set (the UI
  /// falls back to the derived name).
  String? titleFor(String id) => _names[id];

  /// Replaces the in-memory names from an authoritative snapshot — hosted
  /// mode, where a settings broadcast from ANOTHER surface carries its
  /// renames. Notifies only on a real change (the relay's own put echoes
  /// back the same map and must not rebuild).
  void syncFromSnapshot(Map<String, String> names) {
    var changed = false;
    for (final id in _names.keys.toList()) {
      if (names[id] != _names[id]) {
        _names.remove(id);
        changed = true;
      }
    }
    names.forEach((id, title) {
      if (title.isNotEmpty && _names[id] != title) {
        _names[id] = title;
        changed = true;
      }
    });
    if (changed) notifyListeners();
  }

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
    final persistence = _persistence;
    if (persistence != null) {
      await persistence.write(Map<String, String>.of(_names));
      return;
    }
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
