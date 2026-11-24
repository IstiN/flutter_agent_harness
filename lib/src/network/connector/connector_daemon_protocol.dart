// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pure-Dart shared-connector wire protocol and state-file schema for the
/// single-per-machine Machine Connector daemon (`docs/fa_network_connector.md`
/// §3 / §10: one upstream WS per device multiplexing every local CLI session
/// and desktop app process over loopback).
///
/// Transport (`dart:io` HttpServer / WebSocket / pid probe) lives in
/// `lib/src/network/connector/connector_daemon_io.dart` (exported via
/// `lib/io.dart`). This file stays 100% pure Dart.
library;

import 'dart:convert';

import 'envelope.dart';

/// Persisted discovery descriptor written to `~/.fah/network/connector.json`
/// (mode 0600) by the running Machine Connector daemon so any local `fa` CLI
/// or desktop app process can attach instead of opening a competing upstream
/// WebSocket for the same `deviceId`.
final class ConnectorDaemonState {
  const ConnectorDaemonState({
    required this.pid,
    required this.port,
    required this.token,
    required this.deviceId,
    required this.baseUrl,
  });

  /// OS process id of the running connector daemon.
  final int pid;

  /// Loopback TCP port bound on `127.0.0.1`.
  final int port;

  /// Per-launch ephemeral bearer token authenticating local clients.
  final String token;

  /// Enrolled `deviceId` served by this daemon.
  final String deviceId;

  /// Relay base URL this daemon is connected to (e.g. `https://network.fa1.dev`).
  final String baseUrl;

  /// Loopback WebSocket URI for local clients.
  Uri get wsUri => Uri.parse('ws://127.0.0.1:$port/ws');

  /// Loopback healthz URI.
  Uri get healthzUri => Uri.parse('http://127.0.0.1:$port/healthz');

  Map<String, Object?> toJson() => {
    'pid': pid,
    'port': port,
    'token': token,
    'deviceId': deviceId,
    'baseUrl': baseUrl,
  };

  /// Parses a persisted state JSON object; returns null on malformed input.
  static ConnectorDaemonState? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final pid = raw['pid'];
    final port = raw['port'];
    final token = raw['token'];
    final deviceId = raw['deviceId'];
    final baseUrl = raw['baseUrl'];
    if (pid is! int ||
        pid <= 0 ||
        port is! int ||
        port <= 0 ||
        port > 65535 ||
        token is! String ||
        token.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        baseUrl is! String ||
        baseUrl.isEmpty) {
      return null;
    }
    return ConnectorDaemonState(
      pid: pid,
      port: port,
      token: token,
      deviceId: deviceId,
      baseUrl: baseUrl,
    );
  }
}

/// Wire message types exchanged between the local Machine Connector daemon and
/// local CLI / desktop-app clients over `ws://127.0.0.1:<port>/ws`.
final class ConnectorDaemonWire {
  const ConnectorDaemonWire._();

  // Client → Daemon
  static const String registerSession = 'register_session';
  static const String unregisterSession = 'unregister_session';
  static const String setBusy = 'set_busy';
  static const String sendDmReply = 'send_dm_reply';
  static const String dmDeliverAck = 'dm_deliver_ack';
  static const String getRoster = 'get_roster';

  // Daemon → Client
  static const String dmDeliver = 'dm_deliver';
  static const String rpcResult = 'rpc_result';
  static const String rosterEvent = 'roster_event';
  static const String presenceEvent = 'presence_event';
  static const String noticeEvent = 'notice_event';

  /// Encodes a client→daemon request or notification frame.
  static String encode(Map<String, Object?> payload) => jsonEncode(payload);

  /// Decodes a JSON object frame; returns null on invalid JSON / non-object.
  static Map<String, Object?>? tryDecode(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      return {
        for (final MapEntry(:key, :value) in decoded.entries) '$key': value,
      };
    } on FormatException {
      return null;
    }
  }

  /// Serializes an inbound DM delivery payload for a local client session.
  static Map<String, Object?> encodeDmDeliver({
    required String deliveryId,
    required String sessionId,
    required NetworkEnvelope envelope,
    required String text,
    required String senderLabel,
    required String replyAddress,
    String? senderPubkey,
    bool threaded = false,
  }) => {
    'type': dmDeliver,
    'deliveryId': deliveryId,
    'sessionId': sessionId,
    'envelope': envelope.toJson(),
    'text': text,
    'senderLabel': senderLabel,
    'replyAddress': replyAddress,
    'senderPubkey': ?senderPubkey,
    'threaded': threaded,
  };
}
