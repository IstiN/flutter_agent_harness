/// Time-traveling stream rules (TTSR): abort, inject, retry mid-generation.
///
/// Ported from oh-my-pi (`docs/ttsr-injection-lifecycle.md`), reduced to
/// regex conditions and the interrupting path. See `ttsr_controller.dart`
/// for the lifecycle and `ttsr_manager.dart` for the matching strategy.
library;

export 'ttsr_config.dart';
export 'ttsr_controller.dart';
export 'ttsr_manager.dart';
export 'ttsr_rule.dart';
