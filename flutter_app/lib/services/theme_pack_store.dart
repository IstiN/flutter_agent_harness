// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/theme_packs.dart';

/// One pack on disk: the validated [spec] plus the sandbox directory it was
/// installed to (`themes/<id>/`) and the memoized wallpaper bytes (E2: a
/// deleted asset reads back as null, never a crash).
final class InstalledThemePack {
  const InstalledThemePack({required this.spec, required this.wallpaperBytes});

  final ThemePackSpec spec;

  /// The declared wallpaper's bytes, or null when the pack has none or the
  /// file went missing after install.
  final Uint8List? wallpaperBytes;

  String get id => spec.id;
  String get name => spec.name;
  String get version => spec.version;
}

/// The installed theme packs: `themes/<id>/theme.json` (+ the declared
/// wallpaper asset) under the sandbox root, the same persistence home the
/// other app stores use (IndexedDB snapshot on web, plain files on IO).
///
/// Packs enter ONLY through [installFromZip] — a user file import that
/// re-validates everything (schema, security, size) before a single byte is
/// written; there is deliberately NO JS/agent-side install path (AC4). An
/// update (same id, new version) wipes and re-writes the directory — the
/// user's active choice is a separate id persisted by [ThemeController], so
/// it survives the swap (E1).
class ThemePackStore extends ChangeNotifier {
  ThemePackStore._(this._env);

  /// Directory under the sandbox root holding the installed packs.
  static const String rootDir = 'themes';

  final ExecutionEnv _env;
  final Map<String, InstalledThemePack> _packs = {};

  /// The installed packs, sorted by name.
  List<InstalledThemePack> get packs {
    final list = _packs.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(list);
  }

  /// The pack with [id], or null (also the stale-id fallback after removal).
  InstalledThemePack? byId(String? id) =>
      id == null ? null : _packs[id];

  /// Scans [rootDir] and loads every valid pack. Broken directories (half
  /// written, tampered) are skipped, never fatal — the app must boot.
  static Future<ThemePackStore> load(ExecutionEnv env) async {
    final store = ThemePackStore._(env);
    final dirs = (await env.listDir(rootDir)).valueOrNull ?? const [];
    for (final dir in dirs) {
      if (dir.kind != FileKind.directory) continue;
      final id = dir.name;
      final loaded = await store._loadPack(id);
      if (loaded != null) store._packs[id] = loaded;
    }
    return store;
  }

  Future<InstalledThemePack?> _loadPack(String id) async {
    final jsonText =
        (await _env.readTextFile('$rootDir/$id/theme.json')).valueOrNull;
    if (jsonText == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on Object {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    // Re-validate from disk (defense in depth): the wallpaper file must
    // still be there and within the size cap.
    final declared = ((decoded['wallpaper'] as Map?)?['asset'])?.toString();
    final files = <String, Uint8List>{};
    if (declared != null && declared.isNotEmpty) {
      final bytes =
          (await _env.readBinaryFile('$rootDir/$id/$declared')).valueOrNull;
      if (bytes == null) {
        // E2: wallpaper asset deleted after install — the pack stays
        // usable as colors-only. Re-validate WITHOUT the wallpaper
        // declaration: a spec must never promise an asset that is not on
        // disk (the colors still apply; the layer renders nothing).
        decoded.remove('wallpaper');
        final fallback = validateThemePack(decoded, const {});
        final spec = fallback.spec;
        if (spec == null) return null;
        return InstalledThemePack(spec: spec, wallpaperBytes: null);
      }
      files[declared] = bytes;
    }
    final validation = validateThemePack(decoded, files);
    final spec = validation.spec;
    if (spec == null) return null;
    return InstalledThemePack(
      spec: spec,
      wallpaperBytes: spec.wallpaper == null ? null : files[spec.wallpaper!.asset],
    );
  }

  /// Installs (or updates) a pack from a `.zip` the user picked. The zip is
  /// fully unpacked in memory, EVERY entry is screened (flat names, one
  /// optional top-level folder prefix, no symlinks, exactly theme.json +
  /// the declared wallpaper), and nothing is written unless validation
  /// passed. Returns the validation result; on success the pack replaces
  /// any prior install with the same id.
  Future<ThemePackValidation> installFromZip(Uint8List zipBytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } on Object {
      return (
        spec: null,
        reasons: const ['not a readable .zip file'],
        warnings: const <String>[],
      );
    }

    // Screen the entries first: files only, safe names, no nesting beyond
    // one shared top-level folder (what "compress folder" produces).
    var entries = archive.files.where((f) => f.isFile).toList();
    final reasons = <String>[];
    for (final entry in archive.files) {
      if (entry.isSymbolicLink) {
        reasons.add('symbolic links are not allowed: ${entry.name}');
      }
    }
    final prefixes = <String>{};
    for (final entry in entries) {
      final name = entry.name;
      if (name.contains('\\') || name.contains('..') || name.startsWith('/')) {
        reasons.add('unsafe entry name: $name');
      } else if (name.contains('/')) {
        prefixes.add(name.split('/').first);
      }
    }
    if (reasons.isNotEmpty) {
      return (spec: null, reasons: reasons, warnings: const <String>[]);
    }
    if (prefixes.length == 1) {
      // Strip the single shared top-level folder so the pack root is the
      // folder's CONTENT (theme.json must sit at the pack root either way).
      final prefix = '${prefixes.first}/';
      final stripped = <ArchiveFile>[
        for (final entry in entries)
          if (entry.name.length > prefix.length)
            ArchiveFile.bytes(
              entry.name.substring(prefix.length),
              entry.readBytes() ?? Uint8List(0),
            ),
      ];
      if (stripped.isNotEmpty) entries = stripped;
    }
    final files = <String, Uint8List>{};
    String? themeJson;
    for (final entry in entries) {
      final bytes = entry.readBytes() ?? Uint8List(0);
      if (entry.name == 'theme.json') {
        themeJson = utf8.decode(bytes);
      } else {
        files[entry.name] = bytes;
      }
    }
    if (themeJson == null) {
      return (
        spec: null,
        reasons: const ['theme.json missing from the pack root'],
        warnings: const <String>[],
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(themeJson);
    } on Object {
      return (
        spec: null,
        reasons: const ['theme.json is not valid JSON'],
        warnings: const <String>[],
      );
    }
    if (decoded is! Map<String, Object?>) {
      return (
        spec: null,
        reasons: const ['theme.json must contain an object'],
        warnings: const <String>[],
      );
    }
    final validation = validateThemePack(decoded, files);
    final spec = validation.spec;
    if (spec == null) return validation;

    // Validated — write (idempotent update: wipe, then write both files).
    final dir = '$rootDir/${spec.id}';
    await _env.remove(dir, recursive: true, force: true);
    await _env.createDir(dir);
    await _env.writeFile('$dir/theme.json', themeJson);
    final wallpaper = spec.wallpaper;
    if (wallpaper != null) {
      await _env.writeBinaryFile(
        '$dir/${wallpaper.asset}',
        files[wallpaper.asset]!,
      );
    }
    _packs[spec.id] = InstalledThemePack(
      spec: spec,
      wallpaperBytes: wallpaper == null ? null : files[wallpaper.asset],
    );
    notifyListeners();
    return validation;
  }

  /// Removes an installed pack. Returns false when there is nothing under
  /// that id. Reverting the ACTIVE pack to the default look is the
  /// caller's one-liner (`controller.setPack(null)`), so the removal never
  /// races the theme-mode persistence.
  Future<bool> uninstall(String id) async {
    if (!_packs.containsKey(id)) return false;
    await _env.remove('$rootDir/$id', recursive: true, force: true);
    _packs.remove(id);
    notifyListeners();
    return true;
  }
}

/// Provides the app's [ThemePackStore] to the widget tree (settings themes
/// section, the wallpaper layer, the JS theme bridge) without threading it
/// through every intermediate widget.
class ThemePackScope extends InheritedNotifier<ThemePackStore> {
  const ThemePackScope({
    super.key,
    required ThemePackStore store,
    required super.child,
  }) : super(notifier: store);

  /// The nearest store, or null outside the app shell (tests).
  static ThemePackStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemePackScope>()?.notifier;
}
