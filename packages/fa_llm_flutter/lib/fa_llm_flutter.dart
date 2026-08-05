/// Flutter-specific LLM providers that build on top of `fa_llm`.
///
/// This package wraps on-device and Flutter-plugin-backed inference engines
/// (e.g. `flutter_gemma`) so they can be consumed through the same
/// [LlmProvider] interface used by `fa_llm`.
library;

export 'src/flutter_gemma_provider.dart';
