// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// ignore_for_file: prefer_initializing_formals — named private
// parameters cannot be initializing formals in Dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_flow.dart';
import 'auth_loopback.dart';
import 'fa_network_client.dart';
import 'fa_network_ws.dart';
import '../services/app_log.dart';
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
    Uri? authBaseUrl,
    http.Client? httpClient,
    WsConnector? wsConnector,
    String? jwtToken,
    Future<OAuthCallbackReceiver> Function()? startReceiver,
    Future<void> Function(Uri authUrl)? openUrl,
    DateTime Function()? clock,
  }) : _baseUrl = baseUrl,
       _authBaseUrl = authBaseUrl,
       _wallet = wallet,
       _http = httpClient ?? http.Client(),
       _connector = wsConnector ?? const WebSocketChannelConnector(),
       _startReceiver = startReceiver ?? startOAuthCallbackReceiver,
       _openUrl = openUrl ?? openAuthUrl,
       _clock = clock ?? DateTime.now,
       _jwt = jwtToken;

  final Uri _baseUrl;

  /// The ai-native auth service base (null = the client's default
  /// https://ai-native.cloud).
  final Uri? _authBaseUrl;
  final KeyWallet _wallet;
  final http.Client _http;
  final WsConnector _connector;

  /// The OAuth seams: the desktop loopback receiver + browser opener in
  /// production, fakes in tests (never bind a real port there).
  final Future<OAuthCallbackReceiver> Function() _startReceiver;
  final Future<void> Function(Uri authUrl) _openUrl;

  /// The clock seam for the token-expiry checks (test-friendly).
  final DateTime Function() _clock;

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

  /// The login the JWT was minted for: the wallet account's email after
  /// an OAuth sign-in (the tokens persist in the wallet), else the dev
  /// login from [signIn] (in memory only; issue #955).
  String? get accountLogin {
    final walletLogin = _wallet.account?.login;
    if (walletLogin != null && walletLogin.isNotEmpty) return walletLogin;
    return _accountLogin;
  }

  String? _accountLogin;

  /// The wallet account's display name (the wire's `name`); null when no
  /// OAuth account is stored.
  String? get accountDisplayName {
    final account = _wallet.account;
    if (account == null) return null;
    if (account.displayName.isNotEmpty) return account.displayName;
    return account.login.isNotEmpty ? account.login : null;
  }

  /// True when a stored account's tokens have expired beyond refresh
  /// (or the silent refresh failed): the UI keeps the account row and
  /// marks the session expired instead of hiding it.
  bool get sessionExpired => _sessionExpired;
  bool _sessionExpired = false;

  /// The OAuth providers the server has configured
  /// (`GET /api/oauth-proxy/providers`) — the sign-in dialog falls back
  /// to the known four when this fails.
  Future<List<String>> oauthProviders() => _newClient().oauthProviders();

  /// Signs in through the real ai-native.cloud OAuth flow for [provider]
  /// (issue #955 iteration 3): initiate → browser → loopback callback →
  /// exchange, then fetches the profile, persists the account + tokens
  /// into the wallet, and holds the access token as the JWT.
  Future<void> signInWithProvider(
    String provider, {
    String clientType = 'desktop',
    String environment = 'prod',
  }) async {
    final client = _newClient();
    final tokens = await NetworkAuthFlow(client: client).signIn(
      provider: provider,
      clientType: clientType,
      environment: environment,
      startReceiver: _startReceiver,
      openUrl: _openUrl,
    );
    // The profile call is best-effort: the tokens alone are a working
    // sign-in; the sidebar just falls back to the provider name.
    AuthProfile? profile;
    try {
      profile = await client.authUser(tokens.accessToken);
    } on Object {
      profile = null;
    }
    await _wallet.saveAccount(
      WalletAccount(
        provider: provider,
        login: profile?.email ?? '',
        displayName: profile?.name ?? '',
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        accessExpiresAt: tokens.expiresAt,
        refreshExpiresAt: tokens.refreshExpiresAt,
      ),
    );
    _jwt = tokens.accessToken;
    _sessionExpired = false;
    notifyListeners();
  }

  /// Restores the wallet account on app start/resume: an unexpired
  /// access token becomes the JWT directly; an expired one is refreshed
  /// silently via `POST /api/auth/refresh`. A refresh failure (or a dead
  /// refresh token) leaves the account in the wallet but flips
  /// [sessionExpired] — the sidebar keeps showing the account with a
  /// "session expired" note instead of dropping it.
  Future<void> restoreAccount() async {
    final account = _wallet.account;
    if (account == null) return;
    final now = _clock().toUtc();
    if (account.accessExpiresAt.isAfter(now)) {
      _jwt = account.accessToken;
      _sessionExpired = false;
      AppLog.i(
        'fa_network',
        'account restored from wallet (access token fresh)',
      );
      notifyListeners();
      return;
    }
    final refreshExpiry = account.refreshExpiresAt;
    if (refreshExpiry != null && !refreshExpiry.isAfter(now)) {
      _sessionExpired = true;
      notifyListeners();
      return;
    }
    try {
      final tokens = await _newClient().refreshTokens(
        account.refreshToken,
        now: _clock(),
      );
      await _wallet.saveAccount(account.withTokens(tokens));
      _jwt = tokens.accessToken;
      _sessionExpired = false;
      AppLog.i('fa_network', 'account restored via refresh');
    } on Object catch (e) {
      _sessionExpired = true;
      AppLog.i('fa_network', 'account refresh FAILED: $e');
    }
    notifyListeners();
  }

  /// Signs in with the network account: `POST /api/dev/login` (the dev
  /// mock while the OAuth flow is pending) and holds the returned JWT in
  /// memory. Throws [FaNetworkException] with the server's message on
  /// failure; the JWT is left untouched.
  Future<void> signIn({required String login, required String password}) async {
    final token = await FaNetworkClient(
      baseUrl: _baseUrl,
      authBaseUrl: _authBaseUrl,
      httpClient: _http,
    ).devLogin(login: login, password: password);
    _jwt = token;
    _accountLogin = login;
    _sessionExpired = false;
    notifyListeners();
  }

  /// Drops the JWT and the stored wallet account (live member sessions
  /// keep their own session tokens — this only loses the management
  /// affordances).
  Future<void> signOut() async {
    _jwt = null;
    _accountLogin = null;
    _sessionExpired = false;
    await _wallet.clearAccount();
    notifyListeners();
  }

  /// The public-networks directory (`GET /api/networks/public`); null
  /// when the endpoint errors/rate-limits — the sidebar hides the
  /// section then.
  Future<({List<PublicNetworkInfo> items, String? nextCursor})?>
  listPublicNetworks({int? limit, String? cursor}) =>
      _newClient().listPublicNetworks(limit: limit, cursor: cursor);

  /// Re-reads wallet-driven UI after an out-of-band wallet mutation
  /// (e.g. a wallet import replacing the contents in place).
  void walletExternallyUpdated() => notifyListeners();

  /// Ensures the wallet identity exists (the join sheet pre-creates it
  /// with the human's chosen display name; [join] itself also creates it
  /// lazily from the join display name, and a send on an identity-less
  /// wallet creates it silently — there is no onboarding gate).
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
    // Identity is lazy (no onboarding gate): the join's display name
    // seeds the device identity when the wallet has none yet.
    if (!_wallet.hasIdentity) {
      await _wallet.createIfMissing(displayName: displayName ?? '');
    }
    final client = _newClient();
    AppLog.i(
      'fa_network',
      'join $networkId (jwt=${_jwt != null}, displayName=${displayName ?? "-"})',
    );
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
    AppLog.i(
      'fa_network',
      'join $networkId OK as ${result.identity.memberClass.name} '
          '"${result.identity.displayName}"',
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

  FaNetworkClient _newClient() => FaNetworkClient(
    baseUrl: _baseUrl,
    authBaseUrl: _authBaseUrl,
    httpClient: _http,
    jwtToken: _jwt,
  );

  /// Creates a network (management route — requires a JWT); the caller
  /// becomes owner and is joined immediately with the one-time join
  /// credentials. When [isPublic] the network is then listed in the
  /// public directory (PATCH, owner privilege). Returns the live session.
  Future<NetworkSession> createNetwork({
    required String name,
    required String password,
    bool isPublic = false,
  }) async {
    final client = _newClient()..session = _sessionToken;
    final result = await client.createNetwork(name: name, password: password);
    final networkId = result.network.id;
    if (isPublic) {
      await client.updateNetwork(networkId, isPublic: true);
    }
    return join(
      networkId: networkId,
      password: result.joinCredentials?.password ?? password,
    );
  }

  /// Deletes the network (management route — owner JWT required; the
  /// server's 403 surfaces for non-owners), then drops the local session,
  /// wallet membership and channel keys.
  Future<void> deleteNetwork(String networkId) async {
    await _newClient().deleteNetwork(networkId);
    final session = sessions.remove(networkId);
    if (session != null) await session.close();
    await _wallet.removeNetwork(networkId);
    notifyListeners();
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
