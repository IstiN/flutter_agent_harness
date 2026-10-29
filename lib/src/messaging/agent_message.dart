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
    this.kind = AgentMessageKind.agent,
    this.fromName,
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

  /// What the recipient should do with it: agent-to-agent chat, or user
  /// input handed over by an attached client (the Fa app's attach view).
  final AgentMessageKind kind;

  /// The sender's human-readable name when the transport knows it: hub
  /// channel mail relayed for an app member names the HUMAN author here
  /// (the wire `fromId` is the relay's hub agent id — bare ids make
  /// agents greet relays instead of people). Absent on legacy payloads.
  final String? fromName;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromId': fromId,
    'toId': toId,
    'text': text,
    'sentAt': sentAt,
    'hops': hops,
    if (kind != AgentMessageKind.agent) 'kind': kind.name,
    if (fromName != null && fromName!.isNotEmpty) 'fromName': fromName,
  };

  factory AgentMessage.fromJson(Map<String, dynamic> json) => AgentMessage(
    id: json['id'] as String? ?? '',
    fromId: json['fromId'] as String? ?? 'unknown',
    toId: json['toId'] as String? ?? '',
    text: json['text'] as String? ?? '',
    sentAt: json['sentAt'] as String? ?? '',
    hops: json['hops'] as int? ?? 0,
    kind: switch (json['kind']) {
      'user' => AgentMessageKind.user,
      _ => AgentMessageKind.agent,
    },
    fromName: (json['fromName'] as String?)?.trim() == ''
        ? null
        : json['fromName'] as String?,
  );
}

/// The delivery intent of an [AgentMessage].
enum AgentMessageKind {
  /// Agent-to-agent chat (the default, and the only kind older writers
  /// produced — a missing `kind` field parses as this).
  agent,

  /// User input forwarded by an attached client (the Fa app's attach
  /// view): the recipient delivers it as a user turn, not agent chat.
  user,
}

var _messageCounter = 0;
final _messageRandom = Random();

/// Time-ordered, collision-resistant message id:
/// `<microsSinceEpoch:16>_<counter:4>_<rand>` — fixed-width components, so
/// string order == arrival order (inbox file names sort correctly).
String newMessageId() {
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final counter = (_messageCounter++).toRadixString(36).padLeft(4, '0');
  // dart2js: shifts are 32-bit — `1 << 32` == 0, so nextInt(0) would throw
  // on web (issue #1074). Spell the bound literally.
  final rand = _messageRandom.nextInt(0xFFFFFFFF).toRadixString(36);
  return '${micros.toString().padLeft(16, '0')}_${counter}_$rand';
}
