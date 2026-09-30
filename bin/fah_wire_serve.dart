// fa wire-serve transport host (issue #1103) — WS + NDJSON-stdio plumbing
// around the pure [WireServeServer] core (lib/src/wire/wire_serve.dart).
//
// WS: loopback-only HTTP server (127.0.0.1), per-start bearer token in the
// handshake (`Authorization: Bearer <token>` or `?token=<token>`), exactly
// one live client (the pure core enforces single-attach; a second client
// gets the loud `already_attached` error frame). The one-time startup line
// `{"wire_serve":{"port":N,"token":"..."}}` goes to real stdout BEFORE the
// caller starts the agent boot.
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

  @override
  String toString() => encode();
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
      final frames = ws
          .cast<String>()
          .map(AgentWireProtocol.parseLine)
          .where((frame) => frame != null)
          .cast<Map<String, dynamic>>();
      await server
          .attach(frames, (frame) => ws.add(AgentWireProtocol.frameLine(frame)))
          .whenComplete(ws.close);
    } on Object catch (error) {
      // Upgrade raced a disconnect, or the attach raced shutdown —
      // nothing to serve on a dead socket.
      // ignore: avoid_print
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
/// mode. Blank lines are skipped; a malformed line is a loud protocol
/// error frame (the pure core's rule), never a silent drop.
Future<void> serveStdio(WireServeServer server) {
  return server.attach(
    stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty)
        .map(AgentWireProtocol.parseLine)
        .where((frame) => frame != null)
        .cast<Map<String, dynamic>>(),
    (frame) {
      stdout.writeln(AgentWireProtocol.frameLine(frame));
      stdout.flush();
    },
  );
}
