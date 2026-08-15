/// One envelope in the agent messaging fabric: a per-agent inbox model
/// where the main agent, subagents, and even separate Fa instances (sharing
/// one messaging root) exchange messages like people do.
library;

/// One message between two agents.
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

  /// Sender agent id (`main`, a subagent handle id, …).
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

var _messageCounter = 0;

/// Time-ordered, collision-resistant message id:
/// `<utcTimestamp>_<counter>_<rand>`. String order == arrival order.
String newMessageId() {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[^0-9]'),
    '',
  );
  final counter = (_messageCounter++).toRadixString(36).padLeft(4, '0');
  final rand = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return '${stamp}_${counter}_$rand';
}
