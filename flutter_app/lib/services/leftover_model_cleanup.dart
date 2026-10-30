// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/web_model_artifacts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Best-effort deletion of the on-device Gemma stack's cached model
/// artifacts (gh-2004).
///
/// Builds before gh-2004 could download multi-GB `.litertlm` weights via
/// the `flutter_gemma` plugin (app storage on IO, the browser's OPFS on
/// web). The plugin is gone from the app, so the new build cannot
/// uninstall through it — instead boot scans the known locations and
/// deletes what matches:
///
/// - IO: a bounded walk of the **app-owned container** (the env unwrapped
///   past decorator/mount layers via [AppOwnedEnv] — never the macOS
///   mounted user project, which the plugin never wrote to) deleting
///   `*.litertlm` files and the plugin's exact `flutter_gemma` storage
///   directory;
/// - web: the OPFS root, deleting the same shapes.
///
/// The app used the plugin's **streaming** storage mode exclusively, so
/// the OPFS root is the only web surface that can hold artifacts. The
/// plugin's non-streaming CacheStorage fallback (the deleted
/// `web/cache_api.js`) was never enabled by this app — no gema-named
/// caches can exist — and its SharedPreferences registry keeps only stale
/// entries naming deleted files, which nothing reads anymore; both are
/// documented here so the next reader does not re-audit them.
///
/// Every failure is non-fatal and folded into the once-per-boot log line
/// — a read-only volume must never block startup. No settings action, no
/// prompts, no migration (the owner directive: drop local models and
/// cache if present, silently reset to the default cloud connection).
final class GemmaLeftoverCleanupReport {
  const GemmaLeftoverCleanupReport(this.deleted, this.failed);

  /// Deleted artifact paths/names (IO: absolute sandbox paths; web: OPFS
  /// entry names).
  final List<String> deleted;

  /// Artifacts whose deletion errored (non-fatal; logged once per boot).
  final List<String> failed;

  /// Whether the cleanup had nothing to do and nothing went wrong.
  bool get isEmpty => deleted.isEmpty && failed.isEmpty;
}

/// One OPFS/web storage root entry.
final class GemmaArtifactEntry {
  const GemmaArtifactEntry({required this.name, required this.directory});

  final String name;
  final bool directory;
}

/// The web storage seam ([cleanupGemmaLeftovers] builds the OPFS one on
/// web; tests inject a fake).
abstract interface class GemmaWebArtifactStore {
  Future<List<GemmaArtifactEntry>> listRoot();
  Future<void> remove(String name, {bool directory});
}

/// File suffix of the LiteRT-LM model bundles the old stack downloaded.
const _artifactSuffix = '.litertlm';

/// Exact name of the plugin's storage directory (the layout
/// `flutter_gemma` created under the app documents root). An exact match
/// — not a name fragment — so user folders that merely mention the vendor
/// (notes, vendored forks) are never touched (gh-2004 review).
const _storageDirName = 'flutter_gemma';

/// Walk/entry caps: the app container can be large, so the scan is
/// bounded — enough for the plugin's storage layout, never an unbounded
/// crawl.
const _maxDepth = 6;
const _maxEntries = 500;

/// Deletes the cached `.litertlm` artifacts + plugin storage directories
/// from [env] (IO walk) or the web storage root ([isWeb]). Best-effort:
/// per-entry failures land in [GemmaLeftoverCleanupReport.failed] and the
/// walk continues. Returns the report; logging is the caller's job (once
/// per boot, via [logGemmaLeftoverCleanup]).
Future<GemmaLeftoverCleanupReport> cleanupGemmaLeftovers(
  ExecutionEnv env, {
  bool? isWeb,
  GemmaWebArtifactStore? webStore,
}) async {
  if (isWeb ?? kIsWeb) {
    return _cleanupWeb(webStore ?? createGemmaWebArtifactStore());
  }
  return _cleanupIo(env);
}

/// Runs the cleanup and logs ONE line when it did anything (deletions or
/// failures) — the boot wiring's entry point.
Future<GemmaLeftoverCleanupReport> cleanupGemmaLeftoversAndLog(
  ExecutionEnv env, {
  bool? isWeb,
  GemmaWebArtifactStore? webStore,
}) async {
  final report = await cleanupGemmaLeftovers(env, isWeb: isWeb, webStore: webStore);
  if (!report.isEmpty) {
    debugPrint(
      '[fah] gemma leftover cleanup: '
      'deleted ${report.deleted.length}, failed ${report.failed.length}',
    );
    for (final failure in report.failed.take(3)) {
      debugPrint('[fah] gemma leftover cleanup: delete failed: $failure');
    }
  }
  return report;
}

Future<GemmaLeftoverCleanupReport> _cleanupIo(ExecutionEnv env) async {
  final deleted = <String>[];
  final failed = <String>[];
  var visited = 0;
  // gh-2004 review: resolve the walk root to the APP-OWNED container. The
  // boot env can carry the macOS project-folder mount (ProjectMountEnv,
  // cwd == /project mapping onto the user-selected host folder); the
  // plugin only ever stored inside the app container, so walking env.cwd
  // would recursively delete user project content and miss the real
  // cache. Unwrap decorator/mount layers and refuse to touch the mount
  // segment outright.
  final owned = env.appOwnedEnv;
  var root = owned.cwd;
  if (root == projectMountSegment || root.startsWith('$projectMountSegment/')) {
    // Unwrapping failed to leave the mounted-user-project namespace —
    // never walk it (the plugin stored nothing there anyway).
    return GemmaLeftoverCleanupReport(const [], const []);
  }
  if (!root.endsWith('/')) root = '$root/';

  Future<void> walk(String dir, int depth) async {
    if (depth > _maxDepth) return;
    final listing = await owned.listDir(dir);
    final infos = listing.valueOrNull;
    if (infos == null) return; // unreadable dir: skip silently
    for (final info in infos) {
      if (++visited > _maxEntries) return;
      final name = info.name;
      final path = info.path;
      if (info.kind == FileKind.directory) {
        // The plugin's known layout: a `flutter_gemma` dir directly under
        // the container root. Exact name + root-level anchor — a
        // similarly-named dir deeper in the tree (vendored fork, notes)
        // is not plugin storage and must survive (gh-2004 review).
        if (depth == 0 && name == _storageDirName) {
          final result = await owned.remove(path, recursive: true);
          (result.isOk ? deleted : failed).add(path);
          continue;
        }
        await walk(path, depth + 1);
        continue;
      }
      if (name.endsWith(_artifactSuffix)) {
        final result = await owned.remove(path);
        (result.isOk ? deleted : failed).add(path);
      }
    }
  }

  await walk(root, 0);
  return GemmaLeftoverCleanupReport(List.unmodifiable(deleted), List.unmodifiable(failed));
}

Future<GemmaLeftoverCleanupReport> _cleanupWeb(
  GemmaWebArtifactStore store,
) async {
  final deleted = <String>[];
  final failed = <String>[];
  List<GemmaArtifactEntry> entries;
  try {
    entries = await store.listRoot();
  } on Object {
    // The storage root itself is unreadable: nothing to clean, non-fatal.
    return const GemmaLeftoverCleanupReport([], []);
  }
  for (final entry in entries) {
    final isArtifact =
        (!entry.directory && entry.name.endsWith(_artifactSuffix)) ||
        (entry.directory && entry.name == _storageDirName);
    if (!isArtifact) continue;
    try {
      await store.remove(entry.name, directory: entry.directory);
      deleted.add(entry.name);
    } on Object {
      failed.add(entry.name);
    }
  }
  return GemmaLeftoverCleanupReport(List.unmodifiable(deleted), List.unmodifiable(failed));
}

/// Fires the cleanup without awaiting it (boot wiring: cleanup must never
/// delay startup; the report lands in the log). Neutral name so the call
/// site (app_boot) does not carry the removed vendor's name.
void unawaitedLeftoverModelCleanup(ExecutionEnv env, {bool? isWeb}) =>
    unawaited(cleanupGemmaLeftoversAndLog(env, isWeb: isWeb));
