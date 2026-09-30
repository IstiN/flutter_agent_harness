/// `dart:io`-backed execution environment for VM, desktop, and mobile.
///
/// Separate entry point so the core library (`flutter_agent_harness.dart`)
/// stays pure Dart and web-compilable. Import this only from platform code
/// that is allowed to touch `dart:io`.
library;

export 'src/cli/cli_config.dart';
export 'src/cli/aiin_connect_server.dart';
export 'src/cli/chatgpt_oauth_server.dart';
export 'src/cli/codemie_sso_server.dart';
export 'src/cli/headless_prompt.dart';
export 'src/cli/headless_provider_key.dart';
export 'src/cli/startup.dart';
// Conditional: shift_hid.dart and the sqlite3 engine pull in dart:ffi,
// which does not compile on the web — web consumers of lib/io.dart (e.g.
// embedded Flutter players importing the OAuth server) get no-op stubs.
export 'src/cli/shift_hid_stub.dart'
    if (dart.library.io) 'src/cli/shift_hid.dart';
export 'src/cli/openrouter_oauth_server.dart';
export 'src/cli/prompt_overrides_io.dart';
export 'src/cli/ext_engine_process.dart';
export 'src/env/isolate_session_parse_executor.dart';
export 'src/env/session_parse_executor.dart';
export 'src/env/free_space_io.dart';
export 'src/env/io_execution_env.dart';
export 'src/hub/local_hub.dart';
export 'src/messaging/hub_transport.dart';
export 'src/messaging/io_hub_transport.dart';
export 'src/lsp/io_lsp_transport.dart';
export 'src/mcp/io_mcp_transport.dart';
export 'src/power/io_power_runner.dart';
export 'src/secrets/secure_key_store_io.dart';
export 'src/tools/sqlite/sqlite3_engine_stub.dart'
    if (dart.library.io) 'src/tools/sqlite/sqlite3_engine.dart';
