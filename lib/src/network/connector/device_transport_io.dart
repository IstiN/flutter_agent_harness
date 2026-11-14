// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The `dart:io` device transport + enrollment of the machine connector
/// (contract `docs/fa_network_connector.md` §4/§9): the real upstream WS
/// dial ([IoConnectorTransport] over `dart:io`'s `WebSocket.connect`) and
/// the device REST calls ([DeviceEnrollmentClient]):
/// - `POST /api/devices/enroll` (JWT bearer) → `{deviceId, deviceToken}` —
///   the stable §1 identity pair persisted by the host;
/// - `POST /api/ws-ticket` (deviceToken bearer) → a single-use ticket,
///   TTL 60 s, one dial each (§4);
/// - `PATCH /api/devices/{deviceId}/roster` (deviceToken bearer) → the
///   agent/session exposure projection visible to other devices.
///
/// The socket adapter ([ConnectorSocketAdapter]) mirrors the fake-device-
/// server client-socket semantics: writes after close throw, close is
/// idempotent, and the frames stream completes when the peer goes away —
/// the upstream client treats any of that as "link gone" and reconnects.
/// Malformed inbound text (one corrupt frame) is skipped with a
/// diagnostic instead of tearing the link down; JSON frames resync
/// trivially per WS text message.
///
/// NOT web-compilable: exported from `lib/io.dart` only, never the pure
/// core barrel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_api.dart';
import 'envelope.dart';
import 'upstream_client.dart';

export 'device_api.dart'
    show
        DeviceEnrollment,
        DeviceEnrollmentClient,
        DeviceEnrollmentException,
        DeviceRosterAgent,
        DeviceRosterSession,
        DeviceSummary;

/// A plain text duplex between a socket and the adapter — the seam that
/// keeps [ConnectorSocketAdapter] unit-testable without dart:io sockets:
/// tests drive it with in-memory pipes, production binds a [WebSocket].
abstract interface class ConnectorTextDuplex {
  /// Inbound text frames (one JSON envelope per WS text message).
  Stream<String> get inbound;

  /// Writes one outbound text frame. Throws when the socket is gone.
  Future<void> write(String text);

  /// Closes the underlying socket; idempotent.
  Future<void> shutdown();
}

/// The dart:io WebSocket duplex.
final class WebSocketDuplex implements ConnectorTextDuplex {
  /// Wraps [socket].
  WebSocketDuplex(this.socket);

  /// The live `dart:io` WebSocket.
  final WebSocket socket;

  @override
  Stream<String> get inbound => socket.cast<String>();

  @override
  Future<void> write(String text) async => socket.add(text);

  @override
  Future<void> shutdown() => socket.close();
}

/// The [ConnectorSocket] adapter over a [ConnectorTextDuplex]: decodes
/// inbound JSON text into [NetworkEnvelope]s, encodes outbound envelopes
/// into JSON text, and owns the closed/open state machine the upstream
/// client relies on (`isOpen`, throw-on-send-after-close, idempotent
/// close, frames stream completing on either side going away).
final class ConnectorSocketAdapter implements ConnectorSocket {
  /// Binds the adapter to [duplex]. [onLog] is the soft diagnostics sink
  /// (null = drop); it carries skipped-frame reports, never tokens.
  ConnectorSocketAdapter({required ConnectorTextDuplex duplex, this.onLog})
    : _duplex = duplex {
    _subscription = duplex.inbound.listen(
      _onText,
      onDone: () => _peerGone('closed by peer'),
      onError: (Object error) => _peerGone('$error'),
    );
  }

  final ConnectorTextDuplex _duplex;

  /// Soft diagnostics sink (null = drop).
  void Function(String message)? onLog;

  final _frames = StreamController<NetworkEnvelope>.broadcast();
  StreamSubscription<String>? _subscription;
  var _shutdown = false;
  var _closed = false;

  @override
  Stream<NetworkEnvelope> get frames => _frames.stream;

  /// True until [close] or the peer's side ended the socket.
  @override
  bool get isOpen => !_closed;

  @override
  Future<void> send(NetworkEnvelope envelope) async {
    if (_closed) throw StateError('socket closed');
    await _duplex.write(jsonEncode(envelope.toJson()));
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (_shutdown) return;
    _shutdown = true;
    await _subscription?.cancel();
    _subscription = null;
    await _duplex.shutdown();
    await _closeFrames();
  }

  /// The peer side ended the socket (clean close or inbound error): the
  /// socket is gone for the upstream client even before [close] runs.
  void _peerGone(String reason) {
    onLog?.call('device socket gone: $reason');
    _closed = true;
    if (!_shutdown) {
      _shutdown = true;
      unawaited(_subscription?.cancel());
      _subscription = null;
      unawaited(_duplex.shutdown());
    }
    unawaited(_closeFrames());
  }

  Future<void> _closeFrames() async {
    if (_frames.isClosed) return;
    await _frames.close();
  }

  /// Decodes one inbound text frame; malformed JSON or an invalid
  /// envelope is skipped with a diagnostic — the link stays up.
  void _onText(String text) {
    if (_closed) return;
    try {
      if (const bool.fromEnvironment('FA_RAW_WS')) {
        // ignore: avoid_print
        print('RAW_INBOUND: $text');
      }
      _frames.add(NetworkEnvelope.fromJson(jsonDecode(text)));
    } on FormatException catch (error) {
      onLog?.call('skipping malformed device frame: $error');
    }
  }
}

/// Dials the device WS with `dart:io`: the ticket rides the URL query
/// (`?ticket=<...>`, already folded in by the upstream client — the
/// parameter is accepted for the seam's shape and asserted nowhere).
/// Throws when the endpoint refuses the upgrade or is unreachable; the
/// upstream client retries with backoff.
final class IoConnectorTransport implements ConnectorTransport {
  /// Builds the transport (stateless).
  const IoConnectorTransport();

  @override
  Future<ConnectorSocket> dial(Uri url, String ticket) async {
    final socket = await WebSocket.connect(url.toString());
    return ConnectorSocketAdapter(duplex: WebSocketDuplex(socket));
  }
}
