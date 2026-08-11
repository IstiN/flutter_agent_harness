// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The task role ids this store manages. `default` is the main connection
/// (not stored here); `smol` is the fast/cheap model for compaction and
/// later subagents.
final class TaskRole {
  TaskRole._();

  /// Fast/cheap model for compaction summaries and subagent `explore` role.
  static const smol = 'smol';

  /// Every known role id.
  static const all = [smol];
}

/// A per-role endpoint override: which model handles ONE task role when it
/// should not use the main connection.
///
/// Non-secret by design: [apiKeyName] is the NAME of an env/keychain entry,
/// never the key itself — values live in the secrets/session-keys stores.
final class TaskRoleConfig {
  const TaskRoleConfig({
    required this.providerKind,
    required this.baseUrl,
    required this.modelId,
    this.apiKeyName,
  });

  factory TaskRoleConfig.fromJson(Map<String, dynamic> json) => TaskRoleConfig(
    providerKind: (json['providerKind'] ?? '').toString(),
    baseUrl: (json['baseUrl'] ?? '').toString(),
    modelId: (json['modelId'] ?? '').toString(),
    apiKeyName: json['apiKeyName']?.toString(),
  );

  /// Provider adapter kind (currently `openai-completions`).
  final String providerKind;

  /// OpenAI-compatible base URL.
  final String baseUrl;

  /// Model id for the role.
  final String modelId;

  /// Name of the env/keychain entry holding the API key. Null = reuse the
  /// main connection's session key.
  final String? apiKeyName;

  Map<String, dynamic> toJson() => {
    'providerKind': providerKind,
    'baseUrl': baseUrl,
    'modelId': modelId,
    if (apiKeyName != null) 'apiKeyName': apiKeyName,
  };

  @override
  String toString() => 'TaskRoleConfig($providerKind, $baseUrl, $modelId)';
}

/// Per-task-role model overrides, persisted as `task_models.json` in the
/// sandbox root — same JSON-envelope pattern as [MediaModelsStore].
///
/// ```json
/// {
///   "version": 1,
///   "roles": {
///     "smol": {
///       "providerKind": "openai-completions",
///       "baseUrl": "https://openrouter.ai/api/v1",
///       "modelId": "google/gemini-2.5-flash"
///     }
///   }
/// }
/// ```
class TaskModelsStore extends ChangeNotifier {
  TaskModelsStore._(this._env) : _roles = {};

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  TaskModelsStore.inMemory([Map<String, TaskRoleConfig>? initial])
    : _env = null,
      _roles = Map.from(initial ?? const {});

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'task_models.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  final ExecutionEnv? _env;
  final Map<String, TaskRoleConfig> _roles;

  /// Loads the store persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty store.
  static Future<TaskModelsStore> load(ExecutionEnv env) async {
    final store = TaskModelsStore._(env);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    final env = _env;
    if (env == null) return;
    try {
      final result = await env.readTextFile('${env.cwd}/$fileName');
      final text = result.valueOrNull;
      if (text == null || text.isEmpty) return;
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return;
      if (json['version'] != _version) return;
      final roles = json['roles'];
      if (roles is! Map<String, dynamic>) return;
      for (final entry in roles.entries) {
        if (TaskRole.all.contains(entry.key) && entry.value is Map) {
          _roles[entry.key] = TaskRoleConfig.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      }
    } on Object {
      // Corrupt file → empty store.
    }
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      final json = jsonEncode({
        'version': _version,
        'roles': {
          for (final entry in _roles.entries) entry.key: entry.value.toJson(),
        },
      });
      await env.writeFile('${env.cwd}/$fileName', json);
    } on Object {
      // Best-effort write.
    }
  }

  /// The config for [role], if any. Null = use the main connection.
  TaskRoleConfig? overrideFor(String role) => _roles[role];

  /// The role names carrying an override.
  List<String> get configuredRoles =>
      List.unmodifiable(TaskRole.all.where(_roles.containsKey));

  /// Sets (or clears, with null) the config for [role].
  Future<void> setOverride(String role, TaskRoleConfig? config) async {
    if (!TaskRole.all.contains(role)) return;
    if (config == null) {
      if (_roles.remove(role) == null) return;
    } else {
      _roles[role] = config;
    }
    notifyListeners();
    await _save();
  }

  /// Removes every override.
  Future<void> clear() async {
    if (_roles.isEmpty) return;
    _roles.clear();
    notifyListeners();
    await _save();
  }
}

/// Provides the app's [TaskModelsStore] to the widget tree (the settings
/// Task models section) without threading it through every intermediate
/// widget — the [MediaModelsScope] pattern.
class TaskModelsScope extends InheritedNotifier<TaskModelsStore> {
  /// Creates a scope exposing [store].
  const TaskModelsScope({
    super.key,
    required TaskModelsStore store,
    required super.child,
  }) : super(notifier: store);

  /// The nearest store, or `null` outside the app shell (tests).
  static TaskModelsStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TaskModelsScope>()?.notifier;
}
