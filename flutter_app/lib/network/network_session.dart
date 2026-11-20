// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// ignore_for_file: prefer_initializing_formals — named private
// parameters cannot be initializing formals in Dart.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'device_connector_service.dart';
import 'envelope_codec.dart';
import 'fa_network_client.dart';
import 'fa_network_ws.dart';
import 'key_wallet.dart';
import 'models.dart';
import 'showcase_viewer.dart';
import '../services/app_log.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show NetworkEnvelope, isDmChannel;
// The fanet1 DM primitives are pure Dart in the messaging core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
// Shared connector DM channel/text semantics (issue #2214 extraction).
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/device_dm.dart';

part 'network_session_dm.dart';

/// One decrypted channel message, ready for the chat UI.
final class ChannelMessage {
  const ChannelMessage({
    required this.envelopeId,
    required this.senderId,
    required this.senderPub,
    required this.text,
    required this.isOwn,
    this.senderName,
    this.createdAt,
    this.sessionId,
    this.replyTo,
  });

  /// The envelope id — the at-least-once dedupe key.
  final String envelopeId;

  /// The fa_network member id of the sender.
  final String senderId;

  /// The sender's display name when known from the envelope itself
  /// (hub-originated frames carry the enrolled DAP agent name —
  /// fa_network#2); the roster remains the source for member senders.
  final String? senderName;

  /// The sender's X25519 pubkey from the fanet1 frame ('' when the
  /// envelope could not be decrypted).
  final String senderPub;

  /// The decrypted plaintext; `null` when the envelope is undecryptable
  /// (unknown key, hostile garbage) — the UI renders a placeholder.
  final String? text;

  /// Whether the local wallet identity sent this message.
  final bool isOwn;
  final DateTime? createdAt;

  /// DM thread target decrypted from the plaintext wrapper. Null identifies
  /// the device-general bucket used by legacy/session-less rows.
  final String? sessionId;

  /// Original user envelope id for a threaded agent reply/delivery receipt.
  /// Unlike [envelopeId], this stays stable when an unacked original is
  /// retried and the peer mints another receipt envelope.
  final String? replyTo;
}

/// The live message store of one channel: deduped, decrypted, paged.
final class ChannelState {
  final List<ChannelMessage> messages = [];
  final Set<String> seen = {};

  Future<void> _realtimeTail = Future.value();
  int _revision = 0;

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
    final candidate = _collapseForInsert(message, existing: messages);
    if (candidate == null) return false;
    messages.add(candidate);
    return true;
  }

  /// Correlates a delivery receipt and returns null when it duplicates the
  /// same state in [existing]. [preceding] limits legacy reply correlation to rows that
  /// chronologically precede the candidate; older history pages are prepended,
  /// so rows already in the store must not supply their legacy correlation.
  ChannelMessage? _collapseForInsert(
    ChannelMessage message, {
    required Iterable<ChannelMessage> existing,
    Iterable<ChannelMessage>? preceding,
  }) {
    final isReceipt =
        message.text == deviceDmQueuedReceipt ||
        message.text == deviceDmAcceptedReceipt;
    if (message.isOwn || !isReceipt) return message;
    // Delivery receipts are STATE, not agent answers. A peer pre-restart
    // retry can mint a fresh envelope id for the same original, so id-dedup
    // alone cannot collapse them. New peers carry replyTo; infer it from
    // the preceding own row for 1.0.751 legacy receipts. Queued and accepted
    // are separate states: one must never dedup away the other's transition.
    final correlation =
        message.replyTo ??
        _latestOwnEnvelopeId(preceding ?? existing, message.sessionId) ??
        'session:${message.senderId}:${message.sessionId ?? ''}';
    final duplicate = existing.any(
      (row) =>
          !row.isOwn &&
          row.text == message.text &&
          row.senderId == message.senderId &&
          row.sessionId == message.sessionId &&
          row.replyTo == correlation,
    );
    if (duplicate) return null;
    if (message.replyTo != null) return message;
    return ChannelMessage(
      envelopeId: message.envelopeId,
      senderId: message.senderId,
      senderPub: message.senderPub,
      senderName: message.senderName,
      text: message.text,
      isOwn: message.isOwn,
      createdAt: message.createdAt,
      sessionId: message.sessionId,
      replyTo: correlation,
    );
  }

  String? _latestOwnEnvelopeId(
    Iterable<ChannelMessage> rows,
    String? sessionId,
  ) {
    for (final message in rows.toList().reversed) {
      if (message.isOwn && message.sessionId == sessionId) {
        return message.envelopeId;
      }
    }
    return null;
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
    Future<ChannelMessage> Function(Envelope envelope)? envelopeDecoder,
    Future<String?> Function()? freshAccountToken,
    Future<String?> Function()? refreshAccountToken,
  }) : _client = client,
       _ws = ws,
       _wallet = wallet,
       _codec = codec,
       _uuid = uuid,
       _envelopeDecoder = envelopeDecoder,
       _freshAccountToken = freshAccountToken,
       _refreshAccountToken = refreshAccountToken;

  final String networkId;
  final JoinedIdentity identity;

  /// The REST base of the hub this session is connected to. Channel-key
  /// imports validate the invite's hub against it — a cross-hub invite
  /// would persist a key no peer on this hub's channels can decrypt with.
  Uri get hubBaseUrl => _client.baseUrl;

  final FaNetworkClient _client;
  final FaNetworkWs _ws;
  final KeyWallet _wallet;
  final EnvelopeCodec _codec;
  final Uuid _uuid;
  final Future<ChannelMessage> Function(Envelope envelope)? _envelopeDecoder;

  /// Account JWT providers for owner-only DM history. The normal provider
  /// refreshes on declared expiry; the second forces a refresh after the
  /// server rejects a still-unexpired cached token (rotation/re-enrollment).
  final Future<String?> Function()? _freshAccountToken;
  final Future<String?> Function()? _refreshAccountToken;

  StreamSubscription<WsEvent>? _events;
  Future<void>? _startup;

  /// The app-scope device connector for DM virtual channels (§7), plus
  /// its live-mail subscription and per-channel remote session targets.
  DeviceConnectorService? _dmConnector;

  /// The attached Devices connector (DM channels only), exposed so the
  /// conversation surface can read the remote agent's roster run state.
  DeviceConnectorService? get dmConnector => _dmConnector;
  StreamSubscription<NetworkEnvelope>? _dmSubscription;
  final _dmSessionTargets = <String, String?>{};
  final _dmSessionTitles = <String, String?>{};

  /// Plaintext/thread target for messages sent by this session. A live
  /// echo/history refresh must never replace a just-sent bubble with a
  /// decrypt placeholder or move it into the device-general bucket.
  final _dmOwnText = <String, String>{};
  final _dmOwnSessionIds = <String, String?>{};
  Timer? _dmPollTimer;
  var _dmPollInFlight = false;

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
  ///
  /// The manager publishes this session before startup completes, so the
  /// shared future is also the decoder-readiness barrier for an early
  /// channel open or realtime envelope.
  Future<void> start() => _startup ??= _start();

  Future<void> _start() async {
    _events = _ws.events.listen(_onWsEvent);
    await _refreshSnapshot();
    notifyListeners();
    unawaited(_ws.connect());
  }

  /// Fetches the authoritative channels + roster snapshot.
  Future<void> _refreshSnapshot() async {
    try {
      channels = await _client.listChannels(networkId);
      final members = await _client.listMembers(networkId);
      roster
        ..clear()
        ..addEntries(members.map((m) => MapEntry(m.id, m)));
      _logRoster('rest', members);
      error = null;
    } on FaNetworkException catch (e) {
      error = e.message;
    }
  }

  /// Manual recovery for a stuck realtime/offline state: restart the
  /// socket and reload the snapshot. Subscriptions and the queued outbox
  /// survive the socket restart (the ws contract keeps both).
  Future<void> reconnect() async {
    await _ws.disconnect();
    await _refreshSnapshot();
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

  /// Renames a channel through the owner/admin management route and replaces
  /// its local metadata only after the server accepts the change.
  Future<Channel> renameChannel(String channelId, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    final updated = await _client.updateChannel(channelId, name: normalized);
    channels = [
      for (final channel in channels)
        if (channel.id == channelId) updated else channel,
    ];
    notifyListeners();
    return updated;
  }

  /// Deletes a channel through the owner/admin management route, then drops
  /// its local list entry, message state and realtime subscription. There is
  /// no delete frame on the socket; the 204 response is the source of truth.
  Future<void> deleteChannel(String channelId) async {
    await _client.deleteChannel(channelId);
    channels = channels.where((c) => c.id != channelId).toList();
    channelStates.remove(channelId);
    _ws.unsubscribe(channelId);
    notifyListeners();
  }

  /// Removes an agent after the owner/admin route accepts the deletion.
  /// The 204 is authoritative; only a subsequent server push can add the
  /// agent back to the roster.
  Future<void> deleteAgent(String agentId) async {
    await _client.deleteAgent(networkId, agentId);
    roster.remove(agentId);
    notifyListeners();
  }

  /// Removes a store member (guest/member) after the owner/admin route
  /// accepts the deletion; the server revokes its sessions and pushes a
  /// fresh roster.snapshot to everyone else.
  Future<void> deleteMember(String memberId) async {
    await _client.deleteMember(networkId, memberId);
    roster.remove(memberId);
    notifyListeners();
  }

  /// Opens a channel: first history page + socket subscription.
  ///
  /// The history load yields to the event loop before notifying: callers
  /// reach this from `initState`/build-adjacent paths, and a synchronous
  /// `notifyListeners` there trips Flutter's build-phase invariant.
  Future<void> openChannel(String channelId) async {
    final state = channelStates.putIfAbsent(channelId, ChannelState.new);
    if (isDmChannel(channelId)) {
      // History decode needs the same lazy identity as send: an enrolled
      // account on a fresh install can open an existing DM before its first
      // outgoing message, so there is no earlier send path to create it.
      if (!_wallet.hasIdentity) {
        await _wallet.createIfMissing(displayName: identity.displayName);
      }
      prepareDmChannel(channelId);
    }
    // User-addressed DM replies arrive on the account network WS; agent-
    // addressed turns arrive on the device connector. Keep both live paths
    // attached — ChannelState.seen dedups their overlap by envelope id.
    _ws.subscribe(channelId);
    if (state.historyResolved || state.loading) return;
    await Future<void>.microtask(() {});
    await _loadHistoryPage(channelId, state);
  }

  /// Reloads the newest history page after this device's channel keys change.
  ///
  /// Cached plaintext cannot be retroactively decrypted, so the decoded store
  /// and dedupe window are rebuilt from the server's ciphertext. The revision
  /// invalidates older history/realtime decodes before they can append stale
  /// placeholders into the refreshed store.
  Future<void> reloadChannel(String channelId) async {
    final state = channelStates[channelId];
    if (state == null) return openChannel(channelId);
    state._revision++;
    state.messages.clear();
    state.seen.clear();
    state.nextCursor = null;
    state.historyResolved = false;
    state.loadError = null;
    await _loadHistoryPage(channelId, state);
  }

  /// Pages the next chunk of older history into the channel store.
  Future<void> loadOlder(String channelId) async {
    final state = channelStates[channelId];
    if (state == null || state.loading || state.nextCursor == null) return;
    await _loadHistoryPage(channelId, state);
  }

  bool _isCurrentChannelState(
    String channelId,
    ChannelState state,
    int revision,
  ) =>
      identical(channelStates[channelId], state) && state._revision == revision;

  /// Reads one history page with the two recoverable DM failure modes:
  /// an expired/rotated account token refreshes once, and an invalid server
  /// cursor restarts pagination from the newest page instead of spinning on
  /// the same cursor forever. Ordinary channels keep their member token.
  Future<MessagePage> _listHistoryPage(
    String channelId,
    ChannelState state, {
    bool latest = false,
  }) async {
    final account = isDmChannel(channelId);
    if (account) await _syncAccountToken(refresh: false);
    var authRetried = false;
    var cursorReset = false;
    while (true) {
      try {
        return await _client.listMessages(
          channelId,
          cursor: latest || cursorReset ? null : state.nextCursor,
          useAccountToken: account,
        );
      } on FaNetworkException catch (error) {
        if (account &&
            error.statusCode == 401 &&
            !authRetried &&
            await _syncAccountToken(refresh: true)) {
          authRetried = true;
          continue;
        }
        if (_unknownHistoryCursor(error) && !cursorReset) {
          cursorReset = true;
          state.nextCursor = null;
          if (!latest) {
            // Older pages cannot be prepended safely after jumping back to
            // the newest page. Rebuild from that fresh page instead.
            state.messages.clear();
            state.seen.clear();
          }
          continue;
        }
        rethrow;
      }
    }
  }

  Future<bool> _syncAccountToken({required bool refresh}) async {
    final provider = refresh ? _refreshAccountToken : _freshAccountToken;
    if (provider == null) return false;
    final token = await provider();
    if (token == null || token.isEmpty) return false;
    _client.jwt = token;
    return true;
  }

  bool _unknownHistoryCursor(FaNetworkException error) =>
      error.statusCode == 404 &&
      error.message.toLowerCase().contains('unknown cursor');

  Future<void> _loadHistoryPage(String channelId, ChannelState state) async {
    final revision = state._revision;
    state.loading = true;
    state.loadError = null;
    notifyListeners();
    try {
      final page = await _listHistoryPage(channelId, state);
      if (!_isCurrentChannelState(channelId, state, revision)) return;
      // Chat-order pagination (fa_network contract): pages arrive
      // ascending oldest→newest; the first (cursor-less) page IS the
      // newest tail, later pages are strictly older and prepend as a
      // block. An empty nextCursor = the bottom of history (no older).
      final decoded = <ChannelMessage>[];
      for (final envelope in page.items) {
        if (!state.seen.add(envelope.id)) continue;
        final message = await _decode(envelope);
        if (!_isCurrentChannelState(channelId, state, revision)) return;
        final candidate = state._collapseForInsert(
          message,
          existing: decoded.followedBy(state.messages),
          preceding: decoded,
        );
        if (candidate != null) decoded.add(candidate);
      }
      state.messages.insertAll(0, decoded);
      state.nextCursor = (page.nextCursor?.isEmpty ?? true)
          ? null
          : page.nextCursor;
      state.historyResolved = true;
    } on FaNetworkException catch (e) {
      if (_isCurrentChannelState(channelId, state, revision)) {
        state.loadError = e.message;
      }
    } finally {
      if (_isCurrentChannelState(channelId, state, revision)) {
        state.loading = false;
        notifyListeners();
      }
    }
  }

  /// Sends [text] into [channelId] (E2E before it leaves the process).
  /// The socket queues while offline and flushes once on reconnect (E1).
  Future<void> sendText(
    String channelId,
    String text, {
    List<String>? mentions,
  }) async {
    if (isDmChannel(channelId)) return sendDmText(channelId, text);
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

  /// Plaintext shape for channel payloads: the text plus, when the member
  /// has a display name, the sender block that lets DAP agents attribute
  /// the HUMAN author (the wire sender of a relayed frame is the relay's
  /// hub agent id). Legacy consumers read `text` and ignore the rest;
  /// decoders here accept raw payloads from producers without a name.
  String _channelPlaintext(String text) {
    final name = identity.displayName.trim();
    if (name.isEmpty) return text;
    return jsonEncode({
      'text': text,
      'sender': {'name': name, 'id': identity.id},
    });
  }

  /// Unwraps an inbound channel plaintext: app members send the
  /// `{"text": …, "sender": {…}}` envelope (see [_channelPlaintext]);
  /// raw text from pure-DAP agents or older producers passes through.
  ({String text, String? senderName}) _unwrapChannelPlaintext(
    String plaintext,
  ) {
    if (!plaintext.startsWith('{')) return (text: plaintext, senderName: null);
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is Map && decoded['text'] is String) {
        final sender = decoded['sender'];
        final name = sender is Map ? sender['name'] : null;
        return (
          text: decoded['text'] as String,
          senderName: name is String && name.trim().isNotEmpty ? name : null,
        );
      }
    } on Object {
      // Raw text that happens to start with '{' — fall through.
    }
    return (text: plaintext, senderName: null);
  }

  Future<String> _encrypt(Channel channel, String text, String frameId) async {
    // Public showcase channels have no chankey: raw payload by contract.
    if (channel.isPublic) {
      return encodePublicChannelText(
        text,
        senderName: identity.displayName,
        senderId: identity.id,
      );
    }
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
      // AAD binds to the channel id (the hub-side name) — pure-DAP agents
      // cannot know the display name (#1002).
      aadTarget: channel.id,
      plaintext: _channelPlaintext(text),
    );
  }

  Future<ChannelMessage> _decode(Envelope envelope) async {
    // Never guess that an unknown channel is private: on first open the
    // history response can win the race with start()'s channel listing.
    // Waiting here keeps the envelope out of the decoded-message cache
    // until the public/private decoder is known; the history/realtime
    // completion notification then rebuilds the chat with plaintext.
    await _startup;
    final envelopeDecoder = _envelopeDecoder;
    if (envelopeDecoder != null) return envelopeDecoder(envelope);
    if (isDmChannel(envelope.channelId)) return decodeDmEnvelope(envelope);
    final isOwn = envelope.senderId == identity.id;
    final known = channels.where((c) => c.id == envelope.channelId);
    // Public showcase channels have no chankey at all: the payload is
    // base64(raw message) (fa_network showcase contract).
    if (known.isNotEmpty && known.first.isPublic) {
      final payloadSender = decodePublicChannelSender(envelope.payload);
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: '',
        senderName: (envelope.senderName?.isNotEmpty ?? false)
            ? envelope.senderName
            : payloadSender?.name,
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
        senderName: envelope.senderName,
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
        // AAD contract: the channel id (#1002); pre-contract frames were
        // sealed with the display name — accept them via the fallback.
        aadTarget: envelope.channelId,
        legacyAadTarget: channel.name,
        payloadB64: envelope.payload,
      );
      // App members wrap the text with a sender block (human attribution
      // across the relay); pure-DAP agents send raw text — both render.
      final unwrapped = _unwrapChannelPlaintext(decoded.plaintext);
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: decoded.senderPub,
        senderName: (envelope.senderName?.isNotEmpty ?? false)
            ? envelope.senderName
            : unwrapped.senderName,
        text: unwrapped.text,
        isOwn: isOwn,
        createdAt: envelope.createdAt,
      );
    } on EnvelopeCryptoException {
      return ChannelMessage(
        envelopeId: envelope.id,
        senderId: envelope.senderId,
        senderPub: '',
        senderName: envelope.senderName,
        text: null,
        isOwn: isOwn,
        createdAt: envelope.createdAt,
      );
    }
  }

  /// Presence diagnostics (fa_network#4): the online count is derived
  /// from this roster — log exactly what the server sent so a 0-online
  /// report can be attributed to server vs client in one shot.
  void _logRoster(String source, Iterable<Member> members) {
    AppLog.i(
      'fa_network',
      'roster.$source: ${members.map((m) => '${m.id}:${m.displayName}:${m.memberClass.name}:${m.presence.name}').join(', ')}',
    );
  }

  void _onWsEvent(WsEvent event) {
    switch (event) {
      case WsConnected():
        _onWsConnected();
      case RosterSnapshot(:final members):
        _onRosterSnapshot(members);
      case EnvelopeReceived(:final envelope):
        unawaited(_onEnvelope(envelope));
      case PresenceChanged():
        _onPresenceChanged(event);
      case NetworkOffline():
        _onNetworkOffline();
      case NetworkDrain():
        _onNetworkDrain();
      case WakeupDispatched():
        break;
      case WsError(:final message):
        _onWsError(message);
    }
  }

  void _onWsConnected() {
    // The greet sends network.offline only when the hub is DOWN. If recovery
    // happened while this socket was away, no drain is replayed to it — clear
    // the sticky flag on every fresh socket and let a real offline greet
    // reassert it when needed.
    if (networkOffline) {
      networkOffline = false;
      notifyListeners();
    }
  }

  void _onRosterSnapshot(List<Member> members) {
    roster
      ..clear()
      ..addEntries(members.map((m) => MapEntry(m.id, m)));
    _logRoster('snapshot', members);
    notifyListeners();
  }

  void _onPresenceChanged(PresenceChanged event) {
    final member = roster[event.memberId];
    if (member != null) {
      roster[event.memberId] = Member(
        id: member.id,
        memberClass: member.memberClass,
        displayName: member.displayName,
        presence: event.presence,
        // Legacy presence frames carry no access: retain the snapshot's
        // metadata instead of erasing it on every presence flip.
        access: event.access ?? member.access,
      );
      notifyListeners();
    } else if (event.memberId.isNotEmpty &&
        (event.displayName.isNotEmpty || event.memberClass != null)) {
      // A hub agent that came online AFTER the snapshot: the server includes
      // displayName/class precisely so clients can insert it instead of
      // dropping the event (online stayed 0).
      roster[event.memberId] = Member(
        id: event.memberId,
        memberClass: event.memberClass ?? MemberClass.unknown,
        displayName: event.displayName,
        presence: event.presence,
        access: event.access,
      );
      notifyListeners();
    }
  }

  void _onNetworkOffline() {
    networkOffline = true;
    notifyListeners();
  }

  void _onNetworkDrain() {
    networkOffline = false;
    notifyListeners();
    unawaited(_refreshAfterReconnect());
  }

  void _onWsError(String message) {
    error = message;
    notifyListeners();
  }

  /// Test seam for the exact future returned to the unawaited socket path.
  @visibleForTesting
  Future<void> debugHandleEnvelope(Envelope envelope) => _onEnvelope(envelope);

  Future<void> _onEnvelope(Envelope envelope) {
    final channelId = envelope.channelId;
    final state = channelStates[channelId];
    if (state == null) {
      return Future.value(); // not opened — the rail badge counts instead
    }
    final revision = state._revision;
    // Decode and append in socket-arrival order, not decode-completion order.
    final operation = state._realtimeTail.then((_) async {
      if (!_isCurrentChannelState(channelId, state, revision)) return;
      final message = await _decode(envelope);
      if (!_isCurrentChannelState(channelId, state, revision)) return;
      if (state.add(message)) notifyListeners();
    });
    // A failed decode must not prevent later arrivals from being handled,
    // and the future handed back to the (unawaited) call site must carry
    // the same containment: returning the raw `operation` would complete
    // the returned future with the decode error even though the chain
    // itself already swallowed it (gh-1895 review).
    state._realtimeTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return state._realtimeTail;
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
      // Chat-order history: the fresh cursor-less page is the NEWEST
      // tail — it cannot be prepended onto the old list, so the store is
      // rebuilt from it (older pages re-page in via Load earlier).
      // Invalidate work queued against the old snapshot before resetting
      // dedupe so stale decodes cannot append into the rebuilt store.
      state._revision++;
      state.messages.clear();
      state.seen.clear();
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
    _dmPollTimer?.cancel();
    _dmPollTimer = null;
    final events = _events;
    _events = null;
    if (events != null) unawaited(events.cancel());
    unawaited(_ws.disconnect());
  }

  /// Public extension seam for the DM part file (protected member).
  void notifyDmChanged() => notifyListeners();

  @override
  void dispose() {
    unawaited(_dmSubscription?.cancel());
    unawaited(close());
    super.dispose();
  }
}
