// Unit tests for the raw RFC 6455 codec: framing, masking rules,
// fragmentation, control frames, close handshake, ping timer, and the
// message size cap. Exercises RawWsConnection over a raw socket pair —
// no HTTP, no hub.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:dap_hub/src/io/raw_ws.dart';
import 'package:test/test.dart';

void main() {
  late ServerSocket listener;
  late Socket client;
  late RawWsConnection conn;
  late StreamQueue<Object> messages;

  /// Builds a masked client→server frame.
  List<int> clientFrame(
    int opcode,
    List<int> payload, {
    bool fin = true,
    bool masked = true,
  }) {
    final mask = [1, 2, 3, 4];
    final header = <int>[
      (fin ? 0x80 : 0) | opcode,
      (masked ? 0x80 : 0) | payload.length,
      if (masked) ...mask,
    ];
    final body = masked
        ? [for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4]]
        : payload;
    return [...header, ...body];
  }

  final incomingBytes = <int>[];
  late StreamSubscription<Uint8List> clientSub;

  Future<List<int>> takeBytes(int count) async {
    while (incomingBytes.length < count) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final out = incomingBytes.sublist(0, count);
    incomingBytes.removeRange(0, count);
    return out;
  }

  /// Reads one server→client frame as (opcode, payload).
  Future<(int, List<int>)> readServerFrame() async {
    final header = await takeBytes(2);
    final opcode = header[0] & 0x0F;
    var length = header[1] & 0x7F;
    if (length == 126) {
      final ext = await takeBytes(2);
      length = (ext[0] << 8) | ext[1];
    } else if (length == 127) {
      final ext = await takeBytes(8);
      length = 0;
      for (final b in ext) {
        length = (length << 8) | b;
      }
    }
    return (opcode, await takeBytes(length));
  }

  setUp(() async {
    listener = await ServerSocket.bind('127.0.0.1', 0);
    final serverSide = listener.first;
    client = await Socket.connect('127.0.0.1', listener.port);
    incomingBytes.clear();
    clientSub = client.listen(incomingBytes.addAll);
    conn = RawWsConnection(
      await serverSide,
      pingInterval: const Duration(hours: 1),
    );
    messages = StreamQueue(conn.messages);
  });

  tearDown(() async {
    await conn.close();
    await clientSub.cancel();
    client.destroy();
    await listener.close();
  });

  test('a text frame arrives as a String message', () async {
    client.add(clientFrame(1, utf8.encode('hello')));
    expect(await messages.next, 'hello');
  });

  test('a binary frame arrives as bytes', () async {
    client.add(clientFrame(2, [1, 2, 3]));
    expect(await messages.next, [1, 2, 3]);
  });

  test('fragmented text reassembles across continuations', () async {
    client.add(clientFrame(1, utf8.encode('hel'), fin: false));
    client.add(clientFrame(0, utf8.encode('lo'), fin: true));
    expect(await messages.next, 'hello');
  });

  test('a ping gets a pong with the same payload', () async {
    client.add(clientFrame(9, [9, 9, 9]));
    final (opcode, payload) = await readServerFrame();
    expect(opcode, 10);
    expect(payload, [9, 9, 9]);
  });

  test('pongs are ignored silently', () async {
    client.add(clientFrame(10, []));
    client.add(clientFrame(1, utf8.encode('after')));
    expect(await messages.next, 'after');
  });

  test('an unmasked client frame is a protocol error (1002)', () async {
    client.add(clientFrame(1, utf8.encode('x'), masked: false));
    final (opcode, payload) = await readServerFrame();
    expect(opcode, 8);
    expect((payload[0] << 8) | payload[1], 1002);
    expect(conn.isOpen, isFalse);
  });

  test('a fragmented control frame is a protocol error', () async {
    client.add(clientFrame(9, [], fin: false));
    final (opcode, _) = await readServerFrame();
    expect(opcode, 8);
  });

  test('a stray continuation is a protocol error', () async {
    client.add(clientFrame(0, utf8.encode('x')));
    final (opcode, payload) = await readServerFrame();
    expect(opcode, 8);
    expect((payload[0] << 8) | payload[1], 1002);
  });

  test('a new message mid-fragment is a protocol error', () async {
    client.add(clientFrame(1, utf8.encode('a'), fin: false));
    client.add(clientFrame(1, utf8.encode('b')));
    final (opcode, _) = await readServerFrame();
    expect(opcode, 8);
  });

  test('an oversized message closes with 1009', () async {
    // One 2 MiB+1 masked binary frame (64-bit length form).
    final length = (1 << 21) + 1;
    final header = <int>[0x82, 0xFF];
    for (var i = 7; i >= 0; i--) {
      header.add((length >> (8 * i)) & 0xFF);
    }
    header.addAll([1, 2, 3, 4]);
    client.add(header);
    final masked = List<int>.generate(
      length,
      (i) => 0x41 ^ [1, 2, 3, 4][i % 4],
    );
    client.add(masked);
    final (opcode, payload) = await readServerFrame();
    expect(opcode, 8);
    expect((payload[0] << 8) | payload[1], 1009);
  });

  test('the close handshake echoes close and ends the stream', () async {
    client.add(clientFrame(8, []));
    final (opcode, _) = await readServerFrame();
    expect(opcode, 8);
    expect(conn.isOpen, isFalse);
    expect(await messages.hasNext, isFalse);
  });

  test('sendText writes an unmasked text frame', () async {
    await conn.sendText('outbound');
    final (opcode, payload) = await readServerFrame();
    expect(opcode, 1);
    expect(utf8.decode(payload), 'outbound');
  });

  test('close() sends a close frame and closes the socket', () async {
    await conn.close();
    final (opcode, _) = await readServerFrame();
    expect(opcode, 8);
    expect(conn.isOpen, isFalse);
  });

  test('a large text frame with 16-bit length round-trips', () async {
    final big = utf8.encode('Q' * 60000);
    final header = <int>[
      0x81,
      0x80 | 126,
      (big.length >> 8) & 0xFF,
      big.length & 0xFF,
      1,
      2,
      3,
      4,
    ];
    client.add(header);
    client.add([
      for (var i = 0; i < big.length; i++) big[i] ^ [1, 2, 3, 4][i % 4],
    ]);
    expect(await messages.next, 'Q' * 60000);
  });

  test('the ping timer emits protocol pings', () async {
    // A fresh pair with a fast pinger on the server side.
    final fastListener = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(fastListener.close);
    final fastClient = await Socket.connect('127.0.0.1', fastListener.port);
    addTearDown(fastClient.destroy);
    final received = <int>[];
    final sub = fastClient.listen(received.addAll);
    addTearDown(sub.cancel);
    final pinging = RawWsConnection(
      await fastListener.first,
      pingInterval: const Duration(milliseconds: 20),
    );
    addTearDown(pinging.close);
    // Wait until a ping frame (opcode 9, empty payload: 0x89 0x00).
    for (var i = 0; i < 400; i++) {
      if (received.length >= 2 && received[0] == 0x89) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no ping arrived: $received');
  });
}
