/// The messaging fabric for agents: every agent (the main orchestrator,
/// retained subagents, and Fa instances sharing one messaging root) owns an
/// INBOX. Senders deposit messages; recipients drain them at their next turn
/// boundary.
///
/// The repository is an isolated interface on purpose: the file
/// implementation ([FileMessagingRepository]) is the default, but a future
/// database/network implementation only has to satisfy this contract — no
/// caller changes.
library;

import 'agent_message.dart';

/// One entry in the messaging-fabric directory.
class MailboxEntry {
  /// Creates a directory entry with optional session name, cwd, slug and
  /// activity metadata.
  const MailboxEntry({
    required this.id,
    this.name,
    this.cwd,
    this.slug,
    this.lastActivity,
  });

  /// The mailbox id (e.g. `a1`, `sess1/main`).
  final String id;

  /// The session display name this mailbox belongs to, when known — the
  /// human-addressable form (`--session goal_builder`). Senders may use it
  /// wherever a mailbox id is expected: `goal_builder` or
  /// `goal_builder/main` resolve through the directory. Null for legacy
  /// mailboxes registered before names existed.
  final String? name;

  /// The working directory this mailbox belongs to, when known.
  final String? cwd;

  /// The session slug this mailbox belongs to, when known.
  final String? slug;

  /// The newest activity observed in this mailbox. SOURCE-DEFINED: the file
  /// repository reports the newest file mtime inside the mailbox (heartbeat
  /// marker, inbox and read content); a future hub-presence feed would
  /// report its own activity semantics — never compare values across
  /// sources. Null when the source cannot date the mailbox.
  final DateTime? lastActivity;

  /// How recent [lastActivity] must be for a mailbox to count as live in
  /// directory views. Generous enough that a briefly paused watcher never
  /// makes a running peer vanish.
  static const Duration defaultLiveWindow = Duration(minutes: 15);

  /// Whether [lastActivity] counts as live: inside [window] of [now]. An
  /// UNKNOWN timestamp (null) counts as live — a source that cannot date a
  /// mailbox must never have it hidden from the default view.
  static bool isLive(
    DateTime? lastActivity, {
    DateTime? now,
    Duration window = defaultLiveWindow,
  }) {
    if (lastActivity == null) return true;
    final reference = now ?? DateTime.now();
    return reference.difference(lastActivity) <= window;
  }

  @override
  String toString() =>
      'MailboxEntry($id, name: $name, cwd: $cwd, slug: $slug, '
      'lastActivity: $lastActivity)';

  @override
  bool operator ==(Object other) =>
      other is MailboxEntry &&
      other.id == id &&
      other.name == name &&
      other.cwd == cwd &&
      other.slug == slug &&
      other.lastActivity == lastActivity;

  @override
  int get hashCode => Object.hash(id, name, cwd, slug, lastActivity);
}

/// Isolated messaging backend for agent inboxes.
abstract interface class MessagingRepository {
  /// Delivers [message] to the recipient's inbox. Implementations must
  /// assign/keep a unique [AgentMessage.id] and never lose a message
  /// silently (a failed delivery throws).
  Future<void> send(AgentMessage message);

  /// Announces [agentId]'s mailbox in the directory (presence): an agent
  /// with no mail yet is still discoverable. [sessionName], when non-empty,
  /// publishes the session's display name so peers can address this
  /// mailbox by name (`goal_builder` instead of `sess1/main`). Called by
  /// hosts on session start/switch.
  Future<void> register(String agentId, {String? sessionName});

  /// Refreshes [agentId]'s liveness marker (a heartbeat): hosts call this
  /// periodically while the agent runs so directory consumers can tell live
  /// mailboxes from abandoned ones WITHOUT any pending mail. Best-effort by
  /// contract — a failing backend never breaks the caller's loop.
  Future<void> touch(String agentId);

  /// The unread messages for [agentId], oldest first, without consuming
  /// them.
  Future<List<AgentMessage>> peek(String agentId);

  /// The unread messages for [agentId], oldest first, consumed (marked
  /// read). A drained message never appears again.
  Future<List<AgentMessage>> drain(String agentId);

  /// The known mailboxes in the fabric, with optional cwd metadata. The
  /// FULL set (live and stale alike) — live/dead filtering is a display
  /// policy above this layer, not a repository concern.
  Future<List<MailboxEntry>> directory();
}
