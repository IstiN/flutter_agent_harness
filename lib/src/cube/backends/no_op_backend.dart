/// The Phase 1 backend: policy layers only, no kernel confinement.
library;

import 'cube_backend.dart';

/// A [CubeSandboxBackend] that changes nothing — the Dart-layer policies
/// ([tool policy], [filesystem guard], [network scan]) are the only
/// enforcement in this mode.
final class NoOpCubeBackend implements CubeSandboxBackend {
  /// Creates the no-op backend.
  const NoOpCubeBackend();

  @override
  bool get enforces => false;

  @override
  String wrapCommand(
    String command, {
    required String profilePath,
    Map<String, String> env = const {},
  }) => command;

  @override
  String describe() =>
      'no-op (Dart policy layers only; kernel confinement lands with the '
      'OS-backend phases)';
}
