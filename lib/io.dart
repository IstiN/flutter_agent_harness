/// `dart:io`-backed execution environment for VM, desktop, and mobile.
///
/// Separate entry point so the core library (`flutter_agent_harness.dart`)
/// stays pure Dart and web-compilable. Import this only from platform code
/// that is allowed to touch `dart:io`.
library;

export 'src/cli/cli_config.dart';
export 'src/env/io_execution_env.dart';
