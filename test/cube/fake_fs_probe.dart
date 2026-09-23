/// Shared fake [CubeFsProbe] for cube suites: map paths to symlink targets
/// in memory, no filesystem involved. Paths in [unreadable] report the
/// fail-closed shape (`isLink: true, target: null`) — the stand-in for
/// Windows reparse points and permission walls.
library;

import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';

class FakeFsProbe implements CubeFsProbe {
  FakeFsProbe({
    Map<String, String> links = const {},
    Set<String> unreadable = const {},
  }) : links = Map.of(links),
       unreadable = Set.of(unreadable);

  /// path -> verbatim symlink target (absolute or relative).
  final Map<String, String> links;
  final Set<String> unreadable;

  @override
  CubeLinkTarget linkTarget(String path) {
    if (unreadable.contains(path)) return (isLink: true, target: null);
    final target = links[path];
    return target == null
        ? (isLink: false, target: null)
        : (isLink: true, target: target);
  }
}
