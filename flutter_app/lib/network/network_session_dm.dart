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

/// Human-facing peer label for a DM virtual channel. The wire id belongs
/// in routing logs, not in the page title or composer hint. A roster tap
/// supplies its richer device label; inbox/history restores use a generic
/// human label rather than leaking the stable device id from the channel id.
String dmChannelPeerLabel(String channelId, {String? deviceLabel}) {
  final parts = parseDmChannelId(channelId);
  if (parts == null) return channelDisplayLabel(channelId);
  var device = deviceLabel?.trim() ?? '';
  // Restored channel rows historically persisted the WHOLE label in `name`.
  // Accept that form without duplicating the agent suffix, and recognize the
  // old raw-device fallback so it is upgraded instead of shown again.
  final agentSuffix = ' · ${parts.agentName}';
  if (device.endsWith(agentSuffix)) {
    device = device.substring(0, device.length - agentSuffix.length).trim();
  }
  if (device == parts.deviceId) device = '';
  return '${device.isEmpty ? 'Device' : device} · '
      '${parts.agentName}'; // l10n:ignore
}

/// The DM branches of [NetworkSession]. One personal-network session can
/// carry any number of DM conversations next to its regular channels.
extension NetworkSessionDm on NetworkSession {
  /// Per-channel remote session target for the next DM send (the tapped
  /// roster session; null = the device's active/latest session).
  Map<String, String?> get dmSessionTargets => _dmSessionTargets;

  /// Selects the visible DM thread and synchronously notifies open panes.
  /// Null selects the device-general bucket for legacy/session-less rows.
  void selectDmSession(String channelId, String? sessionId, {String? title}) {
    final normalizedTitle = title?.trim();
    if (_dmSessionTargets[channelId] == sessionId &&
        _dmSessionTitles[channelId] == normalizedTitle) {
      return;
    }
    _dmSessionTargets[channelId] = sessionId;
    _dmSessionTitles[channelId] = normalizedTitle?.isEmpty == true
        ? null
        : normalizedTitle;
    notifyDmChanged();
  }

  /// Human title for the selected DM thread, or null for the device header.
  String? dmSessionTitle(String channelId) => _dmSessionTitles[channelId];

  /// Attaches the app-scope device connector: DM sends route through it
  /// and its live device-WS mail feeds the open DM channel stores.
  void attachDmConnector(DeviceConnectorService connector) {
    if (identical(_dmConnector, connector)) return;
    _dmConnector = connector;
    unawaited(_dmSubscription?.cancel());
    _dmSubscription = connector.dmMail.listen(_onDmMail);
  }

  /// Synthetic channel metadata. DM history rides
  /// `GET /api/channels/{dm:id}/messages` (owner-only server branch);
  /// live frames arrive on the account network WS and device connector,
  /// with [ChannelState.seen] deduplicating the two delivery paths.
  /// A roster-supplied [deviceLabel] also upgrades older generic/raw labels.
  void prepareDmChannel(String channelId, {String? deviceLabel}) {
    final label = dmChannelPeerLabel(channelId, deviceLabel: deviceLabel);
    final index = channels.indexWhere((channel) => channel.id == channelId);
    if (index < 0) {
      channels = [
        ...channels,
        Channel(id: channelId, networkId: networkId, name: label),
      ];
    } else if (deviceLabel?.trim().isNotEmpty == true &&
        channels[index].name != label) {
      final previous = channels[index];
      final updated = [...channels];
      updated[index] = Channel(
        id: previous.id,
        networkId: previous.networkId,
        name: label,
        isPublic: previous.isPublic,
        acl: previous.acl,
        retentionDays: previous.retentionDays,
      );
      channels = updated;
    }
    _ensureDmPolling();
  }

  /// The backend persists user/agent DM mail but currently does not push the
  /// user-addressed half to either live socket. Poll only OPEN DM stores as a
  /// v1 fallback; real network/device frames still win through the same
  /// envelope-id dedup. One guarded timer serves every open DM in this session.
  void _ensureDmPolling() {
    if (_dmPollTimer?.isActive ?? false) return;
    _dmPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_pollOpenDmChannels());
    });
  }

  @visibleForTesting
  Future<void> debugPollDmChannels() => _pollOpenDmChannels();

  Future<void> _pollOpenDmChannels() async {
    if (_dmPollInFlight) return;
    final open = channelStates.entries
        .where((entry) => isDmChannel(entry.key))
        .toList(growable: false);
    if (open.isEmpty) {
      _dmPollTimer?.cancel();
      _dmPollTimer = null;
      return;
    }
    _dmPollInFlight = true;
    try {
      for (final entry in open) {
        if (_dmPollTimer == null) return; // closed while a request was away
        try {
          await _pollDmChannel(entry.key, entry.value);
        } on Object catch (error) {
          // A transient REST/decode failure must not kill later ticks or
          // become an unhandled Timer exception.
          debugPrint('[dm] history poll failed ${entry.key}: $error');
        }
      }
    } finally {
      _dmPollInFlight = false;
    }
  }

  Future<void> _pollDmChannel(String channelId, ChannelState state) async {
    final revision = state._revision;
    final page = await _client.listMessages(channelId, useAccountToken: true);
    var changed = false;
    for (final envelope in page.items) {
      if (state.seen.contains(envelope.id)) continue;
      final message = await _decode(envelope);
      if (!_isCurrentChannelState(channelId, state, revision) ||
          _dmPollTimer == null) {
        return;
      }
      // Unlike initial history pagination, a poll MERGES the newest tail:
      // state.add appends after the outgoing message and owns race dedup
      // against either live socket path.
      if (state.add(message)) changed = true;
    }
    if (changed) notifyDmChanged();
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
    final sessionId = _dmSessionTargets[channelId];
    final msgId = await connector.sendDmToAgent(
      deviceId: parts.deviceId,
      agentName: parts.agentName,
      sessionId: sessionId,
      text: text,
    );
    _dmOwnText[msgId] = text;
    _dmOwnSessionIds[msgId] = sessionId;
    final state = channelStates.putIfAbsent(channelId, ChannelState.new);
    state.add(
      ChannelMessage(
        envelopeId: msgId,
        senderId: identity.id,
        senderPub: _wallet.identityPub ?? '',
        text: text,
        isOwn: true,
        createdAt: DateTime.now().toUtc(),
        sessionId: sessionId,
      ),
    );
    notifyDmChanged();
  }

  /// Decrypts one DM history/realtime row. Direction comes from the
  /// seal outcome — not a roster lookup (review #2197), not pubkey
  /// equality alone (PR review r1: the header pubkey names the SEALING
  /// key while the backend rewrites ANY authenticated sender to the
  /// bare account uid). (1) A frame sealed by THIS wallet is mine; the
  /// shared key DH(myPriv, agentPub) is recomputed via the roster dmPub.
  /// (2) A foreign frame that decrypts under DH(myPriv, senderPub) was
  /// sealed TO me — only the peer agent does that, so replies keep
  /// their agent row even when the roster evicted the entry mid-chat.
  /// (3) A foreign frame that fails to decrypt (another device of the
  /// same account, key rotation, legacy shape) has no seal signal left;
  /// the rewritten sender id keeps it an honest placeholder row,
  /// own-shaped when it carries my account uid.
  Future<ChannelMessage> decodeDmEnvelope(Envelope envelope) async {
    final connector = _dmConnector;
    final parts = parseDmChannelId(envelope.channelId);
    final myId = connector == null ? null : await connector.accountUserId();
    final frame = hubTryOpenFanet1(envelope.payload);
    final myPub = _wallet.identityPub;
    final senderIsMyWallet =
        frame != null &&
        myPub != null &&
        base64Encode(frame.senderPubkey.bytes) == myPub;
    String? text;
    String? sessionId;
    var senderPubB64 = '';
    var agentReply = false;
    if (frame != null && !senderIsMyWallet) {
      try {
        final plaintext = await hubDecryptPayloadWithKeyPair(
          recipientDhKeyPair: await _wallet.identityKeyPair(),
          senderDhPubkey: frame.senderPubkey,
          frameId: envelope.id,
          aadTarget: envelope.channelId,
          ciphertextB64: frame.ciphertextB64,
        );
        final decoded = _unwrapDmText(plaintext);
        text = decoded.text;
        sessionId = decoded.sessionId;
        senderPubB64 = base64Encode(frame.senderPubkey.bytes);
        agentReply = true; // sealed TO me ⇒ the peer agent's reply
      } on Object {
        text = null; // other device / wrong key epoch / legacy — placeholder
      }
    }
    final isOwn =
        !agentReply &&
        myId != null &&
        (envelope.senderId == myId || envelope.senderId == 'user:$myId');
    final sentText = isOwn ? _dmOwnText[envelope.id] : null;
    if (sentText != null) {
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: _wallet.identityPub ?? '',
        senderName: identity.displayName,
        text: sentText,
        isOwn: true,
        createdAt: envelope.createdAt,
        sessionId: _dmOwnSessionIds[envelope.id],
      );
    }
    if (isOwn && frame != null) {
      // Own history row: the peer's roster dmPub recomputes the shared
      // key DH(myPriv, agentPub) the frame was sealed with.
      final peerPub = await _dmPeerPubkey(connector, parts);
      if (peerPub != null) {
        try {
          final plaintext = await hubDecryptPayloadWithKeyPair(
            recipientDhKeyPair: await _wallet.identityKeyPair(),
            senderDhPubkey: peerPub,
            frameId: envelope.id,
            aadTarget: envelope.channelId,
            ciphertextB64: frame.ciphertextB64,
          );
          final decoded = _unwrapDmText(plaintext);
          text = decoded.text;
          sessionId = decoded.sessionId;
          senderPubB64 = base64Encode(peerPub.bytes);
        } on Object {
          text = null; // peer entry rotated / evicted — placeholder row
        }
      }
    }
    return ChannelMessage(
      envelopeId: envelope.id,
      senderId: envelope.senderId,
      senderPub: senderPubB64,
      senderName: isOwn
          ? identity.displayName
          : _agentSenderLabel(envelope.channelId, parts, sessionId),
      text: text,
      isOwn: isOwn,
      createdAt: envelope.createdAt,
      sessionId: sessionId,
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

  /// Incoming DM sender label: the tapped session's human title when this
  /// row belongs to it, otherwise 'fa' for the default app agent ('main'
  /// is an internal address part, not a display name) or the agent name.
  String? _agentSenderLabel(
    String channelId,
    DmChannelParts? parts,
    String? sessionId,
  ) {
    if (sessionId != null &&
        sessionId == _dmSessionTargets[channelId] &&
        _dmSessionTitles[channelId] != null) {
      return _dmSessionTitles[channelId];
    }
    final name = parts?.agentName;
    if (name == null || name.isEmpty) return null;
    return name == 'main' ? 'fa' : name;
  }

  /// Thread-aware DM plaintext is `{"text": …, "sessionId"?}` in both
  /// directions. Legacy raw assistant text and malformed wrappers pass
  /// through unchanged and therefore land in the device-general bucket.
  ({String text, String? sessionId}) _unwrapDmText(String plaintext) {
    if (!plaintext.startsWith('{')) return (text: plaintext, sessionId: null);
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is Map && decoded['text'] is String) {
        final sessionId = decoded['sessionId'];
        return (
          text: decoded['text'] as String,
          sessionId: sessionId is String && sessionId.isNotEmpty
              ? sessionId
              : null,
        );
      }
    } on FormatException {
      // Raw text also decrypts here — keep it as-is.
    }
    return (text: plaintext, sessionId: null);
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
          )
          .then((message) {
            if (!identical(channelStates[channelId], state)) return;
            if (state.add(message)) notifyDmChanged();
          })
          .catchError((Object error) {
            // A live DM must never vanish silently (e2e issue #2062).
            debugPrint('[dm] live decode failed ${envelope.msgId}: $error');
          }),
    );
  }
}
