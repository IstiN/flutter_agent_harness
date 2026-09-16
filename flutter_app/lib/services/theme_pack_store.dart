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
    final list = _packs.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(list);
  }

  /// The pack with [id], or null (also the stale-id fallback after removal).
  InstalledThemePack? byId(String? id) => id == null ? null : _packs[id];

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
    final decoded = await _readPackJson(id);
    if (decoded == null) return null;
    final declared = _declaredAsset(decoded);
    if (declared == null) return _validatedPack(decoded, const {});
    final bytes = (await _env.readBinaryFile(
      '$rootDir/$id/$declared',
    )).valueOrNull;
    if (bytes == null) {
      // E2: wallpaper asset deleted after install — the pack stays
      // usable as colors-only. Re-validate WITHOUT the wallpaper
      // declaration: a spec must never promise an asset that is not on
      // disk (the colors still apply; the layer renders nothing).
      decoded.remove('wallpaper');
      return _validatedPack(decoded, const {});
    }
    return _validatedPack(decoded, {declared: bytes});
  }

  /// The decoded `theme.json` under [id], or null when the file is
  /// missing, is invalid JSON, or is not an object (the pack is skipped).
  Future<Map<String, Object?>?> _readPackJson(String id) async {
    final jsonText = (await _env.readTextFile(
      '$rootDir/$id/theme.json',
    )).valueOrNull;
    if (jsonText == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on Object {
      return null;
    }
    return decoded is Map<String, Object?> ? decoded : null;
  }

  /// The declared wallpaper asset name, or null when the pack declares
  /// none — an empty name is not a declaration either: the wallpaper key
  /// then stays in [decoded] and the validator rejects it, exactly as it
  /// would on a fresh import.
  String? _declaredAsset(Map<String, Object?> decoded) {
    final declared = ((decoded['wallpaper'] as Map?)?['asset'])?.toString();
    return (declared == null || declared.isEmpty) ? null : declared;
  }

  /// Re-validates [decoded] against [files]; null when the pack no
  /// longer passes (broken/tampered directories are skipped on load).
  InstalledThemePack? _validatedPack(
    Map<String, Object?> decoded,
    Map<String, Uint8List> files,
  ) {
    final spec = validateThemePack(decoded, files).spec;
    if (spec == null) return null;
    return InstalledThemePack(
      spec: spec,
      wallpaperBytes: spec.wallpaper == null
          ? null
          : files[spec.wallpaper!.asset],
    );
  }

  /// Installs (or updates) a pack from a `.zip` the user picked, as a
  /// fold over the staged zip pipeline (issue #484): decode → screen →
  /// strip the shared folder prefix → extract → decode JSON → validate.
  /// Each stage gets the accumulating [_ZipInstall]; the first stage that
  /// leaves a rejection reason stops the fold — nothing is written unless
  /// validation passed. On success the pack replaces any prior install
  /// with the same id (wipe, then write both files).
  Future<ThemePackValidation> installFromZip(Uint8List zipBytes) async {
    final z = _ZipInstall(zipBytes);
    for (final stage in _zipStages) {
      stage(z);
      if (z.reasons.isNotEmpty) {
        return (spec: null, reasons: z.reasons, warnings: const <String>[]);
      }
    }
    final validation = z.validation!;
    await _commitPack(validation.spec!, z.themeJson!, z.files);
    return validation;
  }

  /// Writes a validated pack to disk (idempotent update: wipe, then
  /// write), swaps it into the in-memory table, and notifies listeners.
  Future<void> _commitPack(
    ThemePackSpec spec,
    String themeJson,
    Map<String, Uint8List> files,
  ) async {
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

/// One zip-install stage (issue #484): a single synchronous step over
/// the accumulating [_ZipInstall]. A stage appends rejection reasons and
/// stages its output; the fold in [ThemePackStore.installFromZip] stops
/// at the first stage that leaves a reason, which keeps every stage's
/// rejection set exactly as short-circuiting as the old inline pipeline.
typedef _ZipStage = void Function(_ZipInstall z);

/// The install pipeline in run order: decode, screen, un-nest, extract,
/// decode JSON, validate. Writing happens after the fold — a stage never
/// touches the filesystem.
const List<_ZipStage> _zipStages = [
  _decodeArchiveStage,
  _screenEntriesStage,
  _stripSharedPrefixStage,
  _extractFilesStage,
  _decodeJsonStage,
  _validatePackStage,
];

/// The zip-install accumulator: raw bytes in, parsed pack parts out.
final class _ZipInstall {
  _ZipInstall(this.zipBytes);

  final Uint8List zipBytes;

  /// Rejection reasons — non-empty after a stage stops the pipeline.
  final List<String> reasons = [];

  Archive? archive;
  List<ArchiveFile> entries = [];
  final Set<String> prefixes = {};
  final Map<String, Uint8List> files = {};
  String? themeJson;
  Map<String, Object?>? decoded;
  ThemePackValidation? validation;
}

void _decodeArchiveStage(_ZipInstall z) {
  try {
    // archive 4.x decodes garbage leniently (an empty archive) — the
    // catch stays for the API contract, never observed in practice.
    z.archive = ZipDecoder().decodeBytes(z.zipBytes);
  } on Object {
    z.reasons.add('not a readable .zip file');
  }
}

/// Files only, safe names, no nesting beyond one shared top-level folder
/// (what "compress folder" produces).
void _screenEntriesStage(_ZipInstall z) {
  final archive = z.archive!;
  z.entries = archive.files.where((f) => f.isFile).toList();
  for (final entry in archive.files) {
    if (entry.isSymbolicLink) {
      z.reasons.add('symbolic links are not allowed: ${entry.name}');
    }
  }
  for (final entry in z.entries) {
    if (_isUnsafeEntryName(entry.name)) {
      z.reasons.add('unsafe entry name: ${entry.name}');
    } else if (entry.name.contains('/')) {
      z.prefixes.add(entry.name.split('/').first);
    }
  }
}

bool _isUnsafeEntryName(String name) =>
    name.contains('\\') || name.contains('..') || name.startsWith('/');

/// Strips the single shared top-level folder so the pack root is the
/// folder's CONTENT (theme.json must sit at the pack root either way).
void _stripSharedPrefixStage(_ZipInstall z) {
  if (z.prefixes.length != 1) return;
  final prefix = '${z.prefixes.first}/';
  final stripped = <ArchiveFile>[
    for (final entry in z.entries)
      if (entry.name.length > prefix.length)
        ArchiveFile.bytes(
          entry.name.substring(prefix.length),
          entry.readBytes() ?? Uint8List(0),
        ),
  ];
  if (stripped.isNotEmpty) z.entries = stripped;
}

void _extractFilesStage(_ZipInstall z) {
  for (final entry in z.entries) {
    final bytes = entry.readBytes() ?? Uint8List(0);
    if (entry.name == 'theme.json') {
      z.themeJson = utf8.decode(bytes);
    } else {
      z.files[entry.name] = bytes;
    }
  }
  if (z.themeJson == null) {
    z.reasons.add('theme.json missing from the pack root');
  }
}

void _decodeJsonStage(_ZipInstall z) {
  final Object? decoded;
  try {
    decoded = jsonDecode(z.themeJson!);
  } on Object {
    z.reasons.add('theme.json is not valid JSON');
    return;
  }
  if (decoded is! Map<String, Object?>) {
    z.reasons.add('theme.json must contain an object');
    return;
  }
  z.decoded = decoded;
}

void _validatePackStage(_ZipInstall z) {
  final validation = validateThemePack(z.decoded!, z.files);
  if (validation.spec == null) {
    z.reasons.addAll(validation.reasons);
    return;
  }
  z.validation = validation;
}
