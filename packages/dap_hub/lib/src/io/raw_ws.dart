// Minimal RFC 6455 server-side WebSocket codec over a raw detached
// socket — the DAP/1 hub needs exactly this subset:
//
//   * text + binary messages (fragmentation reassembled),
//   * ping → automatic pong, pong ignored, close handshake,
//   * client frames must be masked (protocol error otherwise),
//   * a hard message size cap (Go's SetReadLimit equivalent),
//   * writes paced by Socket.flush() — REAL backpressure: dart:io's
//     WebSocket.add completes once bytes hit the unbounded internal
//     buffer, which would defeat the hub's slow-consumer shed.
//
// No permessage-deflate (never negotiated), no masking on outbound
// (server frames), no subprotocols.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../connection.dart';
import '../hub.dart' show maxFrameBytes;

/// Hard inbound message cap (Go relay.go: read limit 2 × maxFrameBytes).
const _maxMessageBytes = 2 * maxFrameBytes;

const _opContinuation = 0;
const _opText = 1;
const _opClose = 8;
const _opPing = 9;
const _opPong = 10;

/// RFC 6455 close codes used by the codec.
const _closeProtocolError = 1002;
const _closeTooBig = 1009;

/// A [DapConnection] speaking RFC 6455 over a raw server-side socket.
final class RawWsConnection implements DapConnection {
  /// Wraps an upgraded raw [socket] (see `DapHubServer`).
  RawWsConnection(this._socket, {required Duration pingInterval}) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => _terminate(),
      onDone: _terminate,
    );
    if (pingInterval > Duration.zero) {
      _pingTimer = Timer.periodic(pingInterval, (_) => _sendPing());
    }
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _subscription;
  Timer? _pingTimer;

  final _incoming = StreamController<Object>();
  final _buffer = BytesBuilder(copy: false);
  final _message = BytesBuilder(copy: false);
  var _messageOpcode = 0;
  var _open = true;
  var _closeSent = false;

  @override
  Stream<Object> get messages => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> sendText(String text) async {
    if (!_open) return;
    _socket.add(_encodeFrame(_opText, utf8.encode(text)));
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _pingTimer?.cancel();
    try {
      if (!_closeSent) {
        _closeSent = true;
        _socket.add(_encodeFrame(_opClose, const []));
        await _socket.flush();
      }
      await _socket.close();
    } on Object {
      // Already gone.
    }
    await _finish();
  }

  // ---- inbound parsing ----

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    while (_open && _parseOneFrame()) {}
  }

  /// Parses one complete frame from the buffer; false when more bytes
  /// are needed. Consumed bytes are removed from the buffer.
  bool _parseOneFrame() {
    final bytes = _buffer.toBytes();
    if (bytes.length < 2) return false;
    final fin = bytes[0] & 0x80 != 0;
    final opcode = bytes[0] & 0x0F;
    final masked = bytes[1] & 0x80 != 0;
    final parsed = _frameLength(bytes);
    if (parsed == null) return false;
    final (length, headerEnd) = parsed;
    var offset = headerEnd;
    if (!masked) {
      _failClose(_closeProtocolError);
      return false;
    }
    if (bytes.length < offset + 4 + length) return false;
    final mask = bytes.sublist(offset, offset + 4);
    offset += 4;
    final payload = Uint8List(length);
    for (var i = 0; i < length; i++) {
      payload[i] = bytes[offset + i] ^ mask[i % 4];
    }
    _consumeBuffer(offset + length);
    _handleFrame(fin, opcode, payload);
    return _open;
  }

  /// Decodes the payload-length field; null when the extended length
  /// bytes have not all arrived yet. Returns (length, headerOffset).
  (int, int)? _frameLength(Uint8List bytes) {
    var length = bytes[1] & 0x7F;
    var offset = 2;
    if (length == 126) {
      if (bytes.length < 4) return null;
      length = (bytes[2] << 8) | bytes[3];
      offset = 4;
    } else if (length == 127) {
      if (bytes.length < 10) return null;
      length = 0;
      for (var i = 0; i < 8; i++) {
        length = (length << 8) | bytes[2 + i];
      }
      offset = 10;
    }
    return (length, offset);
  }

  void _consumeBuffer(int count) {
    final rest = _buffer.toBytes().sublist(count);
    _buffer.clear();
    _buffer.add(rest);
  }

  void _handleFrame(bool fin, int opcode, Uint8List payload) {
    if (opcode >= _opClose) {
      _handleControl(opcode, fin, payload);
      return;
    }
    if (opcode != _opContinuation) {
      if (_messageOpcode != 0) {
        _failClose(_closeProtocolError); // new message mid-fragment
        return;
      }
      _messageOpcode = opcode;
    } else if (_messageOpcode == 0) {
      _failClose(_closeProtocolError); // stray continuation
      return;
    }
    _message.add(payload);
    if (_message.length > _maxMessageBytes) {
      _failClose(_closeTooBig);
      return;
    }
    if (fin) _emitMessage();
  }

  void _handleControl(int opcode, bool fin, Uint8List payload) {
    if (!fin || payload.length > 125) {
      _failClose(_closeProtocolError);
      return;
    }
    switch (opcode) {
      case _opPing:
        _socket.add(_encodeFrame(_opPong, payload));
      case _opPong:
        break; // liveness only; TCP errors do the rest
      case _opClose:
        _echoCloseAndEnd();
    }
  }

  void _emitMessage() {
    final bytes = _message.takeBytes();
    final opcode = _messageOpcode;
    _messageOpcode = 0;
    if (opcode == _opText) {
      _incoming.add(utf8.decode(bytes, allowMalformed: true));
    } else {
      _incoming.add(bytes);
    }
  }

  void _echoCloseAndEnd() {
    if (!_closeSent) {
      _closeSent = true;
      try {
        _socket.add(_encodeFrame(_opClose, const []));
      } on Object {
        // Socket already gone.
      }
    }
    unawaited(
        _socket.flush().then((_) => _socket.close()).catchError((Object _) {}));
    _terminate();
  }

  /// Protocol-level fatal: close code frame, then terminate.
  void _failClose(int code) {
    if (!_open) return;
    if (!_closeSent) {
      _closeSent = true;
      try {
        _socket.add(_encodeFrame(_opClose, [
          (code >> 8) & 0xFF,
          code & 0xFF,
        ]));
      } on Object {
        // Socket already gone.
      }
    }
    unawaited(
        _socket.flush().then((_) => _socket.close()).catchError((Object _) {}));
    _terminate();
  }

  void _sendPing() {
    if (!_open) return;
    try {
      _socket.add(_encodeFrame(_opPing, const []));
    } on Object {
      _terminate();
    }
  }

  void _terminate() {
    if (!_open) return;
    _open = false;
    _pingTimer?.cancel();
    unawaited(_finish());
  }

  Future<void> _finish() async {
    await _subscription.cancel();
    // NOT awaited: a paused listener (e.g. a StreamQueue between nexts)
    // would block the done event and close() would never complete.
    // Events already queued still flush to whoever is listening.
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  // ---- outbound framing ----

  List<int> _encodeFrame(int opcode, List<int> payload) {
    final header = <int>[0x80 | opcode];
    final length = payload.length;
    if (length < 126) {
      header.add(length);
    } else if (length <= 0xFFFF) {
      header.addAll([126, (length >> 8) & 0xFF, length & 0xFF]);
    } else {
      header.add(127);
      for (var i = 7; i >= 0; i--) {
        header.add((length >> (8 * i)) & 0xFF);
      }
    }
    return [...header, ...payload];
  }
}
