/// Shim: the heuristic lives in the pure-Dart core
/// (`flutter_agent_harness/src/model_roles/vision_models.dart`) so the CLI
/// and the app share one marker list.
library;

export 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show modelIdSuggestsVision;
