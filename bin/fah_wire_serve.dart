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

/// The NDJSON line bound: a line longer than this is refused with a loud
/// `bad_frame` and skipped instead of growing memory without limit
/// (review #1113 r4). In-frames are commands - prompts, steers, responses
/// - so 1 MiB is far past any legitimate frame.
const int _maxLineBytes = 1 << 20;

/// Splits a raw byte stream into NDJSON lines on 0x0A (JSON never embeds
/// a raw newline, so byte-level splitting is exact), carrying partial
/// lines across chunks; a trailing 0x0D from CRLF writers is trimmed.
/// The accumulator never copies the whole buffer per chunk (the carry
/// completes at most once per chunk, the rest is scanned in place), and
/// a line past [maxLineBytes] is dropped loudly via [onOversize] instead
/// of growing without bound (review #1113 r4).
Stream<List<int>> byteLines(
  Stream<List<int>> chunks, {
  void Function(String message)? onOversize,
  int maxLineBytes = _maxLineBytes,
}) async* {
  var carry = <int>[];
  await for (final chunk in chunks) {
    final (lines, carryRest) = _stepBytes(
      carry,
      chunk,
      maxLineBytes,
      onOversize,
    );
    yield* Stream<List<int>>.fromIterable(lines);
    carry = carryRest;
  }
  if (carry.isNotEmpty) yield _trimCr(carry);
}

/// One drain step: emits the chunk's complete lines (oversized ones
/// dropped with a loud [WireServeServer.protocolError]-shaped callback)
/// and returns the trailing carry.
(List<List<int>>, List<int>) _stepBytes(
  List<int> carry,
  List<int> chunk,
  int maxLineBytes,
  void Function(String message)? onOversize,
) {
  final (lines, rest, oversized) = _drainByteLines(carry, chunk, maxLineBytes);
  if (oversized) onOversize?.call('ndjson line exceeded $maxLineBytes bytes');
  return (lines, rest);
}

/// Drains every complete line out of `carry + chunk` without per-chunk
/// copies of the accumulated buffer: the carry completes AT MOST once
/// per chunk (one O(line) copy), everything after is scanned in place.
/// Returns the lines, the trailing partial line, and whether an
/// oversized line was discarded.
(List<List<int>>, List<int>, bool) _drainByteLines(
  List<int> carry,
  List<int> chunk,
  int maxLineBytes,
) {
  if (carry.isNotEmpty) return _drainCarryLine(carry, chunk, maxLineBytes);
  return _finishSplit(chunk, 0, <List<int>>[], maxLineBytes);
}

/// The carry-completion branch: a line already in flight either finishes
/// in this chunk, keeps growing (bounded - past the cap it is dropped),
/// or is skipped to its terminating 0x0A when already oversized.
(List<List<int>>, List<int>, bool) _drainCarryLine(
  List<int> carry,
  List<int> chunk,
  int maxLineBytes,
) {
  if (carry.length > maxLineBytes) return _skipOversized(chunk, maxLineBytes);
  final nl = chunk.indexOf(0x0A);
  if (nl < 0) {
    // A fresh growable list: the previous chunk's rest may be a
    // fixed-length Uint8List view, which addAll would reject.
    final merged = List<int>.of(carry)..addAll(chunk);
    return (const <List<int>>[], merged, false);
  }
  final merged = List<int>.of(carry)..addAll(chunk.sublist(0, nl));
  return _finishSplit(chunk, nl + 1, <List<int>>[
    _trimCr(merged),
  ], maxLineBytes);
}

/// An oversized line is in flight: drop it and resume after the chunk's
/// first newline (or consume the whole chunk when it has none). Always
/// reports oversized - entering here means a line WAS discarded.
(List<List<int>>, List<int>, bool) _skipOversized(
  List<int> chunk,
  int maxLineBytes,
) {
  final nl = chunk.indexOf(0x0A);
  if (nl < 0) return (const <List<int>>[], <int>[], true);
  final (lines, rest, _) = _finishSplit(
    chunk,
    nl + 1,
    <List<int>>[],
    maxLineBytes,
  );
  return (lines, rest, true);
}

/// Scans chunk[start..] for complete lines, prepending [head]; a
/// complete line past [maxLineBytes] is dropped (not emitted) and marks
/// the result oversized.
(List<List<int>>, List<int>, bool) _finishSplit(
  List<int> chunk,
  int start,
  List<List<int>> head,
  int? maxLineBytes,
) {
  final lines = head;
  var oversized = false;
  for (var i = start; i < chunk.length; i++) {
    if (chunk[i] != 0x0A) continue;
    final line = _trimCr(chunk.sublist(start, i));
    if (maxLineBytes != null && line.length > maxLineBytes) {
      oversized = true;
    } else {
      lines.add(line);
    }
    start = i + 1;
  }
  return (lines, chunk.sublist(start), oversized);
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
/// malformed byte or an oversized line is a loud `bad_frame`, never a
/// silent server death.
Future<void> serveStdio(WireServeServer server) {
  final send = (Map<String, dynamic> frame) {
    stdout.writeln(AgentWireProtocol.frameLine(frame));
    stdout.flush();
  };
  return server.attach(
    decodeNdjson(
      server,
      byteLines(
        stdin,
        onOversize: (message) =>
            server.protocolError('bad_frame', message, send),
      ),
      send,
    ),
    send,
  );
}
