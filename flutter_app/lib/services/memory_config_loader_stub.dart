/// Web stub: no config file on this platform — the default `.fah/memory`
/// layout applies (the sandbox env's virtual fs).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Always null on the web: there is no `~/.fah/config.yaml` to read.
MemoryConfig? loadAppMemoryConfig() => null;
