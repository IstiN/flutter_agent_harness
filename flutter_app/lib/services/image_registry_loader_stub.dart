/// Always null on the web: there is no `~/.fah/config.yaml` to read, so
/// the registry runs with core defaults (on, cap 20).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The parsed `images:` section, or null (absent — core defaults).
ImageRegistryConfig? loadAppImageRegistryConfig() => null;
