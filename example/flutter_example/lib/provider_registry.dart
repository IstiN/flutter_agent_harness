// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
  ProviderRegistry._(this._env);

  /// A registry without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  ProviderRegistry.inMemory() : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the registry persists to.
  static const fileName = 'providers.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  final ExecutionEnv? _env;
  final List<CustomProvider> _providers = [];
  final Map<String, String> _sessionKeys = {};

  /// Loads the registry persisted in [env]; a missing, unreadable, or
  /// corrupt file yields an empty registry (never crashes boot).
  static Future<ProviderRegistry> load(ExecutionEnv env) async {
    final registry = ProviderRegistry._(env);
    await registry._load();
    return registry;
  }

  /// The persisted providers, in insertion order.
  List<CustomProvider> get providers => List.unmodifiable(_providers);

  /// The session-only API key remembered for provider [id], if any.
  String? keyFor(String id) => _sessionKeys[id];

  /// Remembers [key] for provider [id] for this session only; an empty key
  /// forgets the entry. Never persisted.
  void rememberKey(String id, String key) {
    if (key.isEmpty) {
      _sessionKeys.remove(id);
    } else {
      _sessionKeys[id] = key;
    }
  }

  /// Adds a provider and returns it (with its assigned [CustomProvider.id]).
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

  /// Removes the provider with [id] and its session key.
  Future<void> remove(String id) async {
    _providers.removeWhere((p) => p.id == id);
    _sessionKeys.remove(id);
    await _save();
    notifyListeners();
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
      final list = decoded['providers'];
      if (list is! List) return;
      _providers
        ..clear()
        ..addAll([
          for (final entry in list)
            CustomProvider.fromJson((entry as Map).cast<String, dynamic>()),
        ]);
    } on Object {
      // Corrupt or incompatible file → empty registry, never crash boot.
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
        }),
      );
    } on Object {
      // Best effort: a failed write must not break the settings UI.
    }
  }
}
