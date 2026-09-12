/// IO implementation: reads `compaction.engine` through the core config
/// chain — project `.fah/config.yaml` wins over `~/.fah/config.yaml`
/// (null when absent or unreadable — a missing config never blocks
/// boot, classic stays the default).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;

/// The parsed `compaction.engine`, or null (absent — default classic).
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
