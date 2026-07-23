// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Declared capabilities of a JS app, parsed from its `manifest.json`.
///
/// Mirrors YoLoIT's widget manifest (`network`, `allowedCommands`) and adds
/// the Fa bridge surface (`llm`, `homekit`, `health`, `contacts`). Every
/// capability defaults to denied; the user can grant/deny per app at runtime
/// (see [AppPermissionsStore]).
class AppPermissions {
  const AppPermissions({
    this.network = false,
    this.allowedCommands = const [],
    this.llm = false,
    this.homekit = false,
    this.health = false,
    this.contacts = false,
  });

  factory AppPermissions.fromJson(Map<String, Object?> json) {
    return AppPermissions(
      network: json['network'] == true,
      allowedCommands: [
        for (final c in (json['allowedCommands'] as List?) ?? const [])
          c.toString(),
      ],
      llm: json['llm'] == true,
      homekit: json['homekit'] == true,
      health: json['health'] == true,
      contacts: json['contacts'] == true,
    );
  }

  /// Network access (`jsr.fetchJson`).
  final bool network;

  /// Shell commands the app may run through `jsr.exec`.
  final List<String> allowedCommands;

  /// Access to the host LLM via the `jsr.fa.llm(...)` bridge call.
  final bool llm;

  /// HomeKit bridge (stub — pending platform implementation).
  final bool homekit;

  /// Health data bridge (stub).
  final bool health;

  /// Contacts bridge (stub).
  final bool contacts;

  AppPermissions copyWith({
    bool? network,
    bool? llm,
    bool? homekit,
    bool? health,
    bool? contacts,
  }) {
    return AppPermissions(
      network: network ?? this.network,
      allowedCommands: allowedCommands,
      llm: llm ?? this.llm,
      homekit: homekit ?? this.homekit,
      health: health ?? this.health,
      contacts: contacts ?? this.contacts,
    );
  }

  Map<String, Object?> toJson() => {
    'network': network,
    'allowedCommands': allowedCommands,
    'llm': llm,
    'homekit': homekit,
    'health': health,
    'contacts': contacts,
  };
}

/// A JS app discovered in the env's `apps/` folder.
class JsAppInfo {
  const JsAppInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.declaredPermissions,
    this.version = '1.0.0',
    this.bundled = false,
  });

  factory JsAppInfo.fromManifest(
    Map<String, Object?> json, {
    required bool bundled,
    required String fallbackId,
  }) {
    return JsAppInfo(
      id: (json['id'] ?? fallbackId).toString(),
      name: (json['name'] ?? fallbackId).toString(),
      description: (json['description'] ?? '').toString(),
      icon: (json['icon'] ?? '📦').toString(),
      version: (json['version'] ?? '1.0.0').toString(),
      declaredPermissions: AppPermissions.fromJson(json),
      bundled: bundled,
    );
  }

  final String id;
  final String name;
  final String description;
  final String icon;
  final String version;
  final AppPermissions declaredPermissions;

  /// True for demo apps seeded from bundled assets (read-only source).
  final bool bundled;

  /// Env-relative path of the app directory (`apps/<id>`).
  String get dir => 'apps/$id';
  String get widgetPath => '$dir/widget.js';
  String get manifestPath => '$dir/manifest.json';
}

/// Effective permission state for one app: the manifest's declared set with
/// the user's runtime overrides applied (stored in `apps_permissions.json`).
class EffectiveAppPermissions {
  const EffectiveAppPermissions(this.declared, this.overrides);

  final AppPermissions declared;
  final AppPermissions? overrides;

  bool get network => overrides?.network ?? declared.network;
  bool get llm => overrides?.llm ?? declared.llm;
  bool get homekit => overrides?.homekit ?? declared.homekit;
  bool get health => overrides?.health ?? declared.health;
  bool get contacts => overrides?.contacts ?? declared.contacts;
  List<String> get allowedCommands => declared.allowedCommands;

  AppPermissions effective() => AppPermissions(
    network: network,
    allowedCommands: allowedCommands,
    llm: llm,
    homekit: homekit,
    health: health,
    contacts: contacts,
  );
}

/// User-granted permission overrides per app, persisted as
/// `apps_permissions.json` through the shared [ExecutionEnv] (same pattern
/// as `ProviderRegistry` / `LastConnectionStore`).
class AppPermissionsStore {
  AppPermissionsStore(this._env, this._overrides);

  static const String _fileName = 'apps_permissions.json';

  final ExecutionEnv _env;
  final Map<String, AppPermissions> _overrides;

  static Future<AppPermissionsStore> load(ExecutionEnv env) async {
    final overrides = <String, AppPermissions>{};
    final raw = await env.readTextFile(_fileName);
    final text = raw.valueOrNull;
    if (text != null) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, Object?>) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map<String, Object?>) {
              overrides[entry.key] = AppPermissions.fromJson(value);
            }
          }
        }
      } on FormatException {
        // Corrupt file — start empty.
      }
    }
    return AppPermissionsStore(env, overrides);
  }

  EffectiveAppPermissions forApp(JsAppInfo app) =>
      EffectiveAppPermissions(app.declaredPermissions, _overrides[app.id]);

  Future<void> setOverride(String appId, AppPermissions permissions) async {
    _overrides[appId] = permissions;
    await _save();
  }

  Future<void> clearOverride(String appId) async {
    _overrides.remove(appId);
    await _save();
  }

  Future<void> _save() async {
    final json = {
      for (final entry in _overrides.entries) entry.key: entry.value.toJson(),
    };
    await _env.writeFile(
      _fileName,
      const JsonEncoder.withIndent('  ').convert(json),
    );
  }
}

/// Discovers JS apps in the env's `apps/` folder and seeds the bundled demo
/// apps from Flutter assets on first run.
///
/// The folder layout is `<env.cwd>/apps/<id>/{manifest.json,widget.js}`.
/// Because it lives in the shared env, the Fa agent can create and edit apps
/// with its regular file tools — that is how "Fa, make me an app" works.
class AppsStore {
  /// Creates a store over [env]; [readAsset] defaults to `rootBundle`.
  /// [seedDemoIds] lists the bundled apps seeded on first run.
  AppsStore(
    this._env, {
    Future<String> Function(String path)? readAsset,
    this.seedDemoIds = demoAppIds,
  }) : _readAsset = readAsset ?? rootBundle.loadString;

  /// Asset root holding the bundled demo apps (see pubspec.yaml).
  static const String bundledAssetRoot = 'assets/apps';

  /// The bundled demo apps seeded on first run.
  static const List<String> demoAppIds = [
    'calculator',
    'weather',
    'stocks',
    'crypto',
    'animation-showcase',
    'yolo-hello',
  ];

  /// The demo apps this store seeds (see [seedBundledApps]).
  final List<String> seedDemoIds;

  final ExecutionEnv _env;

  /// Asset reader — reads bundled demo app sources; injectable for tests.
  final Future<String> Function(String path) _readAsset;

  /// Lists all apps found in `apps/`, sorted by name.
  Future<List<JsAppInfo>> listApps() async {
    final apps = <JsAppInfo>[];
    final result = await _env.listDir('apps');
    final entries = result.valueOrNull ?? const <FileInfo>[];
    for (final entry in entries) {
      if (entry.kind != FileKind.directory) continue;
      final manifest = await _env.readTextFile(
        'apps/${entry.name}/manifest.json',
      );
      final raw = manifest.valueOrNull;
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          apps.add(
            JsAppInfo.fromManifest(
              decoded,
              bundled: false,
              fallbackId: entry.name,
            ),
          );
        }
      } on FormatException {
        // Skip malformed app folders.
      }
    }
    apps.sort((a, b) => a.name.compareTo(b.name));
    return apps;
  }

  /// Reads the JS source of [app].
  Future<String> readWidgetSource(JsAppInfo app) async =>
      (await _env.readTextFile(app.widgetPath)).getOrThrow();

  /// Copies bundled demo apps (see [seedDemoIds]) into `apps/` when they are
  /// missing. Existing apps are never overwritten.
  Future<void> seedBundledApps([List<String>? demoIds]) async {
    for (final id in demoIds ?? seedDemoIds) {
      final existing = await _env.readTextFile('apps/$id/manifest.json');
      if (existing.valueOrNull != null) continue;
      final manifest = await _readAsset('$bundledAssetRoot/$id/manifest.json');
      final widget = await _readAsset('$bundledAssetRoot/$id/widget.js');
      await _env.writeFile('apps/$id/manifest.json', manifest);
      await _env.writeFile('apps/$id/widget.js', widget);
    }
  }
}
