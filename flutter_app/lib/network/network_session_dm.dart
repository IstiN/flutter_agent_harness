// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of network_session.dart: the DM virtual-channel surface (§7) —
// `dm:user:<uid>:<agent>@<device>` channels ride the SAME NetworkChatPage
// as regular channels; only the transport branches differ (fanet1 E2EE
// over the device connector instead of channel keys over the network WS).

part of 'network_session.dart';

/// The parsed `dm:user:<uid>:<agent>@<device>` virtual channel id.
typedef DmChannelParts = ({String userId, String agentName, String deviceId});

/// Parses a DM channel id; null on any shape violation.
DmChannelParts? parseDmChannelId(String channelId) {
  if (!channelId.startsWith('dm:user:')) return null;
  final rest = channelId.substring('dm:user:'.length);
  final colon = rest.indexOf(':');
  if (colon <= 0) return null;
  final at = rest.indexOf('@', colon);
  if (at < 0 || at + 1 >= rest.length) return null;
  return (
    userId: rest.substring(0, colon),
    agentName: rest.substring(colon + 1, at),
    deviceId: rest.substring(at + 1),
  );
}

/// The DM branches of [NetworkSession]. One personal-network session can
/// carry any number of DM conversations next to its regular channels.
extension NetworkSessionDm on NetworkSession {
  /// Per-channel remote session target for the next DM send (the tapped
  /// roster session; null = the device's active/latest session).
  Map<String, String?> get dmSessionTargets => _dmSessionTargets;

  /// Attaches the app-scope device connector: DM sends route through it
  /// and its live device-WS mail feeds the open DM channel stores.
  void attachDmConnector(DeviceConnectorService connector) {
    if (identical(_dmConnector, connector)) return;
    _dmConnector = connector;
    unawaited(_dmSubscription?.cancel());
    _dmSubscription = connector.dmMail.listen(_onDmMail);
  }

  /// Synthetic channel metadata + no network-WS subscribe: DM history
  /// rides `GET /api/channels/{dm:id}/messages` (owner-only server
  /// branch) and live frames arrive over the device connector instead.
  void prepareDmChannel(String channelId) {
    if (!channels.any((c) => c.id == channelId)) {
      channels = [
        ...channels,
        Channel(id: channelId, networkId: networkId, name: channelId),
      ];
    }
  }

  Future<void> sendDmText(String channelId, String text) async {
    final connector = _dmConnector;
    final parts = parseDmChannelId(channelId);
    if (connector == null || parts == null) {
      throw StateError('DM connector not attached for $channelId');
    }
    if (!_wallet.hasIdentity) {
      await _wallet.createIfMissing(displayName: identity.displayName);
    }
    final msgId = await connector.sendDmToAgent(
      deviceId: parts.deviceId,
      agentName: parts.agentName,
      sessionId: _dmSessionTargets[channelId],
      text: text,
    );
    final state = channelStates.putIfAbsent(channelId, ChannelState.new);
    state.add(
      ChannelMessage(
        envelopeId: msgId,
        senderId: identity.id,
        senderPub: _wallet.identityPub ?? '',
        text: text,
        isOwn: true,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    notifyDmChanged();
  }

  /// Decrypts one DM history/realtime row: my own frames were sealed
  /// with DH(myPriv, agentPub) — the peer's roster dmPub recomputes the
  /// shared key; their frames carry the sender pubkey in the header.
  Future<ChannelMessage> decodeDmEnvelope(Envelope envelope) async {
    final connector = _dmConnector;
    final parts = parseDmChannelId(envelope.channelId);
    final myId = connector == null ? null : await connector.accountUserId();
    final isOwn =
        envelope.senderId == myId || envelope.senderId == 'user:$myId';
    final frame = hubTryOpenFanet1(envelope.payload);
    final senderPub = isOwn
        ? await _dmPeerPubkey(connector, parts)
        : frame?.senderPubkey;
    String? text;
    var senderPubB64 = '';
    if (frame != null && senderPub != null) {
      try {
        final plaintext = await hubDecryptPayloadWithKeyPair(
          recipientDhKeyPair: await _wallet.identityKeyPair(),
          senderDhPubkey: senderPub,
          frameId: envelope.id,
          aadTarget: envelope.channelId,
          ciphertextB64: frame.ciphertextB64,
        );
        text = isOwn ? _unwrapDmOwnText(plaintext) : plaintext;
        senderPubB64 = base64Encode(senderPub.bytes);
      } on Object {
        text = null; // wrong key epoch / legacy shape — placeholder row
      }
    }
    return ChannelMessage(
      envelopeId: envelope.id,
      senderId: envelope.senderId,
      senderPub: senderPubB64,
      senderName: isOwn ? identity.displayName : parts?.agentName,
      text: text,
      isOwn: isOwn,
      createdAt: envelope.createdAt,
    );
  }

  Future<SimplePublicKey?> _dmPeerPubkey(
    DeviceConnectorService? connector,
    DmChannelParts? parts,
  ) async {
    if (connector == null || parts == null) return null;
    final pub = connector.agentDmPub(
      deviceId: parts.deviceId,
      agentName: parts.agentName,
    );
    if (pub == null) return null;
    return SimplePublicKey(base64Decode(pub), type: KeyPairType.x25519);
  }

  /// Own DM plaintext is the `{"text": …, "sessionId"?}` wrapper; agent
  /// replies are raw assistant text and pass through unchanged.
  String _unwrapDmOwnText(String plaintext) {
    if (!plaintext.startsWith('{')) return plaintext;
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is Map && decoded['text'] is String) {
        return decoded['text'] as String;
      }
    } on FormatException {
      // Raw text also decrypts here — keep it as-is.
    }
    return plaintext;
  }

  void _onDmMail(NetworkEnvelope envelope) {
    final channelId = envelope.channel;
    final ciphertext = envelope.ciphertext;
    if (channelId == null || ciphertext == null) return;
    final state = channelStates[channelId];
    // state.add owns the dedup (seen.add on success) — pre-marking here
    // would make the decoded append a no-op. A contains-check only
    // short-circuits the common redelivery case.
    if (state == null || state.seen.contains(envelope.msgId)) return;
    final ts = DateTime.tryParse(envelope.ts);
    unawaited(
      decodeDmEnvelope(
        Envelope(
          id: envelope.msgId,
          channelId: channelId,
          senderId: envelope.from ?? '',
          payload: ciphertext,
          createdAt: ts,
        ),
      ).then((message) {
        if (!identical(channelStates[channelId], state)) return;
        if (state.add(message)) notifyDmChanged();
      }),
    );
  }
}
