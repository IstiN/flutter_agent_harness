/// flutter_agent_harness messaging contract, mirrored verbatim from
/// upstream `lib/src/messaging/{agent_message,messaging_repository}.dart`.
///
/// In the upstream PR this file is deleted; imports point at the real
/// `package:flutter_agent_harness/src/messaging/messaging_repository.dart`.
/// Mirrored here so this package is self-contained and testable offline.
library;

/// One message between two agents (upstream shape).
final class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.text,
    required this.sentAt,
    this.hops = 0,
  });

  /// Unique message id (assigned by the repository at send time).
  final String id;

  /// Sender agent id.
  final String fromId;

  /// Recipient agent id.
  final String toId;

  /// Message body.
  final String text;

  /// ISO 8601 send timestamp (UTC).
  final String sentAt;

  /// Remaining relay budget (0 refuses further relaying).
  final int hops;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromId': fromId,
    'toId': toId,
    'text': text,
    'sentAt': sentAt,
    'hops': hops,
  };

  factory AgentMessage.fromJson(Map<String, dynamic> json) => AgentMessage(
    id: json['id'] as String? ?? '',
    fromId: json['fromId'] as String? ?? 'unknown',
    toId: json['toId'] as String? ?? '',
    text: json['text'] as String? ?? '',
    sentAt: json['sentAt'] as String? ?? '',
    hops: json['hops'] as int? ?? 0,
  );
}

/// One entry in the messaging-fabric directory (upstream shape).
class MailboxEntry {
  const MailboxEntry({required this.id, this.cwd, this.slug});

  /// The mailbox id (e.g. an agent id).
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

/// Isolated messaging backend for agent inboxes (upstream shape).
abstract interface class MessagingRepository {
  /// Delivers [message] to the recipient's inbox. Implementations must
  /// assign/keep a unique [AgentMessage.id] and never lose a message
  /// silently (a failed delivery throws).
  Future<void> send(AgentMessage message);

  /// Announces [agentId]'s mailbox in the directory (presence).
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
