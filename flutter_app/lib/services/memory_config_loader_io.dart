/// IO implementation: reads `~/.fah/config.yaml` through the core
/// [loadCliConfig] and returns its `memory:` section (null when absent
/// or unreadable — a missing config never blocks boot).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;

/// The parsed `memory:` section, or null (absent section / no config).
MemoryConfig? loadAppMemoryConfig([String? projectDir]) {
  try {
    // Project-level .fah/config.yaml memory: wins (it travels in git).
    if (projectDir != null) {
      final project = loadProjectMemoryConfig(projectDir);
      if (project != null) return project;
    }
    final home = desktopHomeDir();
    if (home == null) return null;
    return loadCliConfig(home).memory;
  } on Object {
    return null;
  }
}
