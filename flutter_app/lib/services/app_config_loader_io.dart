// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO implementation: reads `agent.contextWindowCap` through the core
/// config chain — project `.fah/config.yaml` wins over `~/.fah/config.yaml`
/// (null when absent or unreadable — a missing config never blocks boot;
/// uncapped, like the CLI default).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;
import 'app_config_loader.dart';

/// The parsed owner cap, or null (absent — uncapped).
int? loadAppContextWindowCap([String? projectDir]) {
  try {
    // Project-level .fah/config.yaml wins (it travels in git).
    if (projectDir != null) {
      final project = loadProjectContextWindowCap(projectDir);
      if (project != null) return project;
    }
    final home = desktopHomeDir();
    if (home == null) return null;
    return loadCliConfig(home).contextWindowCap;
  } on Object {
    return null;
  }
}
