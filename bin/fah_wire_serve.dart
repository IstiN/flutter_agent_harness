// fa wire-serve transport host (issue #1103) — WS + NDJSON-stdio plumbing
// around the pure [WireServeServer] core (lib/src/wire/wire_serve.dart).
//
// WS: loopback-only HTTP server (127.0.0.1), per-start bearer token in the
// handshake (`Authorization: Bearer <token>` or `?token=<token>`), exactly
// one live client (the pure core enforces single-attach; a second client
// gets the loud `already_attached` error frame). The one-time startup line
// `{"wire_serve":{"port":N,"token":"..."}}` goes to real stdout only AFTER
// the agent boot (and its lease gate) succeeded - the port itself binds
// early so a race fails loudly before the boot (review #1113 r3).
//
// stdio: NDJSON frames on stdin (blank lines skipped), frames out through
// [AgentWireProtocol.frameLine] + flush — the pipe-embedding contract
// (docs/wire-protocol.md §7). `--stdio` and `--port` are mutually
// exclusive; flag validation lives in the CLI split (bin/fah.dart).
//
// NOT a security boundary: loopback bind + bearer gate only; any local
// process can read the startup line. Documented, deliberate (issue body).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/browser/bridge_protocol.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';
import 'package:flutter_agent_harness/src/wire/wire_serve.dart';

/// The one-time `fa wire-serve` startup line — the ONLY thing this mode
/// ever writes to real stdout in WS mode (E3: never the token elsewhere;
/// `_log` goes to stderr, and the pure core cannot print).
final class WireServeStartupLine {
  WireServeStartupLine({required this.port, required this.token});

  final int port;
  final String token;

  Map<String, dynamic> toJson() => {
    'wire_serve': {'port': port, 'token': token},
  };

  String encode() => jsonEncode(toJson());

  // E4: the token rides `encode()` ONLY (the one stdout startup line).
  // String interpolation in logs/debuggers must never leak it.
  @override
  String toString() => 'WireServeStartupLine(port: $port, token: <redacted>)';
}

/// Mints the per-start bearer token: 32 secure random bytes as 64 lowercase
/// hex chars — the same shape (and quality) as the /browser pairing token.
String wireServeToken() => pairingToken();

/// Binds the loopback WS port BEFORE the agent boots (AC20: a port race
/// fails loudly at startup, naming the port — never a silent fallback).
Future<HttpServer> bindLoopback(int port) =>
    HttpServer.bind(InternetAddress.loopbackIPv4, port);

/// True when [request] carries the bearer [token] (Authorization header or
/// `?token=` query param — the query form serves parents that cannot set
/// headers).
bool tokenOk(HttpRequest request, String token) =>
    request.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $token' ||
    request.uri.queryParameters['token'] == token;

/// NDJSON decode for both transports. One message in — a WS text frame,
/// a WS binary frame's bytes, or one stdio line's raw bytes (via
/// [byteLines]) — becomes at most one frame. Blank lines are skipped;
/// ANY decode failure, byte-level (invalid UTF-8) or line-level (not
/// JSON, not a frame), is a loud `bad_frame` frame and the stream STAYS
/// ALIVE (review #1113 r2 BLOCKING #1 + r3 #1: one bad line or one bad
/// BYTE never kills the connection — stdio used to die with exit 0).
Stream<Map<String, dynamic>> decodeNdjson(
  WireServeServer server,
  Stream<Object> messages,
  void Function(Map<String, dynamic> frame) send,
) => messages
    .map((message) => _decodeMessage(server, message, send))
    .where((frame) => frame != null)
    .cast<Map<String, dynamic>>();

/// One transport message -> at most one frame; every failure mode
/// answers [WireServeServer.protocolError] and yields null.
Map<String, dynamic>? _decodeMessage(
  WireServeServer server,
  Object message,
  void Function(Map<String, dynamic> frame) send,
) {
  try {
    final line = _messageLine(message);
    if (line == null) {
      throw const FormatException('unsupported frame payload');
    }
    return AgentWireProtocol.parseLine(line);
  } on Object catch (error) {
    // Transport boundary: any decode failure (byte, JSON, or frame
    // shape) is the client's line problem, not the server's.
    server.protocolError('bad_frame', '$error', send);
    return null;
  }
}

/// Decodes one message to its NDJSON line text, or null for an
/// unsupported payload type. Byte payloads decode STRICTLY - a malformed
/// byte throws [FormatException] (the caller turns it into bad_frame).
String? _messageLine(Object message) {
  if (message is List<int>) return utf8.decode(message).trim();
  if (message is String) return message.trim();
  return null;
}

/// Splits a raw byte stream into NDJSON lines on 0x0A (JSON never embeds
/// a raw newline, so byte-level splitting is exact), carrying partial
/// lines across chunks; a trailing 0x0D from CRLF writers is trimmed.
Stream<List<int>> byteLines(Stream<List<int>> chunks) async* {
  var carry = <int>[];
  await for (final chunk in chunks) {
    final (lines, rest) = _drainByteLines(carry, chunk);
    yield* Stream<List<int>>.fromIterable(lines);
    carry = rest;
  }
  if (carry.isNotEmpty) yield _trimCr(carry);
}

/// Drains every complete line out of `carry + chunk`; returns the lines
/// and the trailing partial line (empty when the chunk ended on 0x0A).
(List<List<int>>, List<int>) _drainByteLines(List<int> carry, List<int> chunk) {
  final buffer = [...carry, ...chunk];
  final lines = <List<int>>[];
  var start = 0;
  for (var i = 0; i < buffer.length; i++) {
    if (buffer[i] == 0x0A) {
      lines.add(_trimCr(buffer.sublist(start, i)));
      start = i + 1;
    }
  }
  return (lines, buffer.sublist(start));
}

List<int> _trimCr(List<int> line) => line.isNotEmpty && line.last == 0x0D
    ? line.sublist(0, line.length - 1)
    : line;

/// Accept loop: upgrade + token-gate each request, then hand the decoded
/// frame stream to [WireServeServer.attach]. One NDJSON line per frame in
/// both directions (docs/wire-protocol.md §7 — the socket transport
/// carries the same lines). Runs until [http] closes.
Future<void> httpListen(HttpServer http, WireServeServer server, String token) {
  return http.forEach((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (!tokenOk(request, token)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    try {
      final ws = await WebSocketTransformer.upgrade(request);
      final send = (Map<String, dynamic> frame) =>
          ws.add(AgentWireProtocol.frameLine(frame));
      // Text frames arrive as String, binary frames as Uint8List (a
      // List<int>) — both decode through the guarded path. (Invalid
      // UTF-8 in a TEXT frame fails the socket inside dart:io per RFC
      // 6455; that layer is not ours to guard.)
      await server
          .attach(decodeNdjson(server, ws.cast<Object>(), send), send)
          .whenComplete(ws.close);
    } on Object catch (error) {
      // Upgrade raced a disconnect, or the attach raced shutdown —
      // nothing to serve on a dead socket.
      stderr.writeln('wire-serve: ws handler failed: $error');
    }
  });
}

/// Writes the one-time startup line to REAL stdout — the ONLY thing
/// `fa wire-serve` WS mode ever puts there (the protocol stream carries
/// frames only; `_log` diagnostics go to stderr).
void writeStartupLine(WireServeStartupLine line) {
  stdout.writeln(line.encode());
  stdout.flush();
}

/// Serves [WireServeServer.attach] over NDJSON stdin/stdout until stdin
/// EOF; the returned future IS the graceful-shutdown trigger in stdio
/// mode. Bytes decode through [byteLines] + strict per-line UTF-8 — a
/// malformed byte is a loud `bad_frame`, never a silent server death.
Future<void> serveStdio(WireServeServer server) {
  final send = (Map<String, dynamic> frame) {
    stdout.writeln(AgentWireProtocol.frameLine(frame));
    stdout.flush();
  };
  return server.attach(decodeNdjson(server, byteLines(stdin), send), send);
}
