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
  for (final entry in result.entries) {
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
    try {
      final files = await catalog.downloadWidgetHealing(entry);
      await store.installWidget(
        id: entry.id,
        version: entry.version,
        files: files,
      );
      updated.add(entry.id);
      AppLog.i('apps', 'auto-updated ${entry.id} $have → ${entry.version}');
    } on Object catch (error) {
      AppLog.i('apps', 'auto-update of ${entry.id} failed: $error');
    }
  }

  // Heal broken installs: an EMPTY app dir is the residue of a failed
  // install (a wipe-then-redownload whose download never landed). It has
  // no .installed.json entry, so the version pass above never sees it,
  // and the board renders a dead tile forever. Reinstall from the
  // catalog. A dir holding just storage.json is a REMOVED widget's user
  // data — never resurrect those.
  final diskIds = await store.listAppDirIds();
  for (final entry in result.entries) {
    if (installed.containsKey(entry.id) || !diskIds.contains(entry.id)) {
      continue;
    }
    if (!await store.isEmptyAppDir(entry.id)) continue;
    try {
      final files = await catalog.downloadWidgetHealing(entry);
      await store.installWidget(
        id: entry.id,
        version: entry.version,
        files: files,
      );
      updated.add(entry.id);
      AppLog.i(
        'apps',
        'healed broken install of ${entry.id} '
            '(${entry.version})',
      );
    } on Object catch (error) {
      AppLog.i('apps', 'healing of ${entry.id} failed: $error');
    }
  }
  return updated;
}
