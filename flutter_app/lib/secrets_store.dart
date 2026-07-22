export 'secrets_store_stub.dart' if (dart.library.io) 'secrets_store_io.dart';

/// Re-exported factory for the platform [SecretsStore].
///
/// Use [createSecretsStore] to obtain the store: `.env` file + in-memory
/// overlay on IO platforms, in-memory only on web.
