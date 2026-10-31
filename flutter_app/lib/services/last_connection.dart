// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/ondevice_config_store.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:fa_ui/fa_ui.dart';

/// The provider/model combination of the last successful connection.
///
/// Persisted by [LastConnectionStore] so the setup screen can pre-select
/// where the user left off (and offer the still-downloaded on-device model
/// again) instead of falling back to the OpenRouter defaults on every
/// reload. Non-secret by design: provider/model choices are not credentials,
/// and the API key is deliberately NOT part of the record — keys stay
/// session-only (see [ProviderRegistry.rememberKey] for the same policy).
final class LastConnection {
  /// Creates a connection record.
  const LastConnection({
    required this.providerKind,
    required this.modelId,
    this.baseUrl,
    this.webllmPresetId,
    this.transformersJsPresetId,
  });

  /// Restores a record from its JSON form (see [toJson]). Unknown fields
  /// (e.g. the removed gemma stacks's `gemmaPresetId`) are skipped, never
  /// a parse error.
  factory LastConnection.fromJson(Map<String, dynamic> json) => LastConnection(
    providerKind: json['providerKind'] as String,
    modelId: json['modelId'] as String,
    baseUrl: json['baseUrl'] as String?,
    webllmPresetId: json['webllmPresetId'] as String?,
    transformersJsPresetId: json['transformersJsPresetId'] as String?,
  );

  /// Captures a successful [AgentConfig]. The API key is dropped here — it
  /// never reaches the persisted form.
  factory LastConnection.fromConfig(AgentConfig config) => LastConnection(
    providerKind: config.providerKind,
    modelId: config.modelId,
    baseUrl: config.baseUrl.isEmpty ? null : config.baseUrl,
    webllmPresetId: config.providerKind == webLlmProviderKind
        ? config.modelId
        : null,
    transformersJsPresetId: config.providerKind == transformersJsProviderKind
        ? config.modelId
        : null,
  );

  /// [AgentConfig.providerKind] of the connection (`openai-completions`,
  /// `webllm`, `transformers_js`, ...).
  final String providerKind;

  /// Model id passed to the provider; for on-device kinds this is the preset
  /// id (mirrored into the matching `*PresetId` field for explicit parsing).
  final String modelId;

  /// Hosted endpoint; `null` for on-device providers.
  final String? baseUrl;

  /// Selected WebLLM preset (only for [webLlmProviderKind]).
  final String? webllmPresetId;

  /// Selected transformers.js preset (only for [transformersJsProviderKind]).
  final String? transformersJsPresetId;

  /// JSON form persisted in the store file; absent fields stay absent (no
  /// explicit nulls).
  Map<String, dynamic> toJson() => {
    'providerKind': providerKind,
    'modelId': modelId,
    if (baseUrl != null) 'baseUrl': baseUrl,
    if (webllmPresetId != null) 'webllmPresetId': webllmPresetId,
    if (transformersJsPresetId != null)
      'transformersJsPresetId': transformersJsPresetId,
  };
}

/// Persists the last successful connection as JSON at `last_connection.json`
/// in the root of the sandbox filesystem ([ExecutionEnv.cwd]) — on web that
/// file rides the IndexedDB snapshot of the persistent env, on IO it is a
/// plain file in the sandbox/app-documents directory (same pattern as
/// [ProviderRegistry]).
///
/// Written on every successful connect (setup screen, downloaded-models
/// quick start) and on every settings-dialog apply; read once at boot to
/// prefill the connection form. A missing, unreadable, or corrupt file
/// yields an empty store (never crashes boot). API keys are never written.
class LastConnectionStore {
  LastConnectionStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): [save] updates
  /// the in-memory record but nothing is written anywhere.
  LastConnectionStore.inMemory() : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'last_connection.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  final ExecutionEnv? _env;
  LastConnection? _connection;

  /// Loads the record persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty store.
  static Future<LastConnectionStore> load(ExecutionEnv env) async {
    final store = LastConnectionStore._(env);
    await store._load();
    return store;
  }

  /// The last saved connection, if any.
  LastConnection? get connection => _connection;

  /// Saves [connection] (replacing any previous record). Persistence is best
  /// effort: a failed write must not break the connect flow.
  Future<void> save(LastConnection connection) async {
    _connection = connection;
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'connection': connection.toJson()}),
      );
    } on Object {
      // Best effort: persistence must never block connecting.
    }
  }

  /// Saves a successful [AgentConfig] (see [LastConnection.fromConfig]).
  Future<void> saveFromConfig(AgentConfig config) =>
      save(LastConnection.fromConfig(config));

  Future<void> _load() async {
    await faLoadVersionedStore(
      _env,
      fileName: fileName,
      version: _version,
      payloadKey: 'connection',
      decode: (env, connection) {
        final restored = LastConnection.fromJson(
          connection.cast<String, dynamic>(),
        );
        if (_isRemovedKind(restored.providerKind)) {
          // gh-2004: the gemma stack is gone — a persisted gemma connection
          // resets SILENTLY to the default (no last connection), no notice,
          // no migration. The stale file is dropped best-effort so the next
          // save starts clean.
          _connection = null;
          unawaited(env.remove('${env.cwd}/$fileName', force: true));
          return;
        }
        _connection = restored;
      },
    );
  }
}

/// Whether [providerKind] names a stack gh-2004 removed; records carrying
/// it reset on load. The kind set lives in [removedOnDeviceKinds]
/// (ondevice_config_store.dart) — the single shared source for both reset
/// codecs (gh-2004 review).
bool _isRemovedKind(String providerKind) =>
    removedOnDeviceKinds.contains(providerKind);
