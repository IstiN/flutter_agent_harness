// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The set of JS-app ids the user has pinned to the "Pinned" filter of
/// the [MyAppsShell]. Persisted as a JSON array in `pinned_apps.json`
/// under the env cwd (the same sandbox the agent can read/write, so it
/// can re-pin apps too — pinned_apps.json is just a JSON array of ids).
///
/// An empty file / missing file / corrupted file → empty set (not an
/// error — the user can re-pin).
class PinnedAppsStore extends ChangeNotifier {
  PinnedAppsStore(this._env);

  /// A non-persisting store (tests, widget fallbacks): mutations notify
  /// listeners but nothing is written anywhere.
  PinnedAppsStore.inMemory({Set<String>? initial}) : _env = null {
    if (initial != null) _ids.addAll(initial);
  }

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'pinned_apps.json';

  final ExecutionEnv? _env;
  final Set<String> _ids = <String>{};

  /// Whether [appId] is currently pinned.
  bool isPinned(String appId) => _ids.contains(appId);

  /// All pinned ids, in insertion order (most recent last).
  List<String> get ids => List.unmodifiable(_ids);

  /// Pin or unpin [appId]. Returns the new pinned state.
  Future<bool> toggle(String appId) async {
    if (_ids.contains(appId)) {
      _ids.remove(appId);
    } else {
      _ids.add(appId);
    }
    notifyListeners();
    await _persist();
    return _ids.contains(appId);
  }

  /// Loads the pinned set from the env's [fileName]. Falls back to an
  /// empty set if the file is missing or unreadable — pinning is
  /// user-driven, an unreadable file just looks like "nothing pinned
  /// yet". Callers should run this once at startup.
  Future<void> load() async {
    final env = _env;
    if (env == null) return;
    final result = await env.readTextFile(fileName);
    if (result.isErr) return;
    final raw = result.valueOrNull;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _ids
        ..clear()
        ..addAll([
          for (final entry in decoded)
            if (entry is String && entry.isNotEmpty) entry,
        ]);
      notifyListeners();
    } on Object {
      // Corrupt JSON → leave the in-memory set empty, never throw.
    }
  }

  Future<void> _persist() async {
    final env = _env;
    if (env == null) return;
    final encoded = jsonEncode(_ids.toList(growable: false));
    final result = await env.writeFile(fileName, encoded);
    // Best-effort: a persist failure doesn't break the in-memory model.
    if (result.isErr) {
      debugPrint('PinnedAppsStore: persist failed (${result.errorOrNull})');
    }
  }
}