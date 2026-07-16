import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Creates the execution environment for the current platform.
///
/// On web the [AgentService] uses an in-memory filesystem because there is no
/// host shell or filesystem to expose safely.
Future<ExecutionEnv> createPlatformEnv() async {
  return MemoryExecutionEnv(cwd: '/');
}

/// `true` when running on a mobile OS that needs the WASM shell sandbox.
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `true` when running on the web.
bool get isWebPlatform => kIsWeb;
