/// Resolves the `memory:` section of `~/.fah/config.yaml` for the app —
/// the same git-backed memory path overrides the CLI honors. IO platforms
/// read the real config; the stub (web) returns null (the historical
/// `.fah/memory` layout applies).
library;

export 'memory_config_loader_stub.dart'
    if (dart.library.io) 'memory_config_loader_io.dart';
