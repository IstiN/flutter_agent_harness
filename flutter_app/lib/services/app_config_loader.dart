/// Resolves the `~/.fah/config.yaml` sections the app honors (issue
/// #1078): `roles:`, `tools:`, `ttsr:`, `redact:`, `providerTimeouts:`,
/// and `agent.mode` — the SAME parsers the CLI boots with — plus the app's
/// owner context-window cap (`agent.contextWindowCap`, gh-1077), through
/// the same global < project chain the CLI honors. IO platforms read the
/// real files; the stub (web) returns null (the app stores own everything
/// there, as before).
library;

export 'app_config_loader_stub.dart'
    if (dart.library.io) 'app_config_loader_io.dart';
