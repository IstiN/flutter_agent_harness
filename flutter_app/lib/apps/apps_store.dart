// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Declared capabilities of a JS app, parsed from its `manifest.json`.
///
/// Mirrors YoLoIT's widget manifest (`network`, `allowedCommands`) and adds
/// the Fa bridge surface (`llm`, `homekit`, `health`, `contacts`,
/// `microphone`, `notifications`, `media`). Every capability defaults to
/// denied; the user can grant/deny per app at runtime (see
/// [AppPermissionsStore]).
class AppPermissions {
  const AppPermissions({
    this.network = false,
    this.allowedCommands = const [],
    this.llm = false,
    this.homekit = false,
    this.health = false,
    this.contacts = false,
    this.calendar = false,
    this.microphone = false,
    this.notifications = false,
    this.media = false,
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
      calendar: json['calendar'] == true,
      microphone: json['microphone'] == true,
      notifications: json['notifications'] == true,
      media: json['media'] == true,
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

  /// System-calendar bridge (`jsr.fa.calendar` — events, create, update,
  /// delete).
  final bool calendar;

  /// Microphone bridge (`jsr.fa.asr`) — record audio and transcribe speech.
  final bool microphone;

  /// Local-notifications bridge (`jsr.fa.notify`) — schedule/cancel local
  /// system notifications.
  final bool notifications;

  /// Media bridge (`jsr.fa.media`) — image / TTS / music generation and
  /// video reading on the configured media endpoints.
  final bool media;

  AppPermissions copyWith({
    bool? network,
    bool? llm,
    bool? homekit,
    bool? health,
    bool? contacts,
    bool? calendar,
    bool? microphone,
    bool? notifications,
    bool? media,
  }) {
    return AppPermissions(
      network: network ?? this.network,
      allowedCommands: allowedCommands,
      llm: llm ?? this.llm,
      homekit: homekit ?? this.homekit,
      health: health ?? this.health,
      contacts: contacts ?? this.contacts,
      calendar: calendar ?? this.calendar,
      microphone: microphone ?? this.microphone,
      notifications: notifications ?? this.notifications,
      media: media ?? this.media,
    );
  }

  Map<String, Object?> toJson() => {
    'network': network,
    'allowedCommands': allowedCommands,
    'llm': llm,
    'homekit': homekit,
    'health': health,
    'contacts': contacts,
    'calendar': calendar,
    'microphone': microphone,
    'notifications': notifications,
    'media': media,
  };
}

/// Live-tile widget declaration of a JS app, parsed from the optional
/// `"widget"` section of its `manifest.json`:
///
/// ```json
/// "widget": { "entry": "widget_tile.js", "size": "2x1", "refreshSeconds": 900 }
/// ```
///
/// An app with a tile renders its own mini UI inside the launcher home grid
/// cell (see `app_tile_host.dart`) instead of the static icon + label. Unknown
/// or invalid values fall back to the defaults (like `chrome` does).
class JsTileWidgetInfo {
  const JsTileWidgetInfo({
    this.entry = defaultEntry,
    this.widthCells = 1,
    this.heightCells = 1,
    this.refreshSeconds,
  });

  factory JsTileWidgetInfo.fromJson(Map<String, Object?> json) {
    final entry = (json['entry'] ?? defaultEntry).toString();
    // "size": "<W>x<H>" in grid cells (e.g. "2x1", "2x2"); anything
    // unparsable falls back to 1x1, numbers clamp to the supported range.
    var widthCells = 1;
    var heightCells = 1;
    final match = RegExp(
      r'^(\d+)x(\d+)$',
    ).firstMatch(json['size']?.toString() ?? '');
    if (match != null) {
      widthCells = (int.tryParse(match.group(1)!) ?? 1).clamp(1, maxWidthCells);
      heightCells = (int.tryParse(match.group(2)!) ?? 1).clamp(
        1,
        maxHeightCells,
      );
    }
    final refresh = json['refreshSeconds'];
    return JsTileWidgetInfo(
      entry: entry.isEmpty ? defaultEntry : entry,
      widthCells: widthCells,
      heightCells: heightCells,
      refreshSeconds: refresh is num && refresh > 0 ? refresh.toInt() : null,
    );
  }

  /// Default tile entry file inside the app folder.
  static const String defaultEntry = 'widget_tile.js';

  /// Maximum horizontal span of a tile, in grid cells.
  static const int maxWidthCells = 3;

  /// Maximum vertical span of a tile, in grid cells.
  static const int maxHeightCells = 2;

  /// Tile JS entry file inside `apps/<id>/`.
  final String entry;

  /// Horizontal tile span in grid cells (1..[maxWidthCells]); unknown
  /// manifest values fall back to 1.
  final int widthCells;

  /// Vertical tile span in grid cells (1..[maxHeightCells]); unknown
  /// manifest values fall back to 1.
  final int heightCells;

  /// The declared tile size as a `'WxH'` cell string (e.g. `'2x1'`).
  String get size => '${widthCells}x$heightCells';

  /// Optional host-side refresh cadence: the tile host calls the tile's
  /// `tile.refresh` event every this many seconds (the tile JS can also just
  /// use its own `setInterval` instead).
  final int? refreshSeconds;
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
    this.chrome = chromeHeader,
    this.tileWidget,
    this.bundled = false,
  });

  factory JsAppInfo.fromManifest(
    Map<String, Object?> json, {
    required bool bundled,
    required String fallbackId,
  }) {
    final widget = json['widget'];
    return JsAppInfo(
      id: (json['id'] ?? fallbackId).toString(),
      name: (json['name'] ?? fallbackId).toString(),
      description: (json['description'] ?? '').toString(),
      icon: (json['icon'] ?? '📦').toString(),
      version: (json['version'] ?? '1.0.0').toString(),
      chrome: json['chrome'] == chromeFull ? chromeFull : chromeHeader,
      tileWidget: widget is Map<String, Object?>
          ? JsTileWidgetInfo.fromJson(widget)
          : null,
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

  /// Default display chrome: the app renders under a regular AppBar.
  static const String chromeHeader = 'header';

  /// Full-bleed display chrome: no AppBar; app controls float over the app.
  static const String chromeFull = 'full';

  /// Display chrome (NOT a permission): [chromeHeader] (default) or
  /// [chromeFull]; unknown manifest values fall back to [chromeHeader].
  final String chrome;

  /// True when the app wants the full-bleed layout (see [chromeFull]).
  bool get isFullChrome => chrome == chromeFull;

  /// True for demo apps seeded from bundled assets (read-only source).
  final bool bundled;

  /// Live-tile widget declaration (the manifest's `"widget"` section), or
  /// null when the app has no launcher tile — it renders the classic static
  /// icon tile on the home grid.
  final JsTileWidgetInfo? tileWidget;

  /// Env-relative path of the app directory (`apps/<id>`).
  String get dir => 'apps/$id';
  String get widgetPath => '$dir/widget.js';
  String get manifestPath => '$dir/manifest.json';

  /// Env-relative path of the live-tile entry file (see [tileWidget]).
  String get tileWidgetPath =>
      '$dir/${tileWidget?.entry ?? JsTileWidgetInfo.defaultEntry}';
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
  bool get calendar => overrides?.calendar ?? declared.calendar;
  bool get microphone => overrides?.microphone ?? declared.microphone;
  bool get notifications => overrides?.notifications ?? declared.notifications;
  bool get media => overrides?.media ?? declared.media;
  List<String> get allowedCommands => declared.allowedCommands;

  AppPermissions effective() => AppPermissions(
    network: network,
    allowedCommands: allowedCommands,
    llm: llm,
    homekit: homekit,
    health: health,
    contacts: contacts,
    calendar: calendar,
    microphone: microphone,
    notifications: notifications,
    media: media,
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
    'calendar',
    'contacts',
    'map',
    'health',
    'homekit',
    'voice-notes',
    'reminders',
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

  /// Copies bundled demo apps (see [seedDemoIds]) into `apps/`. Files are
  /// refreshed when the bundled content changed (demo apps are samples, not
  /// user data — custom apps should use their own id). A manifest whose
  /// `icon` points at an `.svg` file gets that file copied alongside, and a
  /// manifest with a `"widget"` section gets its tile entry file copied when
  /// the asset exists.
  Future<void> seedBundledApps([List<String>? demoIds]) async {
    for (final id in demoIds ?? seedDemoIds) {
      final manifest = await _readAsset('$bundledAssetRoot/$id/manifest.json');
      final widget = await _readAsset('$bundledAssetRoot/$id/widget.js');
      await _writeIfChanged('apps/$id/manifest.json', manifest);
      await _writeIfChanged('apps/$id/widget.js', widget);
      try {
        final decoded = jsonDecode(manifest);
        if (decoded is Map<String, Object?>) {
          final icon = decoded['icon']?.toString() ?? '';
          if (icon.toLowerCase().endsWith('.svg')) {
            final svg = await _readAsset('$bundledAssetRoot/$id/$icon');
            await _writeIfChanged('apps/$id/$icon', svg);
          }
          final tile = decoded['widget'];
          if (tile is Map<String, Object?>) {
            final entry = JsTileWidgetInfo.fromJson(tile).entry;
            try {
              final tileSource = await _readAsset(
                '$bundledAssetRoot/$id/$entry',
              );
              await _writeIfChanged('apps/$id/$entry', tileSource);
            } on Object {
              // The manifest declares a tile but no asset ships it — the
              // tile host will surface the missing file at render time.
            }
          }
        }
      } on FormatException {
        // Keep the app even if its manifest doesn't parse.
      }
    }
  }

  Future<void> _writeIfChanged(String path, String content) async {
    final existing = await _env.readTextFile(path);
    if (existing.valueOrNull == content) return;
    await _env.writeFile(path, content);
  }
}
