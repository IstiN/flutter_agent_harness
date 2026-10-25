// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/services/app_log.dart';

/// Silent catalog auto-update: every installed widget that (a) has a
/// strictly newer version in the catalog AND (b) is a CLEAN install (no
/// user/agent modifications — [AppsStore.isCleanInstall]) is re-downloaded
/// and updated in place. User data (`storage.json`) always survives;
/// modified widgets stay on the manual Update path in the catalog sheet.
///
/// Returns the ids that were updated. Network/hash failures skip the
/// widget (logged) — auto-update must never break the board.
Future<List<String>> autoUpdateCleanWidgets({
  required AppsStore store,
  required CatalogService catalog,
}) async {
  // Bypass the 6h TTL cache: this runs once per launcher start, and a
  // stale cache is exactly how a board misses a same-day widget fix
  // (the owner's video-player sat on dead-source 1.0.4 while 1.0.5 was
  // already published). Network failure falls back to the stale cache
  // inside fetchCatalog, so offline launches still work.
  final result = await catalog.fetchCatalog(force: true);
  final installed = await store.installedCatalogVersions();
  final updated = <String>[];
  await _autoUpdateNewerVersions(
    store,
    catalog,
    result.entries,
    installed,
    updated,
  );

  // Heal broken installs: an EMPTY app dir is the residue of a failed
  // install (a wipe-then-redownload whose download never landed). It has
  // no .installed.json entry, so the version pass above never sees it,
  // and the board renders a dead tile forever. Reinstall from the
  // catalog. A dir holding just storage.json is a REMOVED widget's user
  // data — never resurrect those.
  final diskIds = await store.listAppDirIds();
  await _healEmptyInstalls(
    store,
    catalog,
    result.entries,
    installed,
    diskIds,
    updated,
  );

  // Repair TORN installs (issue #201): a catalog widget whose RECORDED
  // files are partially missing on disk — the residue of a non-atomic web
  // FS snapshot that persisted mid-install (manifest restored, widget.js
  // lost) and left a tile that dies on launch with FileError notFound. A
  // missing recorded file is damage, never a user edit, so the repair
  // reinstall bypasses the clean-install check. User data (storage.json)
  // survives, as with every installWidget pass.
  await _repairTornInstalls(store, catalog, result.entries, installed, updated);
  return updated;
}

/// Pass 1: every CLEAN install with a strictly newer catalog version is
/// re-downloaded; user-modified widgets stay on the manual Update path.
Future<void> _autoUpdateNewerVersions(
  AppsStore store,
  CatalogService catalog,
  List<CatalogEntry> entries,
  Map<String, String> installed,
  List<String> updated,
) async {
  for (final entry in entries) {
    final have = installed[entry.id];
    if (have == null || !semverNewer(have, entry.version)) continue;
    if (!await store.isCleanInstall(entry.id)) {
      AppLog.i(
        'apps',
        'auto-update skips user-modified ${entry.id} '
            '($have → ${entry.version})',
      );
      continue;
    }
    await _reinstallFromCatalog(
      store,
      catalog,
      entry,
      updated,
      doneLog: 'auto-updated ${entry.id} $have → ${entry.version}',
      failureLog: (error) => 'auto-update of ${entry.id} failed: $error',
    );
  }
}

/// Pass 2: reinstall over the empty app dirs the version pass never sees.
Future<void> _healEmptyInstalls(
  AppsStore store,
  CatalogService catalog,
  List<CatalogEntry> entries,
  Map<String, String> installed,
  List<String> diskIds,
  List<String> updated,
) async {
  for (final entry in entries) {
    if (installed.containsKey(entry.id) || !diskIds.contains(entry.id)) {
      continue;
    }
    if (!await store.isEmptyAppDir(entry.id)) continue;
    await _reinstallFromCatalog(
      store,
      catalog,
      entry,
      updated,
      doneLog: 'healed broken install of ${entry.id} (${entry.version})',
      failureLog: (error) => 'healing of ${entry.id} failed: $error',
    );
  }
}

/// Pass 3: reinstall over recorded-files-missing (torn) installs — the
/// missing recorded file is damage, never a user edit, so no clean check.
Future<void> _repairTornInstalls(
  AppsStore store,
  CatalogService catalog,
  List<CatalogEntry> entries,
  Map<String, String> installed,
  List<String> updated,
) async {
  for (final entry in entries) {
    if (!installed.containsKey(entry.id) || updated.contains(entry.id)) {
      continue;
    }
    final missing = await store.missingInstalledFiles(entry.id);
    if (missing.isEmpty) continue;
    await _reinstallFromCatalog(
      store,
      catalog,
      entry,
      updated,
      doneLog:
          'repaired torn install of ${entry.id} '
          '(missing: ${missing.join(', ')})',
      failureLog: (error) => 'repair of ${entry.id} failed: $error',
    );
  }
}

/// The shared reinstall tail of every pass: download (healing entry),
/// install in place, record the update; network/hash failures skip the
/// widget (logged) — auto-update must never break the board.
Future<void> _reinstallFromCatalog(
  AppsStore store,
  CatalogService catalog,
  CatalogEntry entry,
  List<String> updated, {
  required String doneLog,
  required String Function(Object error) failureLog,
}) async {
  try {
    final files = await catalog.downloadWidgetHealing(entry);
    await store.installWidget(
      id: entry.id,
      version: entry.version,
      files: files,
    );
    updated.add(entry.id);
    AppLog.i('apps', doneLog);
  } on Object catch (error) {
    AppLog.i('apps', failureLog(error));
  }
}
