// Part of hub.dart — hello handshake, enrollment, bearer matching.
//
// Port of the Go auth.go (handleHello/checkHello/welcome) and enroll.go
// (wsAuth/matchBearer/handleEnroll + the secrets file).

part of 'hub.dart';

/// Issued secrets: 32 random bytes, base64url raw (no padding).
const _secretBytes = 32;

/// Bearer/enrollment operations the transport binding needs.
extension DapHubAuthApi on DapHub {
  /// Classifies an upgrade token: master secret (enrollment-capable),
  /// an issued agent secret (bound to its enrolled name), or null.
  DapBearerMatch? matchBearer(String token) {
    if (_isMaster(token)) {
      return (kind: DapAuthKind.master, boundName: '');
    }
    final name = _agentForSecret(token);
    if (name != null) {
      return (kind: DapAuthKind.agent, boundName: name);
    }
    return null;
  }

  bool _isMaster(String token) =>
      token.isNotEmpty &&
      _config.masterSecret.isNotEmpty &&
      constEq(token, _config.masterSecret);

  String? _agentForSecret(String token) {
    if (token.isEmpty) return null;
    final want = sha256Hex(token);
    for (final entry in secrets.entries) {
      if (constEq(entry.value, want)) return entry.key;
    }
    return null;
  }

  /// Authenticates the first frame on a connection (port of handleHello).
  Future<void> _handleHello(ClientSession session, DapFrame frame) async {
    _log('hello agent=${_logAgent(session)} name=${frame.name}');
    if (session.authed) {
      _sendErr(session, DapCodes.badFrame, 'already authenticated');
      return;
    }
    final failure = await _checkHello(session, frame);
    if (failure != null) {
      await _reject(session, failure.code, failure.message);
      return;
    }
    _welcome(session, frame);
  }

  /// The full auth gauntlet: nonce, signature, timestamp, replay.
  Future<DapProtoError?> _checkHello(
    ClientSession session,
    DapFrame frame,
  ) async {
    if (frame.nonce.length < nonceMinLength) {
      return const DapProtoError(DapCodes.badFrame, 'nonce too short');
    }
    final sigError = await verifySignature(frame, frame.pubkey);
    if (sigError != null) return sigError;
    if (!tsFresh(frame.ts, _now)) {
      return const DapProtoError(
        DapCodes.staleTs,
        'timestamp outside ±300s window',
      );
    }
    if (!_nonces.check(frame.pubkey, frame.nonce, _now)) {
      return const DapProtoError(
        DapCodes.replayedNonce,
        'nonce already used',
      );
    }
    return null;
  }

  /// Installs the authenticated client (port of welcome). An issued
  /// client secret only authenticates its enrolled name.
  void _welcome(ClientSession session, DapFrame frame) {
    if (session.authKind == DapAuthKind.agent &&
        frame.name != session.boundName) {
      unawaited(
        _reject(
          session,
          DapCodes.accessDenied,
          'hello name does not match the enrolled secret',
        ),
      );
      return;
    }
    session
      ..agentId = agentIdFor(base64.decode(frame.pubkey))
      ..pubkey = frame.pubkey
      ..x25519 = frame.x25519
      ..name = frame.name
      ..authed = true;
    _register(session);
    session.sendFrame({'op': 'welcome', 'agentId': session.agentId});
  }

  /// Issues a fresh client secret bound to the hello name and persists
  /// its hash (port of handleEnroll). Dispatch guarantees hello already
  /// completed; the master check is the enrollment gate. Re-enrolling
  /// replaces the old secret, which then fails every new dial.
  void _handleEnroll(ClientSession session) {
    if (session.authKind != DapAuthKind.master) {
      _sendErr(
        session,
        DapCodes.accessDenied,
        'enroll requires the hub master secret',
      );
      return;
    }
    final raw = List<int>.generate(_secretBytes, (_) => _random.nextInt(256));
    final secret = base64Url.encode(raw).replaceAll('=', '');
    secrets[session.name] = sha256Hex(secret);
    _persistSecrets();
    _log('enroll agent=${_logAgent(session)} name=${session.name}');
    session.sendFrame({'t': 'enrolled', 'secret': secret});
  }

  /// Restores issued secret hashes. A missing/corrupt file is not an
  /// error (first boot).
  Future<void> _loadSecrets() async {
    final text = await _config.secretStore.read();
    if (text == null) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      _log('store: parse secrets failed');
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final list = decoded['secrets'];
    if (list is! List) return;
    for (final record in list) {
      final entry = _secretEntry(record);
      if (entry != null) secrets[entry.$1] = entry.$2;
    }
  }

  /// One well-formed `{name, hash}` record, or null.
  (String, String)? _secretEntry(Object? record) {
    if (record is Map && record['name'] is String && record['hash'] is String) {
      return (record['name'] as String, record['hash'] as String);
    }
    return null;
  }

  /// Persists the secrets file (hashes only), fire-and-forget.
  void _persistSecrets() {
    final records = [
      for (final entry in secrets.entries)
        {'name': entry.key, 'hash': entry.value},
    ];
    unawaited(
      _config.secretStore
          .write(jsonEncode({'secrets': records}))
          .catchError((Object e) => _log('store: write secrets failed: $e')),
    );
  }
}
