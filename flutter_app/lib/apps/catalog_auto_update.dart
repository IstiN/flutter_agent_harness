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
  final result = await catalog.fetchCatalog();
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
  return updated;
}
