// Part of hub.dart — channel registry, message routing, mailbox.
//
// Port of the Go channels.go (handleJoin/joinChannel/handleSend/
// deliverChannel/deliverDM) and mailbox.go (enqueue/drain/handleFlush).
// The hub stores and forwards ciphertext only.

part of 'hub.dart';

extension _DapHubChannels on DapHub {
  /// Adds the sender to a channel, creating it on first join (the
  /// creator registers the channel public key).
  void _handleJoin(ClientSession session, DapFrame frame) {
    if (frame.channel.isEmpty) {
      _sendErr(session, DapCodes.badFrame, 'join requires channel');
      return;
    }
    final failure = _joinChannel(session, frame.channel, frame.chanPubkey);
    if (failure != null) {
      _sendErr(session, failure.code, failure.message);
      return;
    }
    session.sendFrame({'op': 'joined', 'channel': frame.channel});
  }

  /// Creates or fetches the channel and adds the agent, enforcing the
  /// ACL. Returns the rejection on failure.
  DapProtoError? _joinChannel(
    ClientSession session,
    String name,
    String chanPubkey,
  ) {
    final channel = channels.putIfAbsent(name, () {
      final created = HubChannel(name: name, pubkey: chanPubkey);
      _persistChannels();
      return created;
    });
    if (!channel.allows(session.pubkey)) {
      _log('join agent=${_logAgent(session)} channel=$name result=denied');
      return const DapProtoError(
        DapCodes.accessDenied,
        'pubkey not on channel ACL',
      );
    }
    channel.members.add(session.agentId);
    final peers = _presencePeers(session.agentId);
    _sendPresence(peers, session.agentId, agents[session.agentId]!,
        online: true);
    _log('join agent=${_logAgent(session)} channel=$name result=ok');
    return null;
  }

  /// Verifies the envelope signature and routes to DM or channel.
  Future<void> _handleSend(ClientSession session, DapFrame frame) async {
    final sigError = await verifySignature(frame, session.pubkey);
    if (sigError != null) {
      _sendErr(session, sigError.code, sigError.message);
      return;
    }
    if (!tsFresh(frame.ts, _now)) {
      _sendErr(
        session,
        DapCodes.staleTs,
        'timestamp outside ±300s window',
      );
      return;
    }
    if (frame.id.isEmpty) {
      _sendErr(session, DapCodes.badFrame, 'send requires id');
      return;
    }
    // Dedupe is latch-after-accept: a frame rejected for membership/ACL/
    // unknown-agent must NOT burn its id — clients retry the same id
    // after fixing the cause, and ids are the idempotency mechanism.
    final key = '${frame.to}|${frame.channel}|${frame.id}';
    if (_sendIds.seen(session.pubkey, key)) {
      _sendErr(session, DapCodes.replayedNonce, 'frame id already used');
      return;
    }
    final delivered = frame.to.isNotEmpty
        ? _deliverDM(session, frame)
        : _deliverChannel(session, frame);
    if (delivered) _sendIds.add(session.pubkey, key);
  }

  /// Fans a channel message out to connected members (the sender gets an
  /// echo) and enqueues it into offline members' mailboxes.
  bool _deliverChannel(ClientSession session, DapFrame frame) {
    final failure = _channelTargetFailure(session, frame);
    if (failure != null) {
      _sendErr(session, failure.code, failure.message);
      return false;
    }
    final channel = channels[frame.channel]!;
    final msg = _msgFrame(session, frame, channel: frame.channel);
    var fanout = 0;
    for (final memberId in channel.members) {
      final peer = clients[memberId];
      if (peer != null) {
        peer.sendFrame(msg);
      } else {
        _enqueue(memberId, msg);
      }
      fanout++;
    }
    _log('chan agent=${_logAgent(session)} channel=${frame.channel} '
        'result=ok fanout=$fanout');
    return true;
  }

  /// The channel routing gauntlet: exists → member → ACL.
  DapProtoError? _channelTargetFailure(
    ClientSession session,
    DapFrame frame,
  ) {
    final channel = channels[frame.channel];
    if (channel == null) {
      return DapProtoError(
        DapCodes.unknownChannel,
        'no such channel: ${frame.channel}',
      );
    }
    if (!channel.members.contains(session.agentId)) {
      return const DapProtoError(
        DapCodes.accessDenied,
        'not a member: join the channel first',
      );
    }
    if (!channel.allows(session.pubkey)) {
      return const DapProtoError(
        DapCodes.accessDenied,
        'pubkey not on channel ACL',
      );
    }
    return null;
  }

  /// Hands a direct message to the recipient — or their mailbox. The
  /// sender never receives an echo (spec).
  bool _deliverDM(ClientSession session, DapFrame frame) {
    if (agents[frame.to] == null) {
      _sendErr(session, DapCodes.unknownAgent, 'no such agent: ${frame.to}');
      return false;
    }
    final msg = _msgFrame(session, frame, to: frame.to);
    final recipient = clients[frame.to];
    if (recipient == null || !recipient.sendFrame(msg)) {
      // Offline — or the connection died between lookup and push: queue
      // to the mailbox instead of silently dropping the frame.
      _enqueue(frame.to, msg);
      _log('dm agent=${_logAgent(session)} to=${frame.to} result=mailbox');
      return true;
    }
    _log('dm agent=${_logAgent(session)} to=${frame.to} result=online');
    return true;
  }

  Map<String, Object?> _msgFrame(
    ClientSession session,
    DapFrame frame, {
    String? channel,
    String? to,
  }) =>
      {
        'op': 'msg',
        if (channel != null) 'channel': channel,
        if (to != null) 'to': to,
        'from': session.agentId,
        'id': frame.id,
        'ts': frame.ts,
        'ciphertext': frame.ciphertext,
      };

  /// Buffers a message for an offline agent. On overflow the oldest
  /// entry is dropped and the mailbox_full flag latches until flush.
  int _enqueue(String agentId, Map<String, Object?> msg) {
    final queue = mailbox.putIfAbsent(agentId, () => [])..add(msg);
    if (queue.length > mailboxCap) {
      queue.removeRange(0, queue.length - mailboxCap);
      mailboxDropped.add(agentId);
    }
    return queue.length;
  }

  /// Streams queued messages in order, reports mailbox_full at most once
  /// per overflow episode, then confirms with a count.
  void _handleFlush(ClientSession session) {
    final queued = mailbox.remove(session.agentId) ?? [];
    final dropped = mailboxDropped.remove(session.agentId);
    for (final msg in queued) {
      session.sendFrame(msg);
    }
    if (dropped) {
      _sendErr(
        session,
        DapCodes.mailboxFull,
        'mailbox overflowed; oldest messages dropped',
      );
    }
    session.sendFrame({'op': 'flushed', 'count': queued.length});
    _log('flush agent=${session.agentId} count=${queued.length} '
        'overflowed=$dropped');
  }

  /// Restores the channel registry. A missing/corrupt file is not an
  /// error (first boot).
  Future<void> _loadChannels() async {
    final text = await _config.channelStore.read();
    if (text == null) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      _log('store: parse channels failed');
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final list = decoded['channels'];
    if (list is! List) return;
    for (final record in list) {
      if (record is! Map || record['name'] is! String) continue;
      final channel = HubChannel(name: record['name'] as String)
        ..pubkey = record['pubkey'] as String? ?? ''
        ..allowed = [
          if (record['allowed'] is List)
            for (final a in record['allowed'] as List) '$a',
        ];
      channels[channel.name] = channel;
    }
  }

  /// Persists the channel registry, fire-and-forget.
  void _persistChannels() {
    final records = [
      for (final channel in channels.values)
        {
          'name': channel.name,
          if (channel.pubkey.isNotEmpty) 'pubkey': channel.pubkey,
          if (channel.allowed.isNotEmpty) 'allowed': channel.allowed,
        },
    ];
    unawaited(
      _config.channelStore
          .write(jsonEncode({'channels': records}))
          .catchError((Object e) => _log('store: write channels failed: $e')),
    );
  }
}
