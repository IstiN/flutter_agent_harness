// Startup configuration for one hub (port of the Go hubConfig).

import 'persistence.dart';

/// Configuration for a [DapHub].
final class DapHubConfig {
  const DapHubConfig({
    required this.masterSecret,
    this.adminToken = '',
    HubStore? channelStore,
    HubStore? secretStore,
  })  : channelStore = channelStore ?? const _NullHubStore(),
        secretStore = secretStore ?? const _NullHubStore();

  /// The enrollment master secret. REQUIRED — a hub without it refuses to
  /// start (see [DapHub]).
  final String masterSecret;

  /// Bearer token for the admin API; empty disables it (every admin call
  /// 401s, like the Go hub).
  final String adminToken;

  /// Persistence for the channel registry (`channels.json`).
  final HubStore channelStore;

  /// Persistence for issued client-secret hashes (`secrets.json`).
  final HubStore secretStore;
}

/// A store that never persists (null config default).
final class _NullHubStore implements HubStore {
  const _NullHubStore();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String contents) async {}
}
