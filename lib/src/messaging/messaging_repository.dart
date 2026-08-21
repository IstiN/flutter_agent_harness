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
  /// Creates a directory entry with optional cwd and slug metadata.
  const MailboxEntry({required this.id, this.cwd, this.slug});

  /// The mailbox id (e.g. `a1`, `sess1/main`).
  final String id;

  /// The working directory this mailbox belongs to, when known.
  final String? cwd;

  /// The session slug this mailbox belongs to, when known.
  final String? slug;

  @override
  String toString() => 'MailboxEntry($id, cwd: $cwd, slug: $slug)';

  @override
  bool operator ==(Object other) =>
      other is MailboxEntry &&
      other.id == id &&
      other.cwd == cwd &&
      other.slug == slug;

  @override
  int get hashCode => Object.hash(id, cwd, slug);
}

/// Isolated messaging backend for agent inboxes.
abstract interface class MessagingRepository {
  /// Delivers [message] to the recipient's inbox. Implementations must
  /// assign/keep a unique [AgentMessage.id] and never lose a message
  /// silently (a failed delivery throws).
  Future<void> send(AgentMessage message);

  /// Announces [agentId]'s mailbox in the directory (presence): an agent
  /// with no mail yet is still discoverable. Called by hosts on session
  /// start/switch.
  Future<void> register(String agentId);

  /// The unread messages for [agentId], oldest first, without consuming
  /// them.
  Future<List<AgentMessage>> peek(String agentId);

  /// The unread messages for [agentId], oldest first, consumed (marked
  /// read). A drained message never appears again.
  Future<List<AgentMessage>> drain(String agentId);

  /// The known mailboxes in the fabric, with optional cwd metadata.
  Future<List<MailboxEntry>> directory();
}
