// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// A live-tile size in icon-slot cells (width × height).
typedef TileSize = ({int w, int h});

/// One launcher folder: an id, a user-editable name, and the ordered tile
/// keys it groups (see [LauncherLayoutStore]).
class LauncherFolder {
  LauncherFolder({required this.id, required this.name, required this.tiles});

  /// Stable id referenced from the top-level order as `folder:<id>`.
  final String id;

  /// Display name (auto-named from the first two app names at creation,
  /// user-renamable afterwards).
  String name;

  /// Ordered tile keys inside the folder (`app:<jsAppId>` entries only).
  final List<String> tiles;
}

/// Home-screen layout of the apps launcher, persisted as JSON at
/// `launcher_layout.json` in the root of the sandbox filesystem
/// ([ExecutionEnv.cwd]) — same pattern as [SessionNamesStore]: read once at
/// load, written on every mutation, best effort on both ends. A missing,
/// unreadable, or corrupt file yields an empty layout; [syncApps] then
/// rebuilds the defaults (all apps + the system tiles, no folders), so boot
/// never breaks on a bad file.
///
/// Tile keys: `app:<jsAppId>` for JS apps, [settingsKey]/[filesKey] for the
/// system tiles, `folder:<id>` for folders at the top level. Folder
/// membership lives in [LauncherFolder.tiles]; the top-level [topLevelKeys]
/// list carries one `folder:<id>` entry per folder.
///
/// Schema v2 adds the agent/user-editable knobs `grid: {columns}` (column
/// count override, clamped [minGridColumns]..[maxGridColumns]) and
/// `tileSizes: {appId: "WxH"}` (per-app live-tile size overrides in
/// icon-slot cells, W 2..4 × H 1..4). v1 files migrate silently (the knobs
/// default). Because the file lives in the shared sandbox, the Fa agent can
/// reconfigure the home screen with its regular file tools; the launcher
/// re-reads it on fsRevision bumps (see [reload]).
class LauncherLayoutStore extends ChangeNotifier {
  LauncherLayoutStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  LauncherLayoutStore.inMemory({
    List<String>? order,
    List<LauncherFolder>? folders,
    int? gridColumns,
    Map<String, TileSize>? tileSizes,
  }) : _env = null {
    if (order != null) _order.addAll(order);
    if (folders != null) {
      for (final folder in folders) {
        _folders[folder.id] = folder;
      }
    }
    _gridColumns = _clampColumns(gridColumns);
    if (tileSizes != null) {
      for (final entry in tileSizes.entries) {
        _tileSizes[entry.key] = _clampTileSize(entry.value);
      }
    }
  }

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'launcher_layout.json';

  /// Schema version of the JSON envelope; v1 files migrate (grid/tileSizes
  /// default), other versions load as empty.
  static const _version = 2;

  /// Column-count override bounds.
  static const minGridColumns = 3;
  static const maxGridColumns = 8;

  /// Tile-size override bounds (icon-slot cells). Width 1 = icon-only
  /// tile: the launcher renders the plain icon block and boots no tile
  /// engine (see `_tileContent` in the launcher screen).
  static const minTileWidth = 1;
  static const maxTileWidth = 4;
  static const minTileHeight = 1;
  static const maxTileHeight = 4;

  /// Tile key of the settings system tile.
  static const settingsKey = 'system:settings';

  /// Tile key of the file-browser system tile.
  static const filesKey = 'system:files';

  /// Tile key of the JS app [appId].
  static String appKey(String appId) => 'app:$appId';

  /// Top-level key of the folder [folderId].
  static String folderKey(String folderId) => 'folder:$folderId';

  /// Whether [key] is a top-level folder entry.
  static bool isFolderKey(String key) => key.startsWith('folder:');

  /// The folder id of a top-level folder [key] (see [isFolderKey]).
  static String folderIdOf(String key) => key.substring('folder:'.length);

  final ExecutionEnv? _env;
  final List<String> _order = [];
  final Map<String, LauncherFolder> _folders = {};
  final Map<String, TileSize> _tileSizes = {};
  int? _gridColumns;
  int _folderSeq = 0;

  /// Loads the layout persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty layout ([syncApps] rebuilds defaults from it).
  static Future<LauncherLayoutStore> load(ExecutionEnv env) async {
    final store = LauncherLayoutStore._(env);
    await store.reload();
    return store;
  }

  /// Re-reads the persisted file and applies it (order, folders, grid,
  /// tileSizes), notifying listeners when anything changed. The launcher
  /// calls this on fsRevision bumps so agent/user edits of
  /// `launcher_layout.json` reconfigure the home screen live. A corrupt or
  /// missing file keeps the CURRENT state; a no-op for in-memory stores.
  Future<void> reload() async {
    final env = _env;
    if (env == null) return;
    final parsed = await _read(env);
    if (parsed == null) return; // missing/corrupt → keep current state
    final changed = _apply(parsed);
    if (changed) notifyListeners();
  }

  /// The ordered top-level tile keys (`app:…`, `system:…`, `folder:…`).
  List<String> get topLevelKeys => List.unmodifiable(_order);

  /// The folder with [id], or null.
  LauncherFolder? folderById(String id) => _folders[id];

  /// The grid column-count override (`grid.columns`), or null for the
  /// launcher's width-based default.
  int? get gridColumns => _gridColumns;

  /// Sets (or clears, with null) the grid column-count override; values are
  /// clamped to [minGridColumns]..[maxGridColumns].
  void setGridColumns(int? columns) {
    final next = _clampColumns(columns);
    if (next == _gridColumns) return;
    _gridColumns = next;
    _mutated();
  }

  /// The live-tile size override for [appId] (`tileSizes` entry), or null
  /// when the app's manifest size applies.
  TileSize? tileSizeFor(String appId) => _tileSizes[appId];

  /// Sets (or clears, with null) the live-tile size override for [appId];
  /// the size is clamped to the supported cell range.
  void setTileSize(String appId, TileSize? size) {
    if (size == null) {
      if (_tileSizes.remove(appId) == null) return;
    } else {
      final next = _clampTileSize(size);
      if (_tileSizes[appId] == next) return;
      _tileSizes[appId] = next;
    }
    _mutated();
  }

  static int? _clampColumns(int? columns) =>
      columns?.clamp(minGridColumns, maxGridColumns);

  static TileSize _clampTileSize(TileSize size) => (
    w: size.w.clamp(minTileWidth, maxTileWidth),
    h: size.h.clamp(minTileHeight, maxTileHeight),
  );

  /// Parses a `"WxH"` tile-size string (as stored in `tileSizes`),
  /// clamped; null when unparsable.
  static TileSize? parseTileSize(String raw) {
    final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(raw);
    if (match == null) return null;
    final w = int.tryParse(match.group(1)!);
    final h = int.tryParse(match.group(2)!);
    if (w == null || h == null) return null;
    return _clampTileSize((w: w, h: h));
  }

  /// Reconciles the layout with the apps currently installed ([appIds]):
  /// drops `app:` keys (top level and inside folders) whose app is gone,
  /// dissolves folders left empty, appends new apps after the existing
  /// tiles, and guarantees both system tiles exist. Only notifies/persists
  /// when something actually changed.
  void syncApps(Iterable<String> appIds) {
    final known = appIds.toSet();
    var changed = false;

    bool prune(String key) {
      final keep = !key.startsWith('app:') || known.contains(key.substring(4));
      if (!keep) changed = true;
      return keep;
    }

    _order.removeWhere((key) => !isFolderKey(key) && !prune(key));
    for (final folder in _folders.values.toList()) {
      folder.tiles.removeWhere((key) => !prune(key));
      if (folder.tiles.isEmpty) {
        changed = true;
        _folders.remove(folder.id);
        _order.remove(folderKey(folder.id));
      }
    }
    for (final id in known) {
      final key = appKey(id);
      if (_order.contains(key)) continue;
      if (_folders.values.any((f) => f.tiles.contains(key))) continue;
      _order.add(key);
      changed = true;
    }
    for (final key in const [settingsKey, filesKey]) {
      if (!_order.contains(key)) {
        _order.add(key);
        changed = true;
      }
    }
    if (!changed) return;
    _mutated();
  }

  /// Moves the top-level entry at index [from] to index [to] (the entry
  /// currently at [to] shifts aside). Out-of-range indices are ignored.
  void reorder(int from, int to) {
    if (from == to) return;
    if (from < 0 || from >= _order.length) return;
    if (to < 0 || to >= _order.length) return;
    final entry = _order.removeAt(from);
    _order.insert(to, entry);
    _mutated();
  }

  /// Replaces the whole top-level order in one go (e.g. applying a drag
  /// preview as-is). Entries must be exactly the current top-level keys in
  /// some order — anything else is ignored. No-op when nothing moved.
  void applyTopLevelOrder(List<String> keys) {
    if (keys.length != _order.length) return;
    final current = Set<String>.of(_order);
    var same = keys.length == _order.length;
    for (final key in keys) {
      if (!current.contains(key)) return;
    }
    for (var i = 0; i < keys.length; i++) {
      if (keys[i] != _order[i]) same = false;
    }
    if (same) return;
    _order
      ..clear()
      ..addAll(keys);
    _mutated();
  }

  /// Groups the top-level tiles [a] and [b] into a new folder named [name],
  /// placed where [a] sat. System tiles and folder entries cannot be
  /// grouped. Returns the new folder id, or null when the pair is invalid.
  String? createFolder(String a, String b, {required String name}) {
    if (a == b || !_isGroupable(a) || !_isGroupable(b)) return null;
    final aIndex = _order.indexOf(a);
    final bIndex = _order.indexOf(b);
    if (aIndex < 0 || bIndex < 0) return null;
    final id =
        'folder-${++_folderSeq}-${DateTime.now().microsecondsSinceEpoch}';
    _folders[id] = LauncherFolder(
      id: id,
      name: name.trim().isEmpty ? 'Folder' : name.trim(),
      tiles: [a, b],
    );
    _order.remove(b);
    _order[_order.indexOf(a)] = folderKey(id);
    _mutated();
    return id;
  }

  /// Moves the top-level app tile [tileKey] into the folder [folderId]
  /// (dropped onto the folder tile). No-op for unknown targets.
  void addToFolder(String folderId, String tileKey) {
    final folder = _folders[folderId];
    if (folder == null || !_isGroupable(tileKey)) return;
    if (!_order.remove(tileKey)) return;
    folder.tiles.add(tileKey);
    _mutated();
  }

  /// Pulls [tileKey] out of the folder [folderId], re-inserting it at the
  /// top level right after the folder's own entry. A folder left empty is
  /// dissolved. No-op for unknown targets.
  void removeFromFolder(String folderId, String tileKey) {
    final folder = _folders[folderId];
    if (folder == null || !folder.tiles.remove(tileKey)) return;
    if (folder.tiles.isEmpty) {
      _folders.remove(folderId);
      final index = _order.indexOf(folderKey(folderId));
      if (index >= 0) _order[index] = tileKey;
    } else {
      final index = _order.indexOf(folderKey(folderId));
      _order.insert(index < 0 ? _order.length : index + 1, tileKey);
    }
    _mutated();
  }

  /// Renames the folder [id]; a blank name is ignored.
  void renameFolder(String id, String name) {
    final folder = _folders[id];
    final trimmed = name.trim();
    if (folder == null || trimmed.isEmpty || folder.name == trimmed) return;
    folder.name = trimmed;
    _mutated();
  }

  /// Dissolves the folder [id]: its tiles take its place in the top-level
  /// order. No-op for unknown ids.
  void dissolveFolder(String id) {
    final folder = _folders.remove(id);
    if (folder == null) return;
    final index = _order.indexOf(folderKey(id));
    if (index < 0) {
      _order.addAll(folder.tiles);
    } else {
      _order.replaceRange(index, index + 1, folder.tiles);
    }
    _mutated();
  }

  bool _isGroupable(String key) => key.startsWith('app:');

  void _mutated() {
    notifyListeners();
    // Fire-and-forget persistence, like SessionNamesStore's saves.
    unawaited(_save());
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({
          'version': _version,
          'order': _order,
          'folders': [
            for (final folder in _folders.values)
              {'id': folder.id, 'name': folder.name, 'tiles': folder.tiles},
          ],
          'grid': {'columns': _gridColumns},
          'tileSizes': {
            for (final entry in _tileSizes.entries)
              entry.key: '${entry.value.w}x${entry.value.h}',
          },
        }),
      );
    } on Object {
      // Best effort: a failed write must not break the launcher.
    }
  }

  /// Parses the persisted file; null when missing, unreadable, or corrupt
  /// (wrong version, broken shape, or broken folder references).
  static Future<_ParsedLayout?> _read(ExecutionEnv env) async {
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final version = decoded['version'];
      if (version != 1 && version != _version) return null;
      final order = decoded['order'];
      final folders = decoded['folders'];
      if (order is! List || folders is! List) return null;
      final parsedFolders = <String, LauncherFolder>{};
      for (final raw in folders) {
        if (raw is! Map) continue;
        final id = raw['id'];
        final name = raw['name'];
        final tiles = raw['tiles'];
        if (id is! String || id.isEmpty) continue;
        if (name is! String || name.isEmpty) continue;
        if (tiles is! List) continue;
        parsedFolders[id] = LauncherFolder(
          id: id,
          name: name,
          tiles: [for (final tile in tiles) tile.toString()],
        );
      }
      final parsedOrder = [for (final key in order) key.toString()];
      // Referential integrity: every folder entry resolves, every folder is
      // referenced — otherwise the file is treated as corrupt (defaults).
      for (final key in parsedOrder) {
        if (isFolderKey(key) && !parsedFolders.containsKey(folderIdOf(key))) {
          return null;
        }
      }
      // v2 knobs (v1 migrates with the defaults).
      int? gridColumns;
      final tileSizes = <String, TileSize>{};
      if (version == _version) {
        final grid = decoded['grid'];
        if (grid is Map) {
          final columns = grid['columns'];
          if (columns is num) gridColumns = _clampColumns(columns.toInt());
        }
        final sizes = decoded['tileSizes'];
        if (sizes is Map) {
          for (final entry in sizes.entries) {
            final value = entry.value;
            if (value == null) continue;
            final size = parseTileSize(value.toString());
            if (size != null) tileSizes[entry.key.toString()] = size;
          }
        }
      }
      return _ParsedLayout(parsedOrder, parsedFolders, gridColumns, tileSizes);
    } on Object {
      // Corrupt or incompatible file → empty layout, never crash boot.
      return null;
    }
  }

  /// Swaps the in-memory state for [parsed]; returns true when anything
  /// actually changed (reload spares the notification otherwise).
  bool _apply(_ParsedLayout parsed) {
    final changed =
        _gridColumns != parsed.gridColumns ||
        !_orderEquals(parsed.order) ||
        !_foldersEqual(parsed.folders) ||
        !_tileSizesEqual(parsed.tileSizes);
    if (!changed) return false;
    _order
      ..clear()
      ..addAll(parsed.order);
    _folders
      ..clear()
      ..addAll(parsed.folders);
    _tileSizes
      ..clear()
      ..addAll(parsed.tileSizes);
    _gridColumns = parsed.gridColumns;
    return true;
  }

  bool _orderEquals(List<String> other) {
    if (_order.length != other.length) return false;
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] != other[i]) return false;
    }
    return true;
  }

  bool _foldersEqual(Map<String, LauncherFolder> other) {
    if (_folders.length != other.length) return false;
    for (final entry in _folders.entries) {
      final folder = other[entry.key];
      if (folder == null || folder.name != entry.value.name) return false;
      final a = entry.value.tiles;
      final b = folder.tiles;
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }

  bool _tileSizesEqual(Map<String, TileSize> other) {
    if (_tileSizes.length != other.length) return false;
    for (final entry in _tileSizes.entries) {
      if (other[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// A parsed `launcher_layout.json` (see [LauncherLayoutStore.reload]).
class _ParsedLayout {
  const _ParsedLayout(
    this.order,
    this.folders,
    this.gridColumns,
    this.tileSizes,
  );

  final List<String> order;
  final Map<String, LauncherFolder> folders;
  final int? gridColumns;
  final Map<String, TileSize> tileSizes;
}

/// The index [draggedKey] would occupy when dropped onto [targetKey] at
/// horizontal fraction [fx] within the target's slot: the left half inserts
/// BEFORE the target, the right half AFTER. The index addresses the list
/// WITHOUT the dragged key (post-removal), matching
/// [LauncherLayoutStore.reorder]'s `to` semantics; -1 when the target is
/// unknown.
int launcherInsertionIndex({
  required List<String> order,
  required String draggedKey,
  required String targetKey,
  required double fx,
}) {
  final without = [...order]..remove(draggedKey);
  var to = without.indexOf(targetKey);
  if (to < 0) return -1;
  if (fx >= 0.5) to += 1;
  return to;
}

/// Returns [order] with [key] moved to [insertionIndex] (post-removal
/// indexing, see [launcherInsertionIndex]); an unknown key returns an
/// equal list.
List<String> moveLauncherKey(
  List<String> order,
  String key,
  int insertionIndex,
) {
  final from = order.indexOf(key);
  if (from < 0) return order;
  final list = [...order]..removeAt(from);
  list.insert(insertionIndex.clamp(0, list.length), key);
  return list;
}
