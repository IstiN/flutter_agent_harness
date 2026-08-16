/// One envelope in the agent messaging fabric: a per-agent inbox model
/// where the main agent, subagents, and even separate Fa instances (sharing
/// one messaging root) exchange messages like people do.
library;

import 'dart:math';

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
final _messageRandom = Random();

/// Time-ordered, collision-resistant message id:
/// `<microsSinceEpoch:16>_<counter:4>_<rand>` — fixed-width components, so
/// string order == arrival order (inbox file names sort correctly).
String newMessageId() {
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final counter = (_messageCounter++).toRadixString(36).padLeft(4, '0');
  final rand = _messageRandom.nextInt(1 << 32).toRadixString(36);
  return '${micros.toString().padLeft(16, '0')}_${counter}_$rand';
}
