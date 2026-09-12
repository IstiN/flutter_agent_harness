/// Always null on the web: there is no `~/.fah/config.yaml` to read, so
/// the engine stays at its classic default.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The parsed `compaction.engine`, or null (absent — default classic).
CompactionEngine? loadAppCompactionEngine([String? projectDir]) => null;
