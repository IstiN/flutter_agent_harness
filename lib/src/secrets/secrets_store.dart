/// Read-focused source of secret values (API keys, tokens).
///
/// Implementations decide where secrets live (a `.env` file, an in-memory
/// overlay, secure storage); consumers only ever read them in bulk — e.g.
/// to feed a `SecretRedactor` and `SecretsExecutionEnv`.
library;

/// A read-only bulk source of secrets, name → value.
abstract interface class SecretsStore {
  /// Returns all secrets (name → value). Values must be treated as
  /// sensitive: never write them to logs, the LLM context, or disk.
  Future<Map<String, String>> readAll();
}

/// A [SecretsStore] backed by a plain map. This is the web/default
/// implementation and is convenient in tests.
final class InMemorySecretsStore implements SecretsStore {
  /// Creates a store pre-populated with [initial].
  InMemorySecretsStore([Map<String, String>? initial])
    : _secrets = {...?initial};

  final Map<String, String> _secrets;

  @override
  Future<Map<String, String>> readAll() async => Map.unmodifiable(_secrets);

  /// Adds or replaces a secret.
  void set(String name, String value) => _secrets[name] = value;

  /// Removes a secret (no-op when absent).
  void remove(String name) => _secrets.remove(name);
}
