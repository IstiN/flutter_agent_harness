/// IO implementation: reads `images:` through the core config loader
/// (null when absent or unreadable — a missing config never blocks boot;
/// the registry stays on with core defaults).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../sandbox/env_factory_io.dart' show desktopHomeDir;

/// The parsed `images:` section, or null (absent — core defaults).
ImageRegistryConfig? loadAppImageRegistryConfig() {
  try {
    final home = desktopHomeDir();
    if (home == null) return null;
    return loadCliConfig(home).images;
  } on Object {
    return null;
  }
}
