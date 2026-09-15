/// The hub as the messaging fabric's primary transport (issue #402, GOAL
/// card #27 phase 27.1): a pure-Dart [MessagingRepository] over the DAP/1
/// hub protocol, with the transport injected ([HubTransport] — `lib/io.dart`
/// supplies the `dart:io` WebSocket binding, tests inject fakes).
///
/// Semantics per the phase 27.1 contract:
/// * presence/registration ride the signed hello (`register` publishes the
///   session display name + capabilities, applied on the next hello);
/// * `send` is E2E-encrypted per docs/protocol.md (whois resolves the peer
///   DH key first) and QUEUES while the link is down — on reconnect the
///   queue drains in send order, each message keeping its id so recipients
///   dedupe (at-least-once, dedup by id, per-sender ordering);
/// * inbound frames land in our one hub inbox (keyed by the hub agent id —
///   `peek`/`drain` ignore the fabric agentId, the composition guards that
///   only the wired `primaryMailbox` reaches here);
/// * reconnects are invisible to callers: exponential backoff (1 s → 30 s,
///   reset on welcome), offline mailbox flush after every welcome, `busy`
///   run-state stays local (steering semantics — mail is accepted while a
///   turn streams, never "offline" on the connection level).
library;

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'agent_message.dart';
import 'fallback_messaging_repository.dart';
import 'hub_crypto.dart';
import 'hub_identity.dart';
import 'hub_transport.dart';
import 'messaging_repository.dart';

/// The link state surfaced for host UI (the app's "Agent network" row):
/// honest connection status, never a silent half-state.
enum HubLinkState {
  /// Not connected (initial, after a drop, or after
  /// [HubMessagingRepository.stop]).
  disconnected,

  /// A dial or the post-dial handshake is in flight.
  connecting,

  /// Welcomed by the hub; sends deliver live.
  connected,
}

/// Exponential reconnect backoff: 1 s doubling, capped at 30 s (spec
/// "Client reconnect"). The cap also guards the attempt counter: a hub
/// down for days must not shift a timer by years.
Duration defaultHubBackoff(int attempt) {
  final clamped = attempt.clamp(1, 5);
  return Duration(seconds: 1 << (clamped - 1));
}

/// One roster entry from a presence query or whois.
final class HubPeer {
  const HubPeer({required this.agentId, this.name, this.online = false});

  final String agentId;
  final String? name;
  final bool online;
}

/// Inbound frame-id dedup window: at-least-once delivery means a hub (or a
/// reconnect race) can hand us the same frame twice; this ring remembers
/// the recent ids so a redelivery collapses. Bounded — identities live on
/// the agents, and old ids never legitimately repeat.
const _seenFrameIdsCap = 4096;

/// Per-request cap for whois/presence/welcome waits: a hub that never
/// answers must fail the request (which then falls back or retries), not
/// hang the caller.
const _replyTimeout = Duration(seconds: 10);

/// The DAP/1 hub as a [MessagingRepository].
final class HubMessagingRepository
    implements MessagingRepository, RoutingMessagingRepository {
  /// Builds a repository for the hub at [url]. [identity] defaults to a
  /// fresh one — hosts that need a stable address persist the seeds and
  /// pass them back (see `lib/io.dart`). [token] is the pairing token for
  /// a protected hub (rides the upgrade as `?dap_token=`, the browser-safe
  /// form). [onLog] receives soft diagnostics (decrypt failures, protocol
  /// errors) — never required.
  HubMessagingRepository({
    required Uri url,
    // ignore: prefer_initializing_formals
    required HubTransport transport,
    HubIdentity? identity,
    this.name,
    this.token,
    this.backoff = defaultHubBackoff,
    this.onLog,
  }) : _dialUrl = url,
       // ignore: prefer_initializing_formals
       _transport = transport,
       _identityFuture = identity == null
           ? HubIdentity.generate()
           : Future.value(identity);

  /// The dial URL (tokenless; the pairing token is folded in per dial).
  final Uri _dialUrl;
  final HubTransport _transport;
  final Future<HubIdentity> _identityFuture;

  /// The roster display name published by the signed hello — the session
  /// name (register refreshes it).
  String? name;

  /// The pairing token for a protected hub (write-only: never echoed).
  final String? token;

  /// Reconnect backoff schedule (injectable: tests shrink it).
  final Duration Function(int attempt) backoff;

  /// Soft diagnostics sink (null = drop).
  void Function(String message)? onLog;

  HubIdentity? _identity;
  HubSocket? _socket;
  StreamSubscription<String>? _inbound;
  Timer? _reconnectTimer;
  bool _started = false;
  bool _disposed = false;
  int _attempt = 0;
  Completer<void>? _welcome;
  HubLinkState _state = HubLinkState.disconnected;
  final _stateChanges = StreamController<HubLinkState>.broadcast();

  /// Our hub address (the identity-derived id), set after the first
  /// welcome. Null until then.
  String? get agentId => _identity?.agentId;

  @override
  bool get isConnected => _state == HubLinkState.connected;

  /// The current link state (UI surface).
  HubLinkState get state => _state;

  /// Fires on every link-state transition.
  Stream<HubLinkState> get stateChanges => _stateChanges.stream;

  /// The capabilities announced by [register] (surfaced on our own
  /// directory entry until the hub wire carries them for peers).
  List<AgentCapability> capabilities = const [];

  /// True while the owner reported a run in progress ([touch]) — local
  /// presence knowledge; mail is accepted either way (steering semantics).
  bool busy = false;

  /// Our inbox: inbound DMs in arrival order.
  final _inbox = <AgentMessage>[];

  /// Recent inbound frame ids (dedup ring).
  final _seenFrameIds = <String>[];

  /// Messages queued while the link is down; drained in order on reconnect.
  final _outbound = <AgentMessage>[];

  /// Whois roster cache (agentId → peer), cleared on reconnect.
  final _whoisCache = <String, HubPeer>{};

  /// The roster as of the last successful presence query (the
  /// disconnected-directory view; null before the first contact).
  List<HubPeer>? _lastRoster;

  /// agentId → X25519 pubkey (b64) learned from whois answers.
  final _dhKeys = <String, String>{};

  final _pendingWhois = <String, List<Completer<HubPeer>>>{};
  final _pendingPresence = <String, Completer<List<HubPeer>>>{};

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Starts the connect loop: dials, handshakes, reconnects with backoff.
  /// Idempotent.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _identity = await _identityFuture;
    _dial();
  }

  /// Stops the loop and closes the socket cleanly (the iOS background
  /// path: suspend → stop, foreground → start — reconnect + flush).
  Future<void> stop() async {
    _started = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _dropSocket();
    _setState(HubLinkState.disconnected);
  }

  /// Permanent shutdown (the host is going away).
  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _stateChanges.close();
  }

  void _log(String message) => onLog?.call(message);

  void _setState(HubLinkState next) {
    if (_disposed || _state == next) return;
    _state = next;
    if (!_stateChanges.isClosed) _stateChanges.add(next);
  }

  void _dial() {
    if (!_started || _disposed) return;
    _setState(HubLinkState.connecting);
    unawaited(_dialOnce());
  }

  Future<void> _dialOnce() async {
    if (!_started || _disposed) return;
    final query = _dialUrl.queryParameters;
    final url = token == null || token!.isEmpty
        ? _dialUrl
        : _dialUrl.replace(queryParameters: {...query, 'dap_token': token});
    final HubSocket socket;
    try {
      socket = await _transport.connect(url);
    } on Object catch (error) {
      _log('hub connect failed: $error');
      _scheduleReconnect();
      return;
    }
    _socket = socket;
    _whoisCache.clear();
    _dhKeys.clear();
    _inbound = socket.messages.cast<String>().listen(
      _onFrame,
      onDone: _onLinkDown,
      onError: (Object _) => _onLinkDown,
      cancelOnError: true,
    );
    final welcomed = _welcome = Completer<void>();
    try {
      await _sendHello();
      await welcomed.future.timeout(_replyTimeout);
    } on Object catch (error) {
      _log('hub handshake failed: $error');
      await _dropSocket();
      _scheduleReconnect();
      return;
    }
    // Welcomed: live. Reset the backoff and drain the offline mailbox plus
    // everything queued while the link was down.
    _attempt = 0;
    _setState(HubLinkState.connected);
    unawaited(_sendNow({'op': 'flush'}).catchError((Object _) {}));
    await _drainOutbound();
  }

  Future<void> _sendHello() async {
    final identity = _identity;
    if (identity == null) throw StateError('identity not loaded');
    final frame = <String, dynamic>{
      'op': 'hello',
      'pubkey': identity.signingPubkeyB64,
      'x25519': identity.dhPubkeyB64,
      if (name != null && name!.isNotEmpty) 'name': name,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'nonce': hubRandomHex(24),
    };
    frame['sig'] = await hubSignFrame(frame, identity);
    await _sendNow(frame);
  }

  void _scheduleReconnect() {
    if (!_started || _disposed) return;
    _setState(HubLinkState.disconnected);
    _attempt += 1;
    _reconnectTimer?.cancel();
    // A zero backoff between dial failures would spin a tight loop on a
    // refused port — floor the schedule at one tick.
    final delay = backoff(_attempt);
    _reconnectTimer = Timer(
      delay == Duration.zero ? const Duration(milliseconds: 1) : delay,
      _dial,
    );
  }

  Future<void> _dropSocket() async {
    _inbound?.cancel();
    _inbound = null;
    final socket = _socket;
    _socket = null;
    _failWaiters('hub link down');
    try {
      await socket?.close();
    } on Object {
      // Already gone.
    }
  }

  void _onLinkDown() {
    _inbound = null;
    _socket = null;
    _failWaiters('hub link down');
    _scheduleReconnect();
  }

  void _failWaiters(String error) {
    for (final waiters in _pendingWhois.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.completeError(StateError(error));
      }
    }
    _pendingWhois.clear();
    for (final waiter in _pendingPresence.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError(error));
    }
    _pendingPresence.clear();
    final welcome = _welcome;
    if (welcome != null && !welcome.isCompleted) {
      welcome.completeError(StateError(error));
    }
    _welcome = null;
  }

  // ---------------------------------------------------------------------------
  // Inbound frames
  // ---------------------------------------------------------------------------

  void _onFrame(String text) {
    Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(text) as Map).cast<String, dynamic>();
    } on Object {
      _log('hub sent a non-JSON frame');
      return;
    }
    switch (frame['op'] as String?) {
      case 'welcome':
        final welcome = _welcome;
        if (welcome != null && !welcome.isCompleted) {
          welcome.complete();
          _welcome = null;
        }
      case 'msg':
        unawaited(_onMsg(frame));
      case 'agent_info':
        _onAgentInfo(frame);
      case 'presence':
        _onPresence(frame);
      case 'flushed':
        break; // queued mail already arrived as msg frames
      case 'error':
        _log('hub error: ${frame['code']} ${frame['msg']}');
      default:
        break;
    }
  }

  Future<void> _onMsg(Map<String, dynamic> frame) async {
    final id = frame['id'] as String? ?? '';
    if (id.isEmpty || _identity == null) return;
    if (_seenFrameIds.contains(id)) return; // dedup by id (at-least-once)
    _seenFrameIds.add(id);
    if (_seenFrameIds.length > _seenFrameIdsCap) _seenFrameIds.removeAt(0);
    final from = frame['from'] as String? ?? '';
    String text;
    try {
      var dhB64 = _dhKeys[from];
      if (dhB64 == null) {
        // The sender's DH key arrives with whois; resolve, then decrypt.
        await _whois(from);
        dhB64 = _dhKeys[from];
      }
      if (dhB64 == null) throw StateError('no DH key for $from');
      text = await hubDecryptPayload(
        ourIdentity: _identity!,
        senderDhPubkey: SimplePublicKey(
          base64Decode(dhB64),
          type: KeyPairType.x25519,
        ),
        frameId: id,
        ciphertextB64: frame['ciphertext'] as String? ?? '',
      );
    } on Object catch (error) {
      // Undecryptable (unknown sender key, tampered payload): never deliver
      // opaque ciphertext into the chat — drop with a diagnostic.
      _log('dropped undecryptable DM from $from: $error');
      return;
    }
    _inbox.add(
      AgentMessage(
        id: id,
        fromId: from,
        toId: agentId ?? '',
        text: text,
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          frame['ts'] as int? ?? 0,
        ).toUtc().toIso8601String(),
      ),
    );
  }

  void _onAgentInfo(Map<String, dynamic> frame) {
    final agentId = frame['agentId'] as String? ?? '';
    final peer = HubPeer(
      agentId: agentId,
      name: frame['name'] as String?,
      online: frame['online'] as bool? ?? false,
    );
    _whoisCache[agentId] = peer;
    final dh = frame['x25519'] as String?;
    if (dh != null && dh.isNotEmpty) _dhKeys[agentId] = dh;
    final waiters = _pendingWhois.remove(agentId);
    if (waiters == null) return;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(peer);
    }
  }

  void _onPresence(Map<String, dynamic> frame) {
    final replyTo = frame['replyTo'] as String?;
    final agents = [
      for (final entry in (frame['agents'] as List? ?? const []))
        if (entry is Map)
          HubPeer(
            agentId: entry['agentId'] as String? ?? '',
            name: entry['name'] as String?,
            online: entry['online'] as bool? ?? false,
          ),
    ];
    if (replyTo != null) {
      final waiter = _pendingPresence.remove(replyTo);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(agents);
        return;
      }
    }
    // Legacy hub (no replyTo echo): complete the oldest waiter.
    if (_pendingPresence.isNotEmpty) {
      final waiter = _pendingPresence.remove(_pendingPresence.keys.first)!;
      if (!waiter.isCompleted) waiter.complete(agents);
    }
  }

  /// Whois with caching — the spec-required lookup before a DM.
  Future<HubPeer> _whois(String agentId) async {
    if (agentId.isEmpty) throw ArgumentError('whois needs an agent id');
    final cached = _whoisCache[agentId];
    if (cached != null) return cached;
    final waiter = Completer<HubPeer>();
    _pendingWhois.putIfAbsent(agentId, () => []).add(waiter);
    await _sendNow({'op': 'whois', 'agentId': agentId});
    final peer = await waiter.future.timeout(_replyTimeout);
    _whoisCache[agentId] = peer;
    return peer;
  }

  Future<List<HubPeer>> _presenceQuery() async {
    if (!isConnected) throw StateError('hub link is not connected');
    final id = newHubFrameId();
    final waiter = Completer<List<HubPeer>>();
    _pendingPresence[id] = waiter;
    await _sendNow({'op': 'presence_query', 'id': id});
    try {
      return await waiter.future.timeout(_replyTimeout);
    } on Object {
      _pendingPresence.remove(id);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // RoutingMessagingRepository
  // ---------------------------------------------------------------------------

  @override
  Future<String?> resolveTarget(String toId) async {
    if (!isConnected) return null;
    // Channels are not part of this repository's surface (the CLI's
    // package-backed repo owns them): report "not mine" honestly.
    if (toId.startsWith('#')) return null;
    final me = agentId;
    if (me != null && toId == me) return null; // our own fabric mailbox
    final roster = await _presenceQuery();
    for (final peer in roster) {
      if (peer.agentId == toId) return toId; // exact id wins
    }
    final byName = roster
        .where((peer) => peer.name == toId && peer.agentId != me)
        .toList();
    // A display name resolves only when it is unambiguous — matches the
    // dap_dm resolver; anything else falls through to the file fabric.
    return byName.length == 1 ? byName.single.agentId : null;
  }

  // ---------------------------------------------------------------------------
  // MessagingRepository
  // ---------------------------------------------------------------------------

  @override
  Future<void> send(AgentMessage message) async {
    if (!isConnected) {
      // Queue-while-disconnected: the message keeps its id and position;
      // the reconnect drain preserves per-sender order.
      _outbound.add(message);
      return;
    }
    // A mid-flight failure (whois race, evicted socket) rethrows: the
    // composition falls back to the file fabric and tracks the message for
    // forward-on-reconnect; a standalone caller sees the throw (the
    // contract: never lose mail silently).
    await _sendLive(message);
  }

  Future<void> _sendLive(AgentMessage message) async {
    final identity = _identity;
    if (identity == null) throw StateError('hub fabric not welcomed yet');
    final to = message.toId;
    var dhB64 = _dhKeys[to];
    if (dhB64 == null) {
      // Spec: whois before the first DM.
      await _whois(to);
      dhB64 = _dhKeys[to];
    }
    if (dhB64 == null) {
      throw StateError('hub returned no x25519 pubkey for "$to"');
    }
    final id = message.id.isEmpty ? newHubFrameId() : message.id;
    final ciphertext = await hubEncryptPayload(
      sender: identity,
      recipientDhPubkey: SimplePublicKey(
        base64Decode(dhB64),
        type: KeyPairType.x25519,
      ),
      frameId: id,
      aadTarget: to,
      plaintext: message.text,
    );
    final frame = <String, dynamic>{
      'op': 'send',
      'to': to,
      'id': id,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'ciphertext': ciphertext,
    };
    frame['sig'] = await hubSignFrame(frame, identity);
    await _sendNow(frame);
  }

  /// Drains the offline queue in order after a welcome. A mid-drain failure
  /// keeps the remainder queued (front of the queue, order intact) for the
  /// next reconnect cycle.
  Future<void> _drainOutbound() async {
    while (_outbound.isNotEmpty && isConnected) {
      final message = _outbound.first;
      try {
        await _sendLive(message);
        _outbound.removeAt(0);
      } on Object {
        _log('outbound drain deferred (${_outbound.length} queued)');
        return;
      }
    }
  }

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {
    if (sessionName != null && sessionName.isNotEmpty) name = sessionName;
    this.capabilities = capabilities;
    // Presence rides the signed hello; a live name change re-announces on
    // the spot (best-effort — a failed announce never breaks startup).
    if (isConnected) {
      try {
        await _sendHello();
      } on Object catch (error) {
        _log('hello re-announce failed: $error');
      }
    }
  }

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {
    // Hub liveness is the connection itself; the busy run-state is local
    // knowledge (surfaced on our own directory entry) until the hub wire
    // carries presence states (phase 27.2).
    this.busy = busy;
  }

  @override
  Future<List<AgentMessage>> peek(String agent) =>
      Future.value(List.of(_inbox));

  @override
  Future<List<AgentMessage>> drain(String agent) async {
    final drained = List.of(_inbox);
    _inbox.clear();
    return drained;
  }

  @override
  Future<List<MailboxEntry>> directory() async {
    final me = agentId;
    List<HubPeer> roster;
    try {
      roster = await _presenceQuery();
      _lastRoster = roster;
    } on Object {
      // Link down: the roster as of last contact, everyone offline — the
      // honest disconnected view (a UI shows the network unreachable, not
      // a stale guess at who is live). Never connected → nothing to show.
      final last = _lastRoster;
      if (last == null) rethrow;
      roster = [
        for (final peer in last)
          HubPeer(agentId: peer.agentId, name: peer.name, online: false),
      ];
    }
    return [
      for (final peer in roster)
        MailboxEntry(
          id: peer.agentId,
          name: peer.name,
          // Registration-backed presence: the hub knows who is connected —
          // no mtime heuristic. Our own busy run-state rides on top.
          presence: peer.agentId == me && busy
              ? AgentPresence.busy
              : peer.online
              ? AgentPresence.live
              : AgentPresence.offline,
          capabilities: peer.agentId == me ? capabilities : const [],
          source: mailboxSourceHub,
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Wire
  // ---------------------------------------------------------------------------

  Future<void> _sendNow(Map<String, dynamic> frame) async {
    final socket = _socket;
    if (socket == null || !socket.isOpen) {
      throw StateError('hub link is not open');
    }
    await socket.send(jsonEncode(frame));
  }
}
