/// The upstream device-socket client of the machine connector (contract
/// `docs/fa_network_connector.md` §4): the hello handshake, reconnect
/// backoff, ping/pong liveness and the ack-after-write seam — over an
/// injectable [ConnectorTransport].
///
/// Rules encoded from §4 (plus the fa_network backend phase-A notes):
/// - dial `?ticket=<single-use, 60 s TTL>` minted by the injectable
///   [DeviceTicketProvider] (deviceToken-scoped);
/// - on open the client sends `hello` (deviceId + local roster digest,
///   deviceToken riding the payload) and waits for `hello_ok` referencing
///   the hello's `msgId`; the server then sends the roster snapshot (one
///   frame per user network) and redelivers unacked mail in seq order —
///   the client surfaces all of that on [inbound];
/// - reconnect backoff 1 s → 30 s ([upstreamBackoff]); resume by the same
///   (deviceId, deviceToken) pair;
/// - `ping`/`pong` every ~20 s ([upstreamPingInterval]) are APPLICATION
///   frames: the client NEVER uses socket read-timeouts to wait for quiet
///   (cancelling a read closes the connection — coder/websocket behavior
///   the backend agent field-tested); half-open drops are the server's job
///   at ~45 s;
/// - a second successful dial DISPLACES the first socket for the same
///   device server-side (the client treats any socket close the same way);
/// - `acknowledge` writes the ack frame only after the caller has written
///   the mailbox (connector's rule); while offline the ack is dropped and
///   the server's redelivery gives the connector another chance.
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'dart:async';

import 'envelope.dart';
import 'presence_engine.dart'
    show
        ConnectorClock,
        ConnectorTimer,
        ConnectorTimers,
        SystemClock,
        SystemTimers;

/// One live upstream connection (decoded envelopes both ways).
abstract interface class ConnectorSocket {
  /// Inbound frames. The stream completing (done or error) means the
  /// connection is gone — the client reconnects through its transport.
  /// Consumers MUST NOT gate reads on timeouts.
  Stream<NetworkEnvelope> get frames;

  /// Whether the connection can still carry outbound frames.
  bool get isOpen;

  /// Writes one envelope.
  Future<void> send(NetworkEnvelope envelope);

  /// Closes the connection; idempotent.
  Future<void> close();
}

/// Dials the device WS (`GET /ws?ticket=<...>`): the only network operation
/// of the pure core. Implementations throw when the server is unreachable
/// or rejects the upgrade; the client treats any throw as "not connected"
/// and retries with backoff.
abstract interface class ConnectorTransport {
  /// Opens one socket to [url] authorizing with [ticket]; throws when the
  /// endpoint refuses the upgrade (the client retries with backoff).
  Future<ConnectorSocket> dial(Uri url, String ticket);
}

/// Mints a single-use device WS ticket (TTL 60 s) — the injectable stand-in
/// for `POST /api/ws-ticket` authenticated with the deviceToken.
typedef DeviceTicketProvider = Future<String> Function();

/// Link state surfaced for hosts (honest, never a half-state).
enum ConnectorLinkState {
  /// Not connected (initial, after a drop, or after [ConnectorUpstreamClient.stop]).
  disconnected,

  /// A dial is in flight.
  connecting,

  /// Dialed; hello sent, waiting for hello_ok (+ roster snapshot).
  handshaking,

  /// Welcomed by the server; sends deliver live.
  connected,
}

/// Reconnect backoff (contract §4): 1 s doubling, capped at 30 s. The cap
/// also bounds the shift math: a server down for days must not overflow.
Duration upstreamBackoff(int attempt) {
  final clamped = attempt < 1 ? 1 : attempt;
  return Duration(seconds: 1 << (clamped - 1) > 30 ? 30 : 1 << (clamped - 1));
}

/// Thrown by [ConnectorUpstreamClient.send] while the link is not ready —
/// mail belongs in the offline outbox, not in a silently-dropped send.
final class ConnectorOfflineException implements Exception {
  const ConnectorOfflineException(this.message);

  /// Human-readable reason.
  final String message;

  @override
  String toString() => message;
}

/// The upstream client state machine: dial → hello → hello_ok (+ roster) →
/// connected, with 20 s application-level pings and 1 s → 30 s reconnect
/// backoff. Mail routing/dedup/ordering live in the mux and outbox layers.
final class ConnectorUpstreamClient {
  /// Builds a client for [url]. [ticketProvider] mints a fresh single-use
  /// ticket per dial; [deviceId]/[deviceToken] are the resume pair (§4);
  /// [rosterDigest] supplies the local roster digest for the hello (null
  /// allowed — fresh devices). [clock]/[timers] are the presence-engine
  /// seams (tests drive fake timers); [handshakeTimeout] bounds the wait
  /// for hello_ok (a completer timeout, never a socket read timeout).
  ConnectorUpstreamClient({
    required this.url,
    required ConnectorTransport transport,
    required this.ticketProvider,
    required this.deviceId,
    this.deviceToken,
    this.rosterDigest,
    this.backoff = upstreamBackoff,
    this.pingInterval = upstreamPingInterval,
    this.handshakeTimeout = const Duration(seconds: 10),
    ConnectorClock? clock,
    ConnectorTimers? timers,
    this.idFactory = defaultIdFactory,
    this.onLog,
  }) : _clock = clock ?? const SystemClock(),
       _timers = timers ?? const SystemTimers() {
    _transport = transport;
  }

  /// Liveness period (contract §4: ~20 s; the server drops half-open
  /// connections that stop answering).
  static const upstreamPingInterval = Duration(seconds: 20);

  /// The dial URL (`ws://host/ws`; the ticket is folded in per dial).
  final Uri url;
  late final ConnectorTransport _transport;
  final DeviceTicketProvider ticketProvider;

  /// Stable device id (§1) — the hello carries it.
  final String deviceId;

  /// Opaque bearer issued at enroll; resume credential (§4). Never logged.
  final String? deviceToken;

  /// Local roster digest provider for the hello payload.
  final String? Function()? rosterDigest;

  /// Reconnect backoff schedule (injectable: tests shrink it).
  final Duration Function(int attempt) backoff;

  /// Liveness ping period.
  final Duration pingInterval;

  /// How long the client waits for hello_ok before dropping the socket.
  final Duration handshakeTimeout;

  /// Frame id factory (injectable for tests).
  final IdFactory idFactory;

  /// Soft diagnostics sink (null = drop).
  void Function(String message)? onLog;

  final ConnectorClock _clock;
  final ConnectorTimers _timers;

  ConnectorLinkState _state = ConnectorLinkState.disconnected;
  final _stateChanges = StreamController<ConnectorLinkState>.broadcast();
  final _inbound = StreamController<NetworkEnvelope>.broadcast();
  StreamSubscription<NetworkEnvelope>? _framesSubscription;
  ConnectorSocket? _socket;
  ConnectorTimer? _pingTimer;
  ConnectorTimer? _reconnectTimer;
  ConnectorTimer? _handshakeTimer;
  Completer<NetworkEnvelope>? _helloWait;
  bool _running = false;
  int _attempt = 0;
  int _dialGeneration = 0;
  NetworkEnvelope? _lastRoster;

  /// The current link state.
  ConnectorLinkState get state => _state;

  /// Fires on every link-state transition.
  Stream<ConnectorLinkState> get stateChanges => _stateChanges.stream;

  /// True when the handshake completed — sends deliver live.
  bool get isReady => _state == ConnectorLinkState.connected;

  /// The reconnect attempt counter (test seam).
  int get attempts => _attempt;

  /// Every inbound frame — hello_ok, roster snapshots/patches, mail,
  /// presence, ack, wake_hint, pong — in arrival order. Control frames
  /// (hello_ok, ping) are handled internally AND surfaced here.
  Stream<NetworkEnvelope> get inbound => _inbound.stream;

  /// The most recent roster snapshot frame, or null before one arrives.
  NetworkEnvelope? get lastRoster => _lastRoster;

  /// Starts the connect loop. Idempotent.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _dial();
  }

  /// Clean stop: closes the socket, cancels every timer, disconnects. The
  /// server deregisters the machine immediately on a clean close (§5).
  /// Idempotent.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _dialGeneration++;
    _cancelTimers();
    _helloWait = null;
    await _teardownSocket();
    _transition(ConnectorLinkState.disconnected);
  }

  /// Writes [envelope] to the live socket. Throws
  /// [ConnectorOfflineException] when the link is not ready — callers
  /// (the composition root) queue mail in the offline outbox instead.
  Future<void> send(NetworkEnvelope envelope) async {
    final socket = _socket;
    if (!isReady || socket == null || !socket.isOpen) {
      throw ConnectorOfflineException(
        'upstream not ready (${_state.wireLabel}): '
        'queue in the offline outbox instead of sending',
      );
    }
    await socket.send(envelope);
  }

  /// Writes the ack frame for a DELIVERED inbound mail frame (refId =
  /// [msgId]) — the connector calls this only after the local sink write
  /// (§3 ack-after-write). While offline the ack is dropped: the server
  /// redelivers the mail after resume and the connector acks then.
  void acknowledge(String msgId) {
    if (!isReady) {
      onLog?.call('ack deferred while offline (server will redeliver): $msgId');
      return;
    }
    unawaited(
      send(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.ack,
          msgId: idFactory(),
          refId: msgId,
          ts: rfc3339Timestamp(_clock.now()),
        ),
      ).catchError((Object error) {
        onLog?.call('ack write failed (server will redeliver): $msgId');
      }),
    );
  }

  /// Closes the inbound/state streams (after [stop]).
  void dispose() {
    _stateChanges.close();
    _inbound.close();
  }

  void _dial() {
    if (!_running) return;
    _dialGeneration++;
    final generation = _dialGeneration;
    _transition(ConnectorLinkState.connecting);
    unawaited(() async {
      String ticket;
      try {
        ticket = await ticketProvider();
      } on Object catch (error) {
        onLog?.call('ticket provider failed: $error');
        _retry(generation);
        return;
      }
      ConnectorSocket socket;
      try {
        socket = await _transport.dial(
          url.replace(
            queryParameters: {...url.queryParameters, 'ticket': ticket},
          ),
          ticket,
        );
      } on Object catch (error) {
        onLog?.call('dial failed: $error');
        _retry(generation);
        return;
      }
      if (!_running || generation != _dialGeneration) {
        await socket.close();
        return;
      }
      _socket = socket;
      _framesSubscription = socket.frames.listen(
        _onFrame,
        onDone: () => _onSocketGone(generation, 'socket closed'),
        onError: (Object error) => _onSocketGone(generation, '$error'),
      );
      final hello = _buildHello();
      try {
        await _runHandshake(socket, hello, generation);
      } on Object {
        return;
      }
      _helloWait = null;
      _handshakeTimer?.cancel();
      _handshakeTimer = null;
      _attempt = 0;
      _pingTimer = _timers.periodic(pingInterval, () {
        final live = _socket;
        if (live == null || !isReady) return;
        unawaited(
          live
              .send(
                NetworkEnvelope(
                  kind: NetworkEnvelopeKind.ping,
                  msgId: idFactory(),
                  ts: rfc3339Timestamp(_clock.now()),
                ),
              )
              .catchError((Object error) {
                onLog?.call('ping write failed: $error');
              }),
        );
      });
      _transition(ConnectorLinkState.connected);
    }());
  }

  /// Builds the §4 hello envelope (deviceId + optional deviceToken +
  /// roster digest).
  NetworkEnvelope _buildHello() => NetworkEnvelope(
    kind: NetworkEnvelopeKind.hello,
    msgId: idFactory(),
    ts: rfc3339Timestamp(_clock.now()),
    payload: {
      'deviceId': deviceId,
      if (deviceToken != null) 'deviceToken': deviceToken,
      if (rosterDigest?.call() != null) 'rosterDigest': rosterDigest!(),
    },
  );

  /// Runs the hello → hello_ok handshake for [socket]; throws (and
  /// tears down + schedules a retry) on timeout, write failure, or a
  /// reply that is not hello_ok for our msgId.
  Future<void> _runHandshake(
    ConnectorSocket socket,
    NetworkEnvelope hello,
    int generation,
  ) async {
    _transition(ConnectorLinkState.handshaking);
    _helloWait = Completer<NetworkEnvelope>();
    _handshakeTimer = _timers.delayed(handshakeTimeout, () {
      final wait = _helloWait;
      if (wait != null && !wait.isCompleted) {
        wait.completeError(
          TimeoutException('no hello_ok within $handshakeTimeout'),
        );
      }
    });
    try {
      await socket.send(hello);
      final reply = await _helloWait!.future;
      if (reply.kind != NetworkEnvelopeKind.helloOk ||
          reply.refId != hello.msgId) {
        throw StateError(
          'unexpected handshake reply: ${reply.kind.wireName} '
          'refId=${reply.refId}',
        );
      }
    } on Object catch (error) {
      onLog?.call('handshake failed: $error');
      await _teardownSocket();
      _retry(generation);
      rethrow;
    }
  }

  void _onFrame(NetworkEnvelope envelope) {
    switch (envelope.kind) {
      case NetworkEnvelopeKind.helloOk:
        final wait = _helloWait;
        if (wait != null && !wait.isCompleted) wait.complete(envelope);
      case NetworkEnvelopeKind.ping:
        // Application-level liveness: answer immediately, no read timeouts.
        if (_socket != null) {
          unawaited(
            _socket!
                .send(
                  NetworkEnvelope(
                    kind: NetworkEnvelopeKind.pong,
                    msgId: idFactory(),
                    refId: envelope.msgId,
                    ts: rfc3339Timestamp(_clock.now()),
                  ),
                )
                .catchError((Object error) {
                  onLog?.call('pong write failed: $error');
                }),
          );
        }
      case NetworkEnvelopeKind.roster:
        _lastRoster = envelope;
      default:
        break;
    }
    _inbound.add(envelope);
  }

  void _onSocketGone(int generation, String reason) {
    final wasHandshaking = _helloWait != null;
    if (wasHandshaking) {
      final wait = _helloWait;
      if (wait != null && !wait.isCompleted) {
        wait.completeError(StateError(reason));
      }
      return; // the handshake failure path tears down + retries
    }
    if (generation != _dialGeneration) return;
    onLog?.call('link lost: $reason');
    unawaited(_teardownSocket());
    _retry(generation);
  }

  Future<void> _teardownSocket() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    await _framesSubscription?.cancel();
    _framesSubscription = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  void _retry(int generation) {
    _attempt++;
    _transition(ConnectorLinkState.disconnected);
    if (!_running) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = _timers.delayed(backoff(_attempt), () {
      _reconnectTimer = null;
      if (_running && generation == _dialGeneration) _dial();
    });
  }

  void _cancelTimers() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
  }

  void _transition(ConnectorLinkState next) {
    if (_state == next) return;
    _state = next;
    _stateChanges.add(next);
  }
}

extension on ConnectorLinkState {
  String get wireLabel => switch (this) {
    ConnectorLinkState.disconnected => 'disconnected',
    ConnectorLinkState.connecting => 'connecting',
    ConnectorLinkState.handshaking => 'handshaking',
    ConnectorLinkState.connected => 'connected',
  };
}
