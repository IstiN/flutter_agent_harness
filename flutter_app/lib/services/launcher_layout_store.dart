// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
class LauncherLayoutStore extends ChangeNotifier {
  LauncherLayoutStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  LauncherLayoutStore.inMemory({
    List<String>? order,
    List<LauncherFolder>? folders,
  }) : _env = null {
    if (order != null) _order.addAll(order);
    if (folders != null) {
      for (final folder in folders) {
        _folders[folder.id] = folder;
      }
    }
  }

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'launcher_layout.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

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
  int _folderSeq = 0;

  /// Loads the layout persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty layout ([syncApps] rebuilds defaults from it).
  static Future<LauncherLayoutStore> load(ExecutionEnv env) async {
    final store = LauncherLayoutStore._(env);
    await store._load();
    return store;
  }

  /// The ordered top-level tile keys (`app:…`, `system:…`, `folder:…`).
  List<String> get topLevelKeys => List.unmodifiable(_order);

  /// The folder with [id], or null.
  LauncherFolder? folderById(String id) => _folders[id];

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

  Future<void> _load() async {
    final env = _env;
    if (env == null) return;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != _version) return;
      final order = decoded['order'];
      final folders = decoded['folders'];
      if (order is! List || folders is! List) return;
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
          return;
        }
      }
      _order
        ..clear()
        ..addAll(parsedOrder);
      _folders
        ..clear()
        ..addAll(parsedFolders);
    } on Object {
      // Corrupt or incompatible file → empty layout, never crash boot.
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
          'order': _order,
          'folders': [
            for (final folder in _folders.values)
              {'id': folder.id, 'name': folder.name, 'tiles': folder.tiles},
          ],
        }),
      );
    } on Object {
      // Best effort: a failed write must not break the launcher.
    }
  }
}
