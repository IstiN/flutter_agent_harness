// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO implementation: reads `compaction.engine` through the core config
/// chain — project `.fah/config.yaml` wins over `~/.fah/config.yaml`
/// (null when absent or unreadable — a missing config never blocks
/// boot; the structured default applies, issue #287). Writes go through
/// the core [ConfigService]: surgical line edits validated with the real
/// parsers BEFORE persisting (never a whole-file rewrite — the #221
/// lesson), so an unrelated comment survives byte-for-byte.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;
import 'compaction_engine_loader.dart';

/// The parsed `compaction.engine`, or null (absent — default structured).
CompactionEngine? loadAppCompactionEngine([String? projectDir]) {
  try {
    // Project-level .fah/config.yaml wins (it travels in git).
    if (projectDir != null) {
      final project = loadProjectCompactionEngine(projectDir);
      if (project != null) return project;
    }
    final home = desktopHomeDir();
    if (home == null) return null;
    return loadCliConfig(home).compactionEngine;
  } on Object {
    return null;
  }
}

/// Whether this platform can persist the engine choice at all (IO: yes —
/// the yaml config layers exist; the web stub answers false).
const bool appCompactionConfigSupported = true;

/// Resolves the effective engine plus the layer it came from (issue #287
/// AC2): project < user < the structured fallback. [homeDir] overrides
/// the user-home lookup (tests inject a temp dir; default:
/// [desktopHomeDir]). Absent/unreadable sections read as absent (the
/// fallback), matching [loadAppCompactionEngine] — an invalid section
/// still surfaces loudly at CLI boot and through `fa config check`.
AppCompactionEngineResolution resolveAppCompactionEngine({
  String? projectDir,
  String? homeDir,
}) {
  if (projectDir != null) {
    final project = _guard(() => loadProjectCompactionEngine(projectDir));
    if (project != null) {
      return AppCompactionEngineResolution(
        project,
        AppCompactionEngineSource.project,
      );
    }
  }
  final home = homeDir ?? desktopHomeDir();
  if (home != null) {
    final user = _guard(() => loadCliConfig(home).compactionEngine);
    if (user != null) {
      return AppCompactionEngineResolution(
        user,
        AppCompactionEngineSource.user,
      );
    }
  }
  // No config stated a choice: the structured default (issue #287).
  return const AppCompactionEngineResolution(
    CompactionEngine.structured,
    AppCompactionEngineSource.fallback,
  );
}

/// Writes `compaction.engine` into [layer] — a surgical edit through the
/// core [ConfigService] (issue #287 AC2): every unrelated line survives,
/// the edited text is validated with the real parsers before the write,
/// and missing files are created with the minimal section. Returns the
/// file path that was edited (shown by the picker as the source layer).
/// [homeDir] overrides the user-home lookup (tests).
Future<String> writeAppCompactionEngine(
  CompactionEngine engine, {
  required AppCompactionEngineSource layer,
  String? projectDir,
  String? homeDir,
}) async {
  if (layer == AppCompactionEngineSource.fallback) {
    throw ArgumentError(
      'fallback is not a writable layer — pick project or user',
    );
  }
  final home = homeDir ?? desktopHomeDir();
  if (layer == AppCompactionEngineSource.user && home == null) {
    throw const ConfigException(
      'user config unavailable on this host (no home directory) — write '
      'the project layer instead',
    );
  }
  // Project writes resolve against the project dir (the session cwd);
  // global writes only touch ~/.fah/config.yaml, so the env cwd is a
  // harmless anchor.
  final env = LocalExecutionEnv(cwd: projectDir ?? home ?? '.');
  final service = ConfigService(env: env, homeDir: home);
  final result = await service.set(
    'compaction.engine',
    engine.value,
    scope: layer == AppCompactionEngineSource.project
        ? ConfigScope.project
        : ConfigScope.global,
  );
  return result.file;
}

/// Wraps a config read so an absent/unreadable layer never blocks boot
/// (the same tolerance [loadAppCompactionEngine] always had).
T? _guard<T>(T? Function() read) {
  try {
    return read();
  } on Object {
    return null;
  }
}
