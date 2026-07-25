// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The well-known key names the Keys settings section always lists, even
/// when unset. User-saved names beyond these are listed too (see
/// [SessionKeysStore.names]); custom-provider keys live in
/// [ProviderRegistry]'s session memory and are listed per provider.
const knownKeyNames = ['OPENROUTER_API_KEY', 'HUGGINGFACE_TOKEN'];

/// API keys the user explicitly saved in the Keys settings section,
/// persisted as JSON at `session_keys.json` in the root of the sandbox
/// filesystem ([ExecutionEnv.cwd]) — on web that file rides the IndexedDB
/// snapshot of the persistent env, on IO it is a plain file in the
/// app-sandboxed documents directory (same pattern as [ProviderRegistry]).
///
/// This is the app's strongest available persistence without adding a
/// secure-storage plugin (see the `TODO(secrets-card)` in
/// `secrets_store_io.dart`): values never leave the app sandbox. Keys typed
/// straight into the connection form stay session-only as before — saving
/// here is always an explicit user action in the Keys section.
///
/// Written on every [set]/[delete]; read once at boot. A missing,
/// unreadable, or corrupt file yields an empty store (never crashes boot).
/// Values are write-only for the UI: the Keys section lists names and
/// sources, never values.
class SessionKeysStore extends ChangeNotifier {
  SessionKeysStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  SessionKeysStore.inMemory([Map<String, String>? initial]) : _env = null {
    if (initial != null) _keys.addAll(initial);
  }

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'session_keys.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  final ExecutionEnv? _env;
  final Map<String, String> _keys = {};

  /// Loads the store persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty store.
  static Future<SessionKeysStore> load(ExecutionEnv env) async {
    final store = SessionKeysStore._(env);
    await store._load();
    return store;
  }

  /// The saved key names, sorted.
  List<String> get names => List.unmodifiable(_keys.keys.toList()..sort());

  /// Whether a value is saved for [name].
  bool has(String name) => _keys.containsKey(name);

  /// The saved value for [name], if any. Never show it in the UI.
  String? valueOf(String name) => _keys[name];

  /// Saves [value] under [name] (replacing any previous value). An empty
  /// value deletes the entry instead. Persistence is best effort.
  Future<void> set(String name, String value) async {
    if (value.isEmpty) {
      return delete(name);
    }
    if (_keys[name] == value) return;
    _keys[name] = value;
    notifyListeners();
    await _save();
  }

  /// Removes the entry for [name] (no-op when absent).
  Future<void> delete(String name) async {
    if (_keys.remove(name) == null) return;
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
      final keys = decoded['keys'];
      if (keys is! Map) return;
      _keys
        ..clear()
        ..addAll({
          for (final entry in keys.entries)
            if (entry.value is String)
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
        jsonEncode({'version': _version, 'keys': _keys}),
      );
    } on Object {
      // Best effort: a failed write must not break the settings UI.
    }
  }
}

/// Provides the app's [SessionKeysStore] to the widget tree (settings Keys
/// section, connection-form prefill) without threading it through every
/// intermediate widget.
class SessionKeysScope extends InheritedNotifier<SessionKeysStore> {
  /// Creates a scope exposing [store].
  const SessionKeysScope({
    super.key,
    required SessionKeysStore store,
    required super.child,
  }) : super(notifier: store);

  /// The nearest store, or `null` outside the app shell (tests).
  static SessionKeysStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionKeysScope>()?.notifier;
}
