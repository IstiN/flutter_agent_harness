/// Agent messaging fabric wiring (issue #27): the per-agent FILE inboxes
/// under the session root, optionally composed with a hub-backed primary.
///
/// The FILE layer sits behind a [SwappableMessagingRepository] so hosts can
/// re-point it when session storage falls back to another root. With a hub
/// primary the hub composes OVER the swappable file layer — a storage
/// fallback swaps only files.
library;

import '../env/execution_env.dart';
import '../session/session_repo.dart';
import 'fallback_messaging_repository.dart';
import 'file_messaging_repository.dart';
import 'messaging_repository.dart';

/// Builds the agent fabric rooted at [messagesRoot].
///
/// Without [hubFabric] the fabric is the bare file layer. With one, the hub
/// becomes the primary of a [FallbackMessagingRepository]: hub-resolvable
/// recipients deliver hub-ward, everything else lands in the files.
/// [mainMailbox] names the mailbox hub mail merges into — the MAIN inbox
/// drain only, so subagent drains never touch the hub.
({MessagingRepository fabric, SwappableMessagingRepository fileFabric})
buildAgentFabric({
  required ExecutionEnv env,
  required String messagesRoot,
  required String? homeDir,
  required MessagingRepository? hubFabric,
  required String? Function() mainMailbox,
}) {
  final fileFabric = SwappableMessagingRepository(
    FileMessagingRepository(
      env: env,
      // Messaging is scoped to the *launch* cwd. Sessions are grouped by
      // cwd; the fabric is initialized once. Each mailbox is namespaced by
      // session id.
      root: messagesRoot,
      decodeSessionCwd: decodeSessionCwd,
      homeDir: homeDir,
    ),
  );
  if (hubFabric == null) {
    return (fabric: fileFabric, fileFabric: fileFabric);
  }
  final composite = FallbackMessagingRepository(
    primary: hubFabric,
    fallback: fileFabric,
  );
  composite.primaryMailbox = mainMailbox;
  return (fabric: composite, fileFabric: fileFabric);
}
