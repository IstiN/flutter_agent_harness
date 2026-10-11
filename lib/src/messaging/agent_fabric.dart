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

/// Builds the agent fabric under [sessionRoot], scoped to the launch cwd
/// of [env] (sessions are grouped by cwd; the fabric is initialized once;
/// each mailbox is namespaced by session id).
///
/// Without [hubFabric] the fabric is the bare file layer. With one, the hub
/// becomes the primary of a [FallbackMessagingRepository]: hub-resolvable
/// recipients deliver hub-ward, everything else lands in the files.
/// [mainMailbox] names the mailbox hub mail merges into — the MAIN inbox
/// drain only, so subagent drains never touch the hub. The raw file layer
/// rides the record too (`fileLayer`) for hosts whose hub membership
/// controller swaps over it (issue #402).
({
  MessagingRepository fabric,
  SwappableMessagingRepository fileFabric,
  FileMessagingRepository fileLayer,
  String messagesRoot,
})
buildAgentFabric({
  required ExecutionEnv env,
  required String sessionRoot,
  required String? homeDir,
  required MessagingRepository? hubFabric,
  required String? Function() mainMailbox,
  String? sessionCwd,
}) {
  // The session scope usually IS the launch cwd; hosts with a mount
  // concept (the app's project folders) name the scoped dir explicitly so
  // mail is grouped by WORKSPACE, not by container cwd (issue #1079
  // slice 5 — the flutter_app mount flow keeps its root).
  final messagesRoot =
      '$sessionRoot/${encodeSessionCwd(sessionCwd ?? env.cwd)}/messages';
  final fileLayer = FileMessagingRepository(
    env: env,
    root: messagesRoot,
    decodeSessionCwd: decodeSessionCwd,
    homeDir: homeDir,
  );
  final fileFabric = SwappableMessagingRepository(fileLayer);
  if (hubFabric == null) {
    return (
      fabric: fileFabric,
      fileFabric: fileFabric,
      fileLayer: fileLayer,
      messagesRoot: messagesRoot,
    );
  }
  final composite = FallbackMessagingRepository(
    primary: hubFabric,
    fallback: fileFabric,
  );
  composite.primaryMailbox = mainMailbox;
  return (
    fabric: composite,
    fileFabric: fileFabric,
    fileLayer: fileLayer,
    messagesRoot: messagesRoot,
  );
}
