import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Native hosts boot stock Fa unless the host embedder injects a config.
FaProductConfig loadInjectedProductConfig() => FaProductConfig.stock;
