// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/stores/keychain_store.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';

/// A user-added OpenAI-compatible provider definition.
///
/// Definitions are non-secret (name, endpoint, default model) and are
/// persisted by [ProviderRegistry]; the API key is NOT part of the
/// definition — keys live in memory for the session only (see
/// [ProviderRegistry.rememberKey]).
final class CustomProvider {
  /// Creates a provider definition.
  const CustomProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.modelId,
  });

  /// Restores a definition from its JSON form (see [toJson]).
  factory CustomProvider.fromJson(Map<String, dynamic> json) => CustomProvider(
    id: json['id'] as String,
    name: json['name'] as String,
    baseUrl: json['baseUrl'] as String,
    modelId: json['modelId'] as String,
  );

  /// Stable unique id (assigned by the registry at add time).
  final String id;

  /// Display name shown in the provider picker.
  final String name;

  /// OpenAI-compatible chat-completions endpoint.
  final String baseUrl;

  /// Default model id, prefilled when the provider is selected.
  final String modelId;

  /// JSON form persisted in the registry file.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'modelId': modelId,
  };

  /// Identity is the [id], so edited copies match dropdown selections made
  /// from earlier instances.
  @override
  bool operator ==(Object other) => other is CustomProvider && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CustomProvider($id, $name)';
}

/// The user-added providers shown alongside the built-in presets in the
/// settings form's provider picker.
///
/// Definitions persist as JSON at `providers.json` in the root of the
/// sandbox filesystem ([ExecutionEnv.cwd]) — on web that file rides the
/// IndexedDB snapshot of the persistent env, on IO it is a plain file in the
/// sandbox/app-documents directory; the env abstraction makes both the same
/// code path. API keys are never persisted: [rememberKey] keeps them in
/// process memory for the session, so a reload requires re-entry (matching
/// the app's existing key policy).
class ProviderRegistry extends ChangeNotifier {
  ProviderRegistry._(this._env, [this._keychain, this._sessionKeysStore]);

  /// A registry without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  ProviderRegistry.inMemory()
    : _env = null,
      _keychain = null,
      _sessionKeysStore = null;

  /// File name (under [ExecutionEnv.cwd]) the registry persists to.
  static const fileName = 'providers.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  final ExecutionEnv? _env;

  /// The iOS/macOS Keychain backend (see [KeychainStore]); when available,
  /// provider keys persist there (host-scoped names, same convention as the
  /// CLI's `FA_KEY_<HOST>`) instead of staying session-only.
  final KeychainStore? _keychain;
  var _useKeychain = false;

  /// The saved-keys store (Keys settings section): the fallback backend a
  /// Copilot connect writes the entry-scoped GitHub token to when no
  /// Keychain is available. Only read back on delete — the registry never
  /// writes through it.
  final SessionKeysStore? _sessionKeysStore;
  final List<CustomProvider> _providers = [];
  final Map<String, String> _sessionKeys = {};

  /// User-chosen default models for the built-in hosted presets, keyed by
  /// the preset's name string (`'openrouter'`, …) — the registry is a
  /// service and must not import the UI layer where the preset enum lives.
  /// Persisted next to `providers` in the same envelope.
  final Map<String, String> _presetModels = {};

  /// The secure-store key name backing [baseUrl]'s key:
  /// `FA_KEY_API_ACME_COM`, `FA_KEY_LOCALHOST_11434`.
  static String keyNameFor(String baseUrl) =>
      // The single canonical algorithm lives in the harness
      // (CustomProviderRegistry.keyNameFor) — the CLI and the app produce
      // identical FA_KEY_<HOST> names for the same endpoint.
      CustomProviderRegistry.keyNameFor(baseUrl);

  /// Loads the registry persisted in [env]; a missing, unreadable, or
  /// corrupt file yields an empty registry (never crashes boot). With a
  /// working [keychain], per-provider keys are read from it (session-only
  /// memory otherwise).
  static Future<ProviderRegistry> load(
    ExecutionEnv env, {
    KeychainStore? keychain,
    SessionKeysStore? sessionKeys,
  }) async {
    final registry = ProviderRegistry._(env, keychain, sessionKeys);
    await registry._load();
    return registry;
  }

  /// The persisted providers, in insertion order.
  List<CustomProvider> get providers => List.unmodifiable(_providers);

  /// The session-only API key remembered for provider [id], if any.
  String? keyFor(String id) => _sessionKeys[id];

  /// The session key whose secure-store name is [keyName] (see
  /// [keyNameFor]): the remembered key of the first provider whose endpoint
  /// maps to that name. Lets named-key consumers (media slot `apiKeyName`
  /// references) reach custom-provider session keys.
  String? keyValueForName(String keyName) {
    for (final provider in _providers) {
      if (ProviderRegistry.keyNameFor(provider.baseUrl) == keyName) {
        final key = _sessionKeys[provider.id];
        if (key != null && key.isNotEmpty) return key;
      }
    }
    return null;
  }

  /// The user-chosen default model for the preset named [presetKey]
  /// (`'openrouter'`, …), if one was saved; null means "use the preset's
  /// built-in default".
  String? presetModelOverride(String presetKey) => _presetModels[presetKey];

  /// Saves [modelId] as the default model of the preset named [presetKey];
  /// null/empty clears the override (the preset's built-in default applies
  /// again). Persists and notifies.
  Future<void> setPresetModelOverride(String presetKey, String? modelId) async {
    final trimmed = modelId?.trim() ?? '';
    if (trimmed.isEmpty) {
      if (_presetModels.remove(presetKey) == null) return;
    } else {
      if (_presetModels[presetKey] == trimmed) return;
      _presetModels[presetKey] = trimmed;
    }
    await _save();
    notifyListeners();
  }

  /// Remembers [key] for provider [id]; an empty key forgets the entry.
  /// With a Keychain backend the key persists there (host-scoped name);
  /// otherwise it stays session-only. Notifies listeners so key-aware UI
  /// (the settings Keys section) refreshes.
  void rememberKey(String id, String key) {
    if (key.isEmpty) {
      _sessionKeys.remove(id);
    } else {
      _sessionKeys[id] = key;
    }
    notifyListeners();
    if (_useKeychain) {
      final provider = _providers.where((p) => p.id == id).firstOrNull;
      if (provider != null) {
        final name = keyNameFor(provider.baseUrl);
        final keychain = _keychain;
        if (keychain != null) {
          // Fire and forget: persistence must never block the form.
          if (key.isEmpty) {
            keychain.delete(name);
          } else {
            keychain.set(name, key);
          }
        }
      }
    }
  }

  /// Adds a provider and returns it (with its assigned [CustomProvider.id]).
  /// With a Keychain backend an already-stored key for this endpoint is
  /// picked up immediately (re-created providers keep their key).
  Future<CustomProvider> add({
    required String name,
    required String baseUrl,
    required String modelId,
  }) async {
    final provider = CustomProvider(
      id: 'p${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    _providers.add(provider);
    if (_useKeychain) {
      final secure = await _keychain?.readAll();
      final value = secure?[keyNameFor(baseUrl)];
      if (value != null && value.isNotEmpty) {
        _sessionKeys[provider.id] = value;
      }
    }
    await _save();
    notifyListeners();
    return provider;
  }

  /// Replaces the provider with [updated]'s id (matched by id, so the new
  /// instance keeps dropdown selections valid).
  Future<void> update(CustomProvider updated) async {
    final index = _providers.indexWhere((p) => p.id == updated.id);
    if (index < 0) return;
    _providers[index] = updated;
    await _save();
    notifyListeners();
  }

  /// Removes the provider with [id] and its key (Keychain slot included).
  /// A Copilot entry's GitHub token also lives entry-scoped
  /// (`FA_KEY_COPILOT_<NAME>`, the CLI contract) — that slot is removed
  /// from the Keychain AND the saved-keys store (the connect flow's
  /// Keychain-first/saved-keys-fallback write). Every delete call degrades
  /// gracefully (see [KeychainStore.delete]/[SessionKeysStore.delete]), so
  /// a failed secure-store delete never aborts the registry save.
  Future<void> remove(String id) async {
    final removed = _providers.where((p) => p.id == id).firstOrNull;
    _providers.removeWhere((p) => p.id == id);
    _sessionKeys.remove(id);
    if (removed != null) {
      if (_useKeychain) {
        await _keychain?.delete(keyNameFor(removed.baseUrl));
      }
      if (isCopilotBaseUrl(removed.baseUrl)) {
        final entryKey = CustomProviderRegistry.copilotEntryKeyName(
          removed.name,
        );
        if (_useKeychain) await _keychain?.delete(entryKey);
        await _sessionKeysStore?.delete(entryKey);
      }
    }
    await _save();
    notifyListeners();
  }

  Future<void> _load() async {
    final env = _env;
    if (env != null) {
      try {
        final text = (await env.readTextFile(
          '${env.cwd}/$fileName',
        )).valueOrNull;
        if (text != null) {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic> &&
              decoded['version'] == _version &&
              decoded['providers'] is List) {
            _providers
              ..clear()
              ..addAll([
                for (final entry in decoded['providers'] as List)
                  CustomProvider.fromJson(
                    (entry as Map).cast<String, dynamic>(),
                  ),
              ]);
            _presetModels
              ..clear()
              ..addAll({
                // Unknown/absent keys load as empty; non-string values are
                // ignored (a hand-edited file must not crash boot).
                if (decoded['presetModels'] is Map)
                  for (final entry in (decoded['presetModels'] as Map).entries)
                    if (entry.key is String &&
                        entry.value is String &&
                        (entry.value as String).isNotEmpty)
                      entry.key as String: entry.value as String,
              });
          }
        }
      } on Object {
        // Corrupt or incompatible file → empty registry, never crash boot.
      }
    }
    // With a Keychain backend, hydrate the per-provider keys from it. This
    // runs even without a registry file (fresh installs): the file is not
    // the source of truth for keys.
    final keychain = _keychain;
    if (keychain != null && await keychain.isAvailable()) {
      _useKeychain = true;
      final secure = await keychain.readAll();
      for (final provider in _providers) {
        final value = secure[keyNameFor(provider.baseUrl)];
        if (value != null && value.isNotEmpty) {
          _sessionKeys[provider.id] = value;
          continue;
        }
        // Copilot entries persist the GitHub token ENTRY-scoped
        // (`FA_KEY_COPILOT_<NAME>`, the connect flow / CLI contract), never
        // host-scoped — hydrate from that slot or a restart loses the key
        // and every model fetch silently 401s.
        if (isCopilotBaseUrl(provider.baseUrl)) {
          final scoped =
              secure[CustomProviderRegistry.copilotEntryKeyName(provider.name)];
          if (scoped != null && scoped.isNotEmpty) {
            _sessionKeys[provider.id] = scoped;
          }
        }
      }
    }
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({
          'version': _version,
          'providers': [for (final p in _providers) p.toJson()],
          if (_presetModels.isNotEmpty) 'presetModels': _presetModels,
        }),
      );
    } on Object {
      // Best effort: a failed write must not break the settings UI.
    }
  }
}
