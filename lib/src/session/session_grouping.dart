import 'session_storage.dart';

/// Header metadata value marking a session as a subagent's transcript
/// (written by both hosts' `childSessionFactory`: the CLI's
/// `agent_cli.dart` and the app's `agent_service.dart`).
const subagentAgentMarker = 'subagent';

/// Whether [session]'s header classifies it as a subagent session
/// (`metadata: {agent: 'subagent', parent: <mainSessionId>}`). Sessions
/// without header metadata (pre-feature files) are mains.
bool isSubagentSession(SessionMetadata session) =>
    session.metadata?['agent'] == subagentAgentMarker;

/// The parent session id a subagent session nests under, or null for a
/// main session (including malformed headers without a `parent` field).
String? subagentParentId(SessionMetadata session) {
  if (!isSubagentSession(session)) return null;
  final parent = session.metadata?['parent'];
  return parent is String && parent.isNotEmpty ? parent : null;
}

/// One main session with the subagent sessions nested under it (issue
/// #198's shared grouping model). An orphaned subagent — its parent is
/// deleted or simply absent from the listed set — renders as its own
/// group with [main] carrying the subagent marker and no children.
final class SessionGroup {
  /// Creates a group; [children] is already display-ordered by the caller
  /// of [groupSessionsByParent].
  const SessionGroup({required this.main, this.children = const []});

  /// The main session heading the group (or an orphaned subagent).
  final SessionMetadata main;

  /// Subagent sessions attached to [main], parent's display order.
  final List<SessionMetadata> children;
}

/// Groups [sessions] into [SessionGroup]s: every subagent session whose
/// parent is present in the list nests under it; orphans stay top-level.
///
/// Pure projection over header metadata — no I/O (AC5). Order within each
/// level follows the input order, so callers keep their own sort: the CLI
/// passes current-folder-first activity order, the app its stable
/// creation order.
///
/// Depth is capped at one: a subagent can never spawn a subagent, so a
/// child pointing at another child degrades to an orphan instead of
/// nesting deeper.
List<SessionGroup> groupSessionsByParent(List<SessionMetadata> sessions) {
  final byId = {for (final s in sessions) s.id: s};
  final childrenByParent = <String, List<SessionMetadata>>{};
  final orphans = <SessionMetadata>{};
  for (final session in sessions) {
    if (!isSubagentSession(session)) continue;
    final parentId = subagentParentId(session);
    final parent = parentId == null ? null : byId[parentId];
    if (parent == null || isSubagentSession(parent)) {
      // Empty/missing parent id, parent absent from this list, or the
      // parent is itself a child (depth must never exceed one): render
      // top-level with a subagent marker — a subagent row can never
      // vanish from a tree listing.
      orphans.add(session);
    } else {
      childrenByParent.putIfAbsent(parentId!, () => []).add(session);
    }
  }
  return [
    // Top level follows the input order (the caller's activity sort), so
    // orphans sit at their own activity position instead of being dumped
    // after the mains.
    for (final session in sessions)
      if (!isSubagentSession(session) || orphans.contains(session))
        SessionGroup(
          main: session,
          children: childrenByParent[session.id] ?? const [],
        ),
  ];
}
