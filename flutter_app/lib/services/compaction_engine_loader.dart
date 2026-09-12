/// Resolves the `compaction.engine` setting for the app — the same
/// global < project chain the CLI honors (issue #148 D8): project
/// `.fah/config.yaml` wins over `~/.fah/config.yaml`, default classic.
/// IO platforms read the real config; the stub (web) returns null.
library;

export 'compaction_engine_loader_stub.dart'
    if (dart.library.io) 'compaction_engine_loader_io.dart';
