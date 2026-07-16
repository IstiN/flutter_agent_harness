export 'env_factory_stub.dart' if (dart.library.io) 'env_factory_io.dart';

/// Re-exported factory that selects the right [ExecutionEnv] for the platform.
///
/// Use [createPlatformEnv] to obtain an environment and [isMobile]/
/// [isWebPlatform] for platform-specific UI decisions.
