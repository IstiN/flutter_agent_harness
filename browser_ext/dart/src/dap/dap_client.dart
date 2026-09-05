/// DAP/1 client transport for the browser: WebSocket via js_interop (the
/// extension SW has no dart:io), one connect cycle, E2E DM crypto over
/// fa_hub_client's pure functions, and backoff reconnects. Failures are
/// quiet by contract — nothing here throws into the host loop.
///
/// Cycle: connect → hello → welcome (agentId assigned) → auto-flush the
/// offline mailbox. Channels v1 is not implemented (the extension carries
/// no channel key store), so auto-join never fires.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:fa_hub_client/src/hub/canonical.dart';

import 'dap_frames.dart';

/// Connection phases surfaced as status events.
enum DapPhase { connecting, connected, reconnecting, disconnected }

/// One status snapshot (panel shows `hub: connected as <agentId>` etc.).
final class DapStatus {
  DapStatus({required this.phase, this.agentId, this.reason});

  final DapPhase phase;
  final String? agentId;
  final String? reason;

  Map<String, dynamic> toMap() => {
    'phase': phase.name,
    if (agentId != null) 'agentId': agentId,
    if (reason != null) 'reason': reason,
  };
}

// -- Browser WebSocket bindings (MV3 service worker global) ------------------

@JS('WebSocket')
extension type _WebSocket._(JSObject _) implements JSObject {
  external _WebSocket(String url);

  external void send(String data);

  external void close([int? code, String? reason]);

  /// `WebSocket.OPEN`.
  external int get readyState;

  external set onopen(JSFunction? f);

  external set onmessage(JSFunction? f);

  external set onclose(JSFunction? f);

  external set onerror(JSFunction? f);
}

@JS('MessageEvent')
extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

@JS('CloseEvent')
extension type _CloseEvent._(JSObject _) implements JSObject {
  external String get reason;
}

const _wsOpen = 1;
const _lookupTimeout = Duration(seconds: 10);

/// One live DAP/1 connection with reconnect. Create, then [start].
final class DapClient {
  DapClient({
    required this.identity,
    required this.url,
    required this.name,
    required this.onMail,
    required this.onStatus,
  });

  final DapIdentity identity;
  final String url;

  /// Display name advertised in the hello (cosmetic, unique per hub).
  final String name;

  /// Decrypted inbound mail (or the undecryptable placeholder — never
  /// dropped).
  final void Function(String from, String text) onMail;
  final void Function(DapStatus status) onStatus;

  _WebSocket? _ws;
  var _generation = 0;
  var _attempt = 0;
  var _stopped = false;
  var _fatal = false; // hub rejected the hello — stop retrying (§3.1)
  var _awaitingWelcome = false;
  String? agentId;
  DapPhase _phase = DapPhase.disconnected;
  String? _reason;
  Timer? _retry;

  /// Peer agentId → advertised x25519 key (whois/presence cache).
  final _peers = <String, String>{};
  final _whoisWaiters = <String, Completer<String?>>{};
  final _presenceWaiters = <String, Completer<List<Map<String, dynamic>>>>{};

  void start() {
    _stopped = false;
    _fatal = false;
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _generation++;
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    ws?.close();
    _set(DapPhase.disconnected, reason: 'stopped');
  }

  /// Sends an E2E DM. [to] is a 16-hex agent id or a unique online display
  /// name. Throws a descriptive error (the tool loop surfaces it); never
  /// throws for transport reasons — those stay quiet in the status.
  Future<String> sendDm(String to, String text) async {
    if (_phase != DapPhase.connected || _ws == null) {
      throw StateError('not connected to the hub');
    }
    final target = to.trim();
    final (peerId, peerX) = RegExp(r'^[0-9a-f]{16}$').hasMatch(target)
        ? await _byId(target)
        : await _byName(target);
    final frameId = newFrameId();
    final ciphertext = await encryptDm(identity, peerX, frameId, peerId, text);
    _send(
      jsonEncode(
        await sendFrame(
          from: identity,
          to: peerId,
          ciphertext: ciphertext,
          frameId: frameId,
        ),
      ),
    );
    return 'sent to $peerId';
  }

  /// Presence roster (every agent ever seen by the hub, self included).
  /// Empty list on timeout — presence is best-effort.
  Future<List<Map<String, dynamic>>> presence() async {
    if (_phase != DapPhase.connected || _ws == null) {
      throw StateError('not connected to the hub');
    }
    final frameId = newFrameId();
    final waiter = Completer<List<Map<String, dynamic>>>();
    _presenceWaiters[frameId] = waiter;
    _send(jsonEncode(presenceQueryFrame(frameId)));
    try {
      return await waiter.future.timeout(
        _lookupTimeout,
        onTimeout: () => const [],
      );
    } finally {
      _presenceWaiters.remove(frameId);
    }
  }

  Future<(String, String)> _byId(String agentId) async {
    final x = await _whoisKey(agentId);
    if (x == null) throw StateError('unknown agent $agentId on the hub');
    return (agentId, x);
  }

  Future<(String, String)> _byName(String name) async {
    final matches = <(String, String)>[
      for (final agent in await presence())
        if (agent['online'] == true && agent['name'] == name)
          (agent['agentId'] as String, agent['x25519'] as String? ?? ''),
    ];
    if (matches.isEmpty) {
      throw StateError(
        'no online agent named "$name" (dap_peers lists who is)',
      );
    }
    if (matches.length > 1) {
      throw StateError('"$name" is ambiguous — use the 16-hex id');
    }
    final (id, x) = matches.single;
    if (x.isEmpty) throw StateError('agent $id advertises no x25519 key');
    _peers[id] = x;
    return (id, x);
  }

  // -- Connection cycle -------------------------------------------------------

  void _connect() {
    if (_stopped || _fatal) return;
    final gen = ++_generation;
    final ws = _WebSocket(url);
    _ws = ws;
    _awaitingWelcome = true;
    if (_attempt == 0) _set(DapPhase.connecting);

    void onOpen() {
      if (gen == _generation) unawaited(_sendHello());
    }

    void onMessage(JSObject event) {
      if (gen == _generation) {
        unawaited(_handleRaw((event as _MessageEvent).data));
      }
    }

    void onClose(JSObject event) {
      if (gen != _generation || _stopped || _fatal) return;
      _ws = null;
      _awaitingWelcome = false;
      _attempt++;
      var reason = '';
      try {
        reason = (event as _CloseEvent).reason;
      } on Object {
        // Non-CloseEvent close — fall through with an empty reason.
      }
      _set(DapPhase.reconnecting, reason: reason);
      _retry?.cancel();
      _retry = Timer(reconnectBackoff(_attempt), _connect);
    }

    ws.onopen = onOpen.toJS;
    ws.onmessage = onMessage.toJS;
    ws.onclose = onClose.toJS;
    ws.onerror = (() {}).toJS; // close always follows; status covers it
  }

  Future<void> _sendHello() async {
    try {
      _send(
        jsonEncode(
          await helloFrame(identity, name: name.isEmpty ? null : name),
        ),
      );
    } on Object {
      // Signing should never fail; force the retry path regardless.
      _ws?.close();
    }
  }

  Future<void> _handleRaw(JSAny? data) async {
    try {
      final frame = (jsonDecode((data as JSString).toDart) as Map)
          .cast<String, dynamic>();
      await _onFrame(frame);
    } on Object {
      // Malformed frame — ignore; the connection stays up.
    }
  }

  Future<void> _onFrame(Map<String, dynamic> frame) async {
    switch (frame['op']) {
      case 'welcome':
        _awaitingWelcome = false;
        _attempt = 0;
        agentId = frame['agentId'] as String? ?? agentId;
        _set(DapPhase.connected);
        _send(jsonEncode(flushFrame())); // drain offline mail
      // No auto-join: channels v1 skipped (no channel key store here).
      case 'msg':
        await _onMsg(frame);
      case 'agent_info':
        final id = frame['agentId'] as String?;
        final x = frame['x25519'] as String?;
        if (id != null && x != null && x.isNotEmpty) _peers[id] = x;
        _whoisWaiters.remove(id)?.complete(x);
      case 'presence':
        final agents = [
          for (final entry in (frame['agents'] as List? ?? const []))
            (entry as Map).cast<String, dynamic>(),
        ];
        for (final agent in agents) {
          final id = agent['agentId'] as String?;
          final x = agent['x25519'] as String?;
          if (id != null && x != null && x.isNotEmpty) _peers[id] = x;
        }
        _presenceWaiters.remove(frame['replyTo'] as String?)?.complete(agents);
      case 'flushed':
        break; // delivered mail already arrived as msg frames
      case 'joined':
        break; // join ack — channels v1 not implemented
      case 'error':
        final code = frame['code'] as String? ?? 'error';
        if (_awaitingWelcome) {
          // Rejected hello is fatal (§3.1): surface it and stop retrying.
          _fatal = true;
          _generation++;
          _ws?.close();
          _ws = null;
          _retry?.cancel();
          _set(DapPhase.disconnected, reason: 'hub rejected hello: $code');
        } else {
          // Hub errors carry no target id — fail every pending peer lookup
          // so sendDm reports instead of hanging to the timeout.
          for (final waiter in _whoisWaiters.values) {
            if (!waiter.isCompleted) waiter.complete(null);
          }
          _whoisWaiters.clear();
        }
      default:
        break;
    }
  }

  Future<void> _onMsg(Map<String, dynamic> frame) async {
    final from = frame['from'] as String? ?? 'unknown';
    if (frame['channel'] != null) return; // channels v1: not implemented
    String? text;
    try {
      final senderX = await _whoisKey(from);
      if (senderX != null) {
        text = await decryptDm(
          identity,
          senderX,
          frame['id'] as String? ?? '',
          frame['ciphertext'] as String? ?? '',
        );
      }
    } on Object {
      text = null; // wrong key, tampered box, missing fields
    }
    onMail(from, text ?? undecryptableText(from));
  }

  Future<String?> _whoisKey(String agentId) {
    final cached = _peers[agentId];
    if (cached != null) return Future.value(cached);
    final waiter = Completer<String?>();
    _whoisWaiters[agentId] = waiter;
    _send(jsonEncode(whoisFrame(agentId)));
    return waiter.future
        .timeout(_lookupTimeout, onTimeout: () => null)
        .whenComplete(() {
          if (identical(_whoisWaiters[agentId], waiter)) {
            _whoisWaiters.remove(agentId);
          }
        });
  }

  void _send(String text) {
    final ws = _ws;
    if (ws != null && ws.readyState == _wsOpen) ws.send(text);
  }

  void _set(DapPhase phase, {String? reason}) {
    if (phase == _phase && reason == _reason) return;
    _phase = phase;
    _reason = reason;
    onStatus(DapStatus(phase: phase, agentId: agentId, reason: reason));
  }
}
