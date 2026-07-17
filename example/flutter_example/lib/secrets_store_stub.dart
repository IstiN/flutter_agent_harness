import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Creates the [SecretsStore] for the current platform.
///
/// On web there is no file access from the app sandbox, so the store is
/// purely in-memory: populate it at runtime (e.g. from app config) via
/// [InMemorySecretsStore.set]. Nothing is read from disk or network.
SecretsStore createSecretsStore() => InMemorySecretsStore();
