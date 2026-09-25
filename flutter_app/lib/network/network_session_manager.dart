// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// ignore_for_file: prefer_initializing_formals — named private
// parameters cannot be initializing formals in Dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'fa_network_client.dart';
import 'fa_network_ws.dart';
import 'key_wallet.dart';
import 'models.dart';
import 'network_session.dart';

/// Owns the [KeyWallet] and every live [NetworkSession] (issue #955):
/// join, silent resume, leave. One manager per app run; the UI binds to it
/// for the networks sidebar (memberships with live badges) and the chat.
final class NetworkSessionManager extends ChangeNotifier {
  NetworkSessionManager({
    required Uri baseUrl,
    required KeyWallet wallet,
    http.Client? httpClient,
    WsConnector? wsConnector,
    String? jwtToken,
  }) : _baseUrl = baseUrl,
       _wallet = wallet,
       _http = httpClient ?? http.Client(),
       _connector = wsConnector ?? const WebSocketChannelConnector(),
       _jwt = jwtToken;

  final Uri _baseUrl;
  final KeyWallet _wallet;
  final http.Client _http;
  final WsConnector _connector;

  String? _jwt;
  String? _sessionToken;

  /// The live sessions by network id.
  final Map<String, NetworkSession> sessions = {};

  /// Joins in flight, coalesced by network id: a controller-change silent
  /// resume (the home page's `_ensureSession`) racing an explicit
  /// join/resume (sidebar tap, ⌘N switch) must not join the same network
  /// twice.
  final Map<String, Future<NetworkSession>> _joinsInFlight = {};

  KeyWallet get wallet => _wallet;

  /// The ai-native JWT (management routes + authed join); null = guest.
  set jwt(String? token) => _jwt = token;

  /// Whether an ai-native JWT is set (drives management-only UI like
  /// network creation — guests never see those affordances).
  bool get hasJwt => _jwt != null && _jwt!.isNotEmpty;

  /// Re-reads wallet-driven UI after an out-of-band wallet mutation
  /// (e.g. a wallet import replacing the contents in place).
  void walletExternallyUpdated() => notifyListeners();

  /// Ensures the wallet identity exists (first-run onboarding calls this
  /// with the human's chosen display name).
  Future<void> ensureIdentity({String displayName = ''}) =>
      _wallet.createIfMissing(displayName: displayName);

  /// Joins [networkId] with [password] (guest join when no JWT is set,
  /// authed join otherwise — the server locks the display name then),
  /// records the membership + password in the wallet, and starts the
  /// session. Returns the live session. Concurrent joins of the same
  /// network coalesce into one in-flight call.
  Future<NetworkSession> join({
    required String networkId,
    required String password,
    String? displayName,
  }) {
    final inFlight = _joinsInFlight[networkId];
    if (inFlight != null) return inFlight;
    final future = _join(
      networkId: networkId,
      password: password,
      displayName: displayName,
    );
    _joinsInFlight[networkId] = future;
    future.whenComplete(() => _joinsInFlight.remove(networkId)).ignore();
    return future;
  }

  Future<NetworkSession> _join({
    required String networkId,
    required String password,
    String? displayName,
  }) async {
    final client = _newClient();
    final result = await client.joinNetwork(
      networkId,
      password: password,
      displayName: displayName,
    );
    await _wallet.addNetwork(
      networkId: networkId,
      name: result.network?.name ?? networkId,
      memberClass: result.identity.memberClass.name,
      displayName: result.identity.displayName,
      password: password,
    );
    return _startSession(networkId, result, client);
  }

  /// Silently re-joins a known membership using the password stored in
  /// the wallet (the contract's sessionToken is memory-only, E7). Throws
  /// [StateError] when the wallet has no credentials for [networkId].
  Future<NetworkSession> resume(String networkId) async {
    final entry = _wallet.networks[networkId];
    final password = entry?.password;
    if (entry == null || password == null) {
      throw StateError(
        'no stored credentials for network $networkId — join again',
      );
    }
    return join(networkId: networkId, password: password);
  }

  /// An already-known live session, or null.
  NetworkSession? operator [](String networkId) => sessions[networkId];

  /// Leaves the network: the session closes and every key + membership
  /// for it is removed from the wallet.
  Future<void> leave(String networkId) async {
    final session = sessions.remove(networkId);
    if (session != null) await session.close();
    await _wallet.removeNetwork(networkId);
    notifyListeners();
  }

  /// Closes every live session but keeps all keys (mode switch to local).
  Future<void> disconnectAll() async {
    for (final session in sessions.values) {
      await session.close();
    }
    sessions.clear();
    notifyListeners();
  }

  FaNetworkClient _newClient() =>
      FaNetworkClient(baseUrl: _baseUrl, httpClient: _http, jwtToken: _jwt);

  /// Creates a network (management route — requires a JWT); the caller
  /// becomes owner and is joined immediately with the one-time join
  /// credentials. Returns the live session.
  Future<NetworkSession> createNetwork({
    required String name,
    required String password,
  }) async {
    final client = _newClient()..session = _sessionToken;
    final result = await client.createNetwork(name: name, password: password);
    final networkId = result.network.id;
    return join(
      networkId: networkId,
      password: result.joinCredentials?.password ?? password,
    );
  }

  /// Creates a channel inside [networkId] (management route — public
  /// channels require owner/admin) and reflects it into the live session's
  /// channel list when one is running.
  Future<Channel> createChannel(
    String networkId, {
    required String name,
    bool isPublic = false,
  }) async {
    final client = _newClient()..session = _sessionToken;
    final channel = await client.createChannel(
      networkId,
      name: name,
      isPublic: isPublic,
    );
    sessions[networkId]?.addChannel(channel);
    return channel;
  }

  NetworkSession _startSession(
    String networkId,
    JoinResult result,
    FaNetworkClient client,
  ) {
    _sessionToken = result.sessionToken;
    client.session = result.sessionToken;
    final ws = FaNetworkWs(
      baseUrl: _baseUrl,
      connector: _connector,
      sessionToken: () => _sessionToken ?? '',
    );
    final session = NetworkSession(
      networkId: networkId,
      identity: result.identity,
      client: client,
      ws: ws,
      wallet: _wallet,
    );
    sessions[networkId] = session;
    notifyListeners();
    // Fire and forget: the UI binds to the session and watches it fill in.
    session.start();
    return session;
  }
}
