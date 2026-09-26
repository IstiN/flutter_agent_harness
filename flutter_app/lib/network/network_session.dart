// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// ignore_for_file: prefer_initializing_formals — named private
// parameters cannot be initializing formals in Dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'envelope_codec.dart';
import 'fa_network_client.dart';
import 'fa_network_ws.dart';
import 'key_wallet.dart';
import 'models.dart';
import 'showcase_viewer.dart';

/// One decrypted channel message, ready for the chat UI.
final class ChannelMessage {
  const ChannelMessage({
    required this.envelopeId,
    required this.senderId,
    required this.senderPub,
    required this.text,
    required this.isOwn,
    this.createdAt,
  });

  /// The envelope id — the at-least-once dedupe key.
  final String envelopeId;

  /// The fa_network member id of the sender.
  final String senderId;

  /// The sender's X25519 pubkey from the fanet1 frame ('' when the
  /// envelope could not be decrypted).
  final String senderPub;

  /// The decrypted plaintext; `null` when the envelope is undecryptable
  /// (unknown key, hostile garbage) — the UI renders a placeholder.
  final String? text;

  /// Whether the local wallet identity sent this message.
  final bool isOwn;
  final DateTime? createdAt;
}

/// The live message store of one channel: deduped, decrypted, paged.
final class ChannelState {
  final List<ChannelMessage> messages = [];
  final Set<String> seen = {};

  /// Pagination cursor of the NEXT older page; null = nothing older.
  String? nextCursor;

  /// True until the first history page landed (count still unknown).
  bool historyResolved = false;
  bool loading = false;
  String? loadError;

  /// `FaChatService.historyAboveCount` semantics: null while unknown,
  /// 0 once everything is loaded, 1 as a generic "there is more" signal
  /// (the contract's cursor pagination yields no exact counts).
  int? get historyAboveCount => !historyResolved
      ? null
      : nextCursor != null
      ? 1
      : 0;

  bool add(ChannelMessage message) {
    if (!seen.add(message.envelopeId)) return false;
    messages.add(message);
    return true;
  }
}

/// The runtime of one joined fa_network network (issue #955): owns the
/// REST client + realtime socket + wallet glue, the member roster with
/// presence, and one [ChannelState] per opened channel. Everything the UI
/// reads flows through this [ChangeNotifier]; everything it writes is a
/// method call here.
///
/// Invariants honored here:
/// - at-least-once delivery ⇒ envelopes are deduped by id (AC-B7/E1);
/// - an undecryptable envelope renders as a placeholder, never crashes;
/// - no key material ever leaves the wallet (I1/I2) — payloads are
///   ciphertext before they reach client/socket.
final class NetworkSession extends ChangeNotifier {
  NetworkSession({
    required this.networkId,
    required this.identity,
    required FaNetworkClient client,
    required FaNetworkWs ws,
    required KeyWallet wallet,
    EnvelopeCodec codec = const EnvelopeCodec(),
    Uuid uuid = const Uuid(),
  }) : _client = client,
       _ws = ws,
       _wallet = wallet,
       _codec = codec,
       _uuid = uuid;

  final String networkId;
  final JoinedIdentity identity;
  final FaNetworkClient _client;
  final FaNetworkWs _ws;
  final KeyWallet _wallet;
  final EnvelopeCodec _codec;
  final Uuid _uuid;

  StreamSubscription<WsEvent>? _events;

  /// The member roster by id, presence included (roster.snapshot +
  /// presence.changed folded in).
  final Map<String, Member> roster = {};

  /// The network's channels, list order as served.
  List<Channel> channels = const [];

  /// Per-channel message stores, created by [openChannel].
  final Map<String, ChannelState> channelStates = {};

  /// True while the relay reports `network.offline` (badges, queueing).
  bool networkOffline = false;

  /// The last session-level error surfaced to the UI (refresh, history
  /// paging); null when the last operation succeeded.
  String? error;

  /// Fetches channels + roster and connects the socket. Idempotent.
  Future<void> start() async {
    if (_events != null) return;
    _events = _ws.events.listen(_onWsEvent);
    try {
      channels = await _client.listChannels(networkId);
      final members = await _client.listMembers(networkId);
      roster
        ..clear()
        ..addEntries(members.map((m) => MapEntry(m.id, m)));
      error = null;
    } on FaNetworkException catch (e) {
      error = e.message;
    }
    notifyListeners();
    unawaited(_ws.connect());
  }

  /// Adds a freshly created channel to the local list (the manager's
  /// `createChannel` calls this) and notifies — the rail updates live.
  void addChannel(Channel channel) {
    if (channels.any((c) => c.id == channel.id)) return;
    channels = [...channels, channel];
    notifyListeners();
  }

  /// Opens a channel: first history page + socket subscription.
  Future<void> openChannel(String channelId) async {
    final state = channelStates.putIfAbsent(channelId, ChannelState.new);
    _ws.subscribe(channelId);
    if (state.historyResolved || state.loading) return;
    await _loadHistoryPage(channelId, state);
  }

  /// Pages the next chunk of older history into the channel store.
  Future<void> loadOlder(String channelId) async {
    final state = channelStates[channelId];
    if (state == null || state.loading || state.nextCursor == null) return;
    await _loadHistoryPage(channelId, state);
  }

  Future<void> _loadHistoryPage(String channelId, ChannelState state) async {
    state.loading = true;
    state.loadError = null;
    notifyListeners();
    try {
      final page = await _client.listMessages(
        channelId,
        cursor: state.nextCursor,
      );
      // History pages arrive newest-first; prepend each as served so the
      // store stays oldest-first, with id-dedupe on the way in.
      for (final envelope in page.items) {
        if (state.seen.contains(envelope.id)) continue;
        final message = await _decode(envelope);
        state.seen.add(envelope.id);
        state.messages.insert(0, message);
      }
      state.nextCursor = (page.nextCursor?.isEmpty ?? true)
          ? null
          : page.nextCursor;
      state.historyResolved = true;
    } on FaNetworkException catch (e) {
      state.loadError = e.message;
    } finally {
      state.loading = false;
      notifyListeners();
    }
  }

  /// Sends [text] into [channelId] (E2E before it leaves the process).
  /// The socket queues while offline and flushes once on reconnect (E1).
  Future<void> sendText(
    String channelId,
    String text, {
    List<String>? mentions,
  }) async {
    final channel = _channelById(channelId);
    // Identity is lazy (no onboarding gate): a send on a wallet without
    // an identity creates it silently with the member's display name —
    // signing needs the keypair, blocking the UI is never an option.
    if (!_wallet.hasIdentity) {
      await _wallet.createIfMissing(displayName: identity.displayName);
    }
    // The envelope id doubles as the fanet1 AAD frame id: the sender
    // generates the client uuid and binds ciphertext + envelope to it.
    final envelopeId = _uuid.v4();
    final payload = await _encrypt(channel, text, envelopeId);
    final state = channelStates.putIfAbsent(channelId, ChannelState.new);
    // Optimistic append; the relayed echo dedupes by the same id.
    state.add(
      ChannelMessage(
        envelopeId: envelopeId,
        senderId: identity.id,
        senderPub: _wallet.identityPub ?? '',
        text: text,
        isOwn: true,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    notifyListeners();
    _ws.sendEnvelope(
      channelId: channelId,
      id: envelopeId,
      payload: payload,
      mentions: mentions,
      senderKey: _wallet.identityPub,
    );
  }

  Channel _channelById(String channelId) => channels.firstWhere(
    (c) => c.id == channelId,
    orElse: () => Channel(id: channelId, networkId: networkId, isPublic: false),
  );

  Future<String> _encrypt(Channel channel, String text, String frameId) async {
    // Public showcase channels have no chankey: raw payload by contract.
    if (channel.isPublic) return encodePublicChannelText(text);
    final senderIdentity = await _wallet.identityKeyPair();
    final channelKeys = _wallet.channelKeysFor(networkId, channel.id);
    if (channelKeys == null) {
      throw StateError(
        'no channel keys for $networkId/${channel.id} in the wallet',
      );
    }
    return _codec.encrypt(
      senderIdentity: senderIdentity,
      channelPub: _codec.publicKeyFromB64(channelKeys.pub),
      frameId: frameId,
      channelName: channel.name ?? channel.id,
      plaintext: text,
    );
  }

  Future<ChannelMessage> _decode(Envelope envelope) async {
    final isOwn = envelope.senderId == identity.id;
    final known = channels.where((c) => c.id == envelope.channelId);
    // Public showcase channels have no chankey at all: the payload is
    // base64(raw message) (fa_network showcase contract).
    if (known.isNotEmpty && known.first.isPublic) {
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: '',
        text: decodePublicChannelPayload(envelope.payload),
        isOwn: isOwn,
        createdAt: envelope.createdAt,
      );
    }
    final keys = _wallet.channelKeysFor(networkId, envelope.channelId);
    if (keys == null) {
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: '',
        text: null,
        isOwn: isOwn,
        createdAt: envelope.createdAt,
      );
    }
    final channel = _channelById(envelope.channelId);
    try {
      final decoded = await _codec.decrypt(
        channelKeyPair: await _codec.keyPairFromPriv(keys.priv),
        // The fanet1 AAD frame id IS the envelope id (see sendText).
        frameId: envelope.id,
        channelName: channel.name ?? channel.id,
        payloadB64: envelope.payload,
      );
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: decoded.senderPub,
        text: decoded.plaintext,
        isOwn: isOwn,
        createdAt: envelope.createdAt,
      );
    } on EnvelopeCryptoException {
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: '',
        text: null,
        isOwn: isOwn,
        createdAt: envelope.createdAt,
      );
    }
  }

  void _onWsEvent(WsEvent event) {
    switch (event) {
      case RosterSnapshot(:final members):
        roster
          ..clear()
          ..addEntries(members.map((m) => MapEntry(m.id, m)));
        notifyListeners();
      case EnvelopeReceived(:final envelope):
        unawaited(_onEnvelope(envelope));
      case PresenceChanged(:final memberId, :final presence):
        final member = roster[memberId];
        if (member != null) {
          roster[memberId] = Member(
            id: member.id,
            memberClass: member.memberClass,
            displayName: member.displayName,
            presence: presence,
          );
          notifyListeners();
        }
      case NetworkOffline():
        networkOffline = true;
        notifyListeners();
      case NetworkDrain():
        networkOffline = false;
        notifyListeners();
        unawaited(_refreshAfterReconnect());
      case WakeupDispatched():
        break;
      case WsError(:final message):
        error = message;
        notifyListeners();
    }
  }

  Future<void> _onEnvelope(Envelope envelope) async {
    final state = channelStates[envelope.channelId];
    if (state == null) return; // not opened — the rail badge counts instead
    final message = await _decode(envelope);
    if (state.add(message)) notifyListeners();
  }

  /// After a reconnect the server drains queued envelopes; rebuild the
  /// ground truth from REST (channels + the open channels' latest page)
  /// — dedupe makes the overlap free (snapshot + history resume).
  Future<void> _refreshAfterReconnect() async {
    try {
      channels = await _client.listChannels(networkId);
      error = null;
    } on FaNetworkException catch (e) {
      error = e.message;
    }
    for (final entry in channelStates.entries) {
      final state = entry.value;
      state.nextCursor = null;
      state.historyResolved = false;
      await _loadHistoryPage(entry.key, state);
    }
    notifyListeners();
  }

  /// Tears the session down (leave/network switch): socket closed, event
  /// subscription cancelled. The wallet keeps every key (I1).
  ///
  /// Fire-and-forget: stream cancel/close futures resolve on the zone's
  /// event queue, which wedges `testWidgets`'s implicit end-of-test pump —
  /// teardown is best-effort and needs no completion guarantee.
  Future<void> close() async {
    final events = _events;
    _events = null;
    if (events != null) unawaited(events.cancel());
    unawaited(_ws.disconnect());
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
