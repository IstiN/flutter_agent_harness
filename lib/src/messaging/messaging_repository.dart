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

  /// The known agent ids that have any mail (read or unread) — the
  /// directory of the messaging fabric.
  Future<List<String>> directory();
}
