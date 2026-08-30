/// Persistence interface for GitHub tokens, keyed by entry name.
///
/// Platform implementations live outside fa_llm (IO → secure key store,
/// Flutter app → its secure storage); fa_llm stays pure Dart. Tokens are
/// stored ONLY in a secure store — never plain files or config.
abstract class CopilotTokenStore {
  Future<String?> read(String name);
  Future<void> write(String name, String token);
  Future<void> delete(String name);
}

/// In-memory store, ships for tests and apps without a secure backend.
class MemoryCopilotTokenStore implements CopilotTokenStore {
  final _tokens = <String, String>{};

  @override
  Future<String?> read(String name) async => _tokens[name];

  @override
  Future<void> write(String name, String token) async => _tokens[name] = token;

  @override
  Future<void> delete(String name) async => _tokens.remove(name);
}
