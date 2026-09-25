// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

// ignore: depend_on_referenced_packages
import 'package:stream_channel/stream_channel.dart';
// ignore: depend_on_referenced_packages
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

/// Events pushed on [FaNetworkWs.events]. Parsed server→client frames.
sealed class WsEvent {
  const WsEvent();
}

/// `roster.snapshot` — full roster on connect and on roster change.
final class RosterSnapshot extends WsEvent {
  const RosterSnapshot(this.members);

  final List<Member> members;
}

/// `envelope` — a relayed channel envelope (opaque ciphertext).
final class EnvelopeReceived extends WsEvent {
  const EnvelopeReceived(this.envelope);

  final Envelope envelope;
}

/// `presence.changed` — one member's presence flipped.
final class PresenceChanged extends WsEvent {
  const PresenceChanged(this.memberId, this.presence);

  final String memberId;
  final Presence presence;
}

/// `network.offline` — the dap hub is unreachable; the server queues
/// outbound envelopes until it drains.
final class NetworkOffline extends WsEvent {
  const NetworkOffline(this.reason);

  final String reason;
}

/// `network.drain` — the hub is back; the server is replaying the queue.
final class NetworkDrain extends WsEvent {
  const NetworkDrain(this.count);

  final int count;
}

/// `wakeup.dispatched` — an offline agent was woken (owners/admins only).
final class WakeupDispatched extends WsEvent {
  const WakeupDispatched(this.agentId, this.at);

  final String agentId;
  final DateTime? at;
}

/// A malformed inbound frame or a server `error` frame. Never thrown.
final class WsError extends WsEvent {
  const WsError(this.message);

  final String message;
}

/// Abstraction over the platform WebSocket so tests (and platforms with
/// special header needs) can inject their own transport.
abstract interface class WsConnector {
  Future<StreamChannel<String>> connect(Uri wsUri, Map<String, String> headers);
}

/// Default connector backed by `package:web_socket_channel` (web-safe).
///
/// NOTE: the browser WebSocket API cannot set arbitrary headers, so this
/// connector cannot attach the `Authorization` header from [connect] on
/// web. Deployments that need header auth must provide a custom
/// [WsConnector].
class WebSocketChannelConnector implements WsConnector {
  const WebSocketChannelConnector();

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    final channel = WebSocketChannel.connect(wsUri);
    return StreamChannel<String>(
      channel.stream.cast<String>(),
      _StringSink(channel.sink),
    );
  }
}

/// Narrows a dynamic WebSocket sink to a `StreamSink<String>`.
class _StringSink implements StreamSink<String> {
  _StringSink(this._inner);

  final WebSocketSink _inner;

  @override
  void add(String event) => _inner.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<String> stream) => _inner.addStream(stream);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

/// Realtime fa_network session over `/ws` (fa_network/docs/openapi.yaml).
///
/// - Reconnects with capped exponential backoff + jitter after the server
///   drops the socket (never after a manual [disconnect]).
/// - Resubscribes previously subscribed channels after each reconnect.
/// - Outbound frames sent while disconnected are queued in memory and
///   flushed once, in order, on the next successful connect.
/// - Sends a `ping` every [heartbeat] (30s by default).
/// - Malformed frames surface as [WsError] events; the stream never throws.
class FaNetworkWs {
  FaNetworkWs({
    required this.baseUrl,
    required this.connector,
    required this.sessionToken,
    this.heartbeat = const Duration(seconds: 30),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    Random? random,
  }) : _random = random ?? Random();

  /// REST base (`http(s)`); the socket URL is derived by swapping the
  /// scheme to `ws(s)` and appending `/ws`.
  final Uri baseUrl;

  /// Transport used to open the socket.
  final WsConnector connector;

  /// Supplies the current fa_network session token (read on each connect).
  final String Function() sessionToken;

  /// Heartbeat interval for the client→server `ping`.
  final Duration heartbeat;

  /// Reconnect backoff: first delay; doubled per attempt up to [maxBackoff]
  /// (plus up to 500ms jitter).
  final Duration initialBackoff;

  /// See [initialBackoff].
  final Duration maxBackoff;

  final Random _random;

  final StreamController<WsEvent> _events =
      StreamController<WsEvent>.broadcast();

  StreamChannel<String>? _channel;
  StreamSubscription<String>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  final Set<String> _subscriptions = {};
  final List<String> _outbox = [];

  bool _connected = false;
  bool _connecting = false;
  bool _manualClose = false;
  int _attempts = 0;

  /// Parsed server→client events.
  Stream<WsEvent> get events => _events.stream;

  /// Whether a live socket is attached right now.
  bool get isConnected => _connected;

  /// The `ws(s)` URL derived from [baseUrl].
  Uri get wsUri {
    final scheme = baseUrl.scheme == 'https' ? 'wss' : 'ws';
    var path = baseUrl.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    return Uri(
      scheme: scheme,
      userInfo: baseUrl.userInfo.isEmpty ? null : baseUrl.userInfo,
      host: baseUrl.host.isEmpty ? null : baseUrl.host,
      port: baseUrl.hasPort ? baseUrl.port : null,
      path: '$path/ws',
    );
  }

  /// Opens the socket. Safe to call again after [disconnect].
  Future<void> connect() async {
    _manualClose = false;
    await _open();
  }

  /// Queues (or sends) an `envelope.send` frame.
  void sendEnvelope({
    required String channelId,
    required String id,
    required String payload,
    List<String>? mentions,
    String? senderKey,
  }) {
    final frame = <String, Object?>{
      'type': 'envelope.send',
      'channelId': channelId,
      'id': id,
      'payload': payload,
      '''mentions''': ?mentions,
      '''senderKey''': ?senderKey,
    };
    if (_connected) {
      _sendNow(frame);
    } else {
      _outbox.add(jsonEncode(frame));
    }
  }

  /// Subscribes to a channel. Persisted across reconnects.
  void subscribe(String channelId) {
    if (!_subscriptions.add(channelId)) return;
    if (_connected) {
      _sendNow({'type': 'subscribe', 'channelId': channelId});
    }
  }

  /// Unsubscribes from a channel.
  void unsubscribe(String channelId) {
    _subscriptions.remove(channelId);
    if (_connected) {
      _sendNow({'type': 'unsubscribe', 'channelId': channelId});
    }
  }

  /// Closes the socket and stops reconnecting until [connect] is called.
  /// Queued outbound frames and channel subscriptions are kept.
  Future<void> disconnect() async {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _connected = false;
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }

  /// [disconnect] plus closes the [events] stream.
  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }

  // ------------------------------------------------------------------ open

  Future<void> _open() async {
    if (_connected || _connecting || _manualClose || _events.isClosed) return;
    _connecting = true;
    final StreamChannel<String> channel;
    try {
      channel = await connector.connect(wsUri, {
        'Authorization': 'Bearer ${sessionToken()}',
      });
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
      return;
    }
    _connecting = false;
    if (_manualClose || _events.isClosed) {
      await channel.sink.close();
      return;
    }
    _channel = channel;
    _connected = true;
    _attempts = 0;
    _subscription = channel.stream.listen(
      _onFrame,
      onError: _onChannelError,
      onDone: _onChannelClosed,
    );
    _startHeartbeat();
    // Resubscribe first so flushed envelopes have a destination.
    for (final channelId in _subscriptions) {
      _sendNow({'type': 'subscribe', 'channelId': channelId});
    }
    _flushOutbox();
  }

  void _scheduleReconnect() {
    if (_manualClose || _events.isClosed) return;
    _reconnectTimer?.cancel();
    final exp = initialBackoff.inMilliseconds * pow(2, _attempts);
    final capped = min(exp.toInt(), maxBackoff.inMilliseconds);
    final jitterMs = _random.nextInt(500);
    _attempts++;
    _reconnectTimer = Timer(Duration(milliseconds: capped + jitterMs), () {
      _reconnectTimer = null;
      unawaited(_open());
    });
  }

  // ---------------------------------------------------------------- frames

  void _onFrame(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      _emit(const WsError('malformed frame: not JSON'));
      return;
    }
    if (decoded is! Map) {
      _emit(const WsError('malformed frame: not an object'));
      return;
    }
    try {
      switch (decoded['type']) {
        case 'roster.snapshot':
          final payload = decoded['payload'];
          final members = payload is List
              ? payload
                    .whereType<Map>()
                    .map((m) => Member.fromJson(m.cast<String, Object?>()))
                    .toList()
              : <Member>[];
          _emit(RosterSnapshot(members));
        case 'envelope':
          final payload = decoded['payload'];
          if (payload is Map) {
            _emit(
              EnvelopeReceived(
                Envelope.fromJson(payload.cast<String, Object?>()),
              ),
            );
          }
        case 'presence.changed':
          final payload = decoded['payload'];
          if (payload is Map) {
            _emit(
              PresenceChanged(
                payload['memberId']?.toString() ?? '',
                Presence.parse(payload['presence']),
              ),
            );
          }
        case 'network.offline':
          final payload = decoded['payload'];
          _emit(
            NetworkOffline(
              payload is Map ? payload['reason']?.toString() ?? '' : '',
            ),
          );
        case 'network.drain':
          final payload = decoded['payload'];
          final count = payload is Map ? payload['count'] : null;
          _emit(NetworkDrain(count is int ? count : 0));
        case 'wakeup.dispatched':
          final payload = decoded['payload'];
          if (payload is Map) {
            final at = payload['at'];
            _emit(
              WakeupDispatched(
                payload['agentId']?.toString() ?? '',
                at is String ? DateTime.tryParse(at) : null,
              ),
            );
          }
        case 'pong':
          break; // heartbeat ack
        case 'error':
          final payload = decoded['payload'];
          final message = payload is Map
              ? payload['message']?.toString()
              : null;
          _emit(WsError(message ?? decoded['message']?.toString() ?? 'error'));
        default:
          break; // forward-compatible: ignore unknown frame types
      }
    } catch (e) {
      _emit(WsError('malformed frame: $e'));
    }
  }

  void _onChannelError(Object error) => _handleClosed();

  void _onChannelClosed() => _handleClosed();

  void _handleClosed() {
    if (!_connected) return;
    _connected = false;
    _channel = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!_manualClose) _scheduleReconnect();
  }

  // -------------------------------------------------------------- outbound

  void _sendNow(Map<String, Object?> frame) {
    try {
      _channel?.sink.add(jsonEncode(frame));
    } catch (_) {
      // The socket died mid-write; the reconnect path re-establishes and
      // the caller's envelopes are idempotent (dedup by id).
    }
  }

  void _flushOutbox() {
    if (_outbox.isEmpty) return;
    final queued = List<String>.of(_outbox);
    _outbox.clear();
    final channel = _channel;
    if (channel == null) {
      _outbox.insertAll(0, queued);
      return;
    }
    for (final frame in queued) {
      try {
        channel.sink.add(frame);
      } catch (_) {
        _outbox.add(frame);
      }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      if (_connected) _sendNow(const {'type': 'ping'});
    });
  }

  void _emit(WsEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
