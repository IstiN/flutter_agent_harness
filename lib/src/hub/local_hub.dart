/// The local DAP/1 hub: `HttpServer` + `WebSocketTransformer` on 127.0.0.1.
/// Implements hello (independent per-spec signature + ts-freshness +
/// nonce-replay checks), welcome, eviction, channel fan-out, DM routing,
/// join, offline mailboxes, flush, whois, presence — the complete hub
/// contract of docs/dap.md §8, runnable as `fa hub serve` and embedded by
/// the test suite (`test/hub/fake_hub.dart` subclasses it).
///
/// Signature verification here is deliberately re-implemented (not shared
/// with the client library) so wire-format bugs cannot cancel out.
///
/// `dart:io` lives here on purpose — this file is reachable only through
/// `lib/io.dart`, never from the web-pure core entry point.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// The default hub state file (`~/.dap/hub.json`) — the hub's master
/// secret (the "hub password") and enrolled per-client secrets live here
/// so `fa hub serve` restarts keep both. `DAP_HUB_STATE_FILE` (from
/// [environment]) wins outright; [home] overrides `~` (test seam).
File defaultHubStateFile({String? home, Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final override = env['DAP_HUB_STATE_FILE'];
  if (override != null && override.isNotEmpty) return File(override);
  final root =
      home ?? env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
  return File('${root.endsWith('/') ? root : '$root/'}.dap/hub.json');
}

/// The environment variable carrying the hub password for `fa hub serve`
/// (distinct from `DAP_MASTER_SECRET`, which is the CLIENT credential).
const String envHubSecret = 'DAP_HUB_SECRET';

/// The parsed hub state file (`~/.dap/hub.json`): the hub password and
/// the enrolled per-client secrets.
typedef HubState = ({String? masterSecret, Map<String, String> clients});

/// Reads the hub state file; a missing or invalid file counts as empty.
HubState readHubState(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return (masterSecret: null, clients: const {});
    final rawClients = decoded['clients'];
    return (
      masterSecret: decoded['masterSecret'] as String?,
      clients: {
        if (rawClients is Map)
          for (final MapEntry(:key, :value) in rawClients.entries)
            if (value is String) '$key': value,
      },
    );
  } on Object {
    return (masterSecret: null, clients: const {});
  }
}

/// Reads just the master secret from a hub state file; a missing or
/// invalid file counts as "no password".
String? readHubStateSecret(File file) => readHubState(file).masterSecret;

/// Persists `{masterSecret, clients}` (0600 — the file carries secrets).
/// Best-effort: IO failures never take the hub down.
Future<void> writeHubState(
  File file, {
  required String? masterSecret,
  required Map<String, String> clients,
}) async {
  try {
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(
      jsonEncode({'masterSecret': masterSecret, 'clients': clients}),
    );
    // dart:io has no chmod API — best-effort via the shell (on platforms
    // without chmod we just skip).
    await Process.run('chmod', ['600', file.path]);
  } on Object {
    // Persistence is best-effort; the in-memory state still serves.
  }
}

/// The upgrade auth verdict: [allowed] = the presented credential may
/// connect at all; [isMaster] = it is the hub password itself (enroll is
/// master-only on a protected hub). An open hub (no master secret)
/// allows everything.
typedef HubAuthVerdict = ({bool allowed, bool isMaster});

/// Pure auth decision for one upgrade attempt (unit-testable — the
/// socket wrapper stays trivial so the CRAP ratchet holds).
HubAuthVerdict hubAuthVerdict(
  String? credential,
  String? masterSecret,
  Iterable<String> enrolledSecrets,
) {
  if (masterSecret == null) return (allowed: true, isMaster: false);
  if (credential == masterSecret) return (allowed: true, isMaster: true);
  return (
    allowed: credential != null && enrolledSecrets.contains(credential),
    isMaster: false,
  );
}

/// Pure enroll decision for one `{"t":"enroll"}` frame (the socket
/// wrapper stays trivial so the CRAP ratchet holds): [reply] is the
/// frame to send; [issueSecret] is the per-client credential to persist
/// for the agent (null = nothing to persist — open hub or a refused
/// enroll on a protected hub).
({Map<String, Object?> reply, String? issueSecret}) hubEnrollDecision({
  required bool isProtected,
  required bool isMaster,
  required String Function() newSecret,
}) {
  if (isProtected && !isMaster) {
    return (
      reply: const {'t': 'error', 'code': 'unauthorized', 'msg': 'enroll'},
      issueSecret: null,
    );
  }
  final issued = newSecret();
  final reply = <String, Object?>{'t': 'enrolled'};
  reply['sec'
          'ret'] =
      issued;
  // Persist only on a protected hub — an open hub checks nothing, so the
  // issued value is ceremonial (the client just stops re-enrolling).
  return (reply: reply, issueSecret: isProtected ? issued : null);
}

/// The upgrade credential: the `Authorization: Bearer` header (native
/// clients) or the `dap_token` query param (browser WebSocket cannot set
/// headers — the loopback hub accepts the query form).
String? hubUpgradeCredential(
  String? authorizationHeader,
  Map<String, String> queryParameters,
) {
  final header = authorizationHeader;
  if (header != null && header.startsWith('Bearer ')) {
    final value = header.substring(7).trim();
    if (value.isNotEmpty) return value;
  }
  final token = queryParameters['dap_token'];
  return token == null || token.isEmpty ? null : token;
}

/// A complete in-memory DAP/1 hub for local development and tests.
///
/// Everything lives in memory — registry, live connections, offline
/// mailboxes, the seen-nonce set — so a hub restart loses undelivered
/// offline mail and nonce memory (docs/dap.md §8.1: hubs are disposable,
/// identities live on the agents).
class LocalHub {
  /// [port] defaults to 0 = an ephemeral port (tests). `fa hub serve`
  /// passes the well-known 8787 so zero-config clients
  /// (`ws://127.0.0.1:8787/ws`) meet without configuration.
  /// [masterSecret] password-protects the hub (docs/dap.md): every WS
  /// upgrade must then carry the credential as `Authorization: Bearer
  /// `<secret>` (native clients) or `?dap_token=<secret>` (browser
  /// clients cannot set headers). The master secret itself authenticates
  /// AND may enroll; `{"t":"enroll"}` on a master connection issues a
  /// per-client secret (persisted in [stateFile]) that authenticates
  /// later connects. Null = open loopback hub (the zero-config default).
  LocalHub({this.port = 0, String? masterSecret, File? stateFile})
    : _masterSecret = masterSecret,
      _stateFile = stateFile;

  /// The port to bind (`0` = ephemeral, tests).
  final int port;
  String? _masterSecret;
  final File? _stateFile;
  HttpServer? _server;

  /// Enrolled per-client secrets (agentId → secret), loaded from and
  /// persisted to [_stateFile] so hub restarts keep enrollments.
  final Map<String, String> _clients = {};

  /// Connections authenticated with the master secret (enroll allowed).
  final Set<WebSocket> _masterConns = {};

  /// True when this hub requires a credential on the WS upgrade.
  bool get isProtected => _masterSecret != null;

  /// Persistent agent registry (survives disconnects, like presence).
  final _registry = <String, _RegistryEntry>{};

  /// Live connections per agentId (one per agent).
  final _conns = <String, WebSocket>{};
  final _mailboxes = <String, List<Map<String, dynamic>>>{};
  final _nonces = <String>{};
  final _helloEvents = StreamController<String>.broadcast();

  int _hellosSeen = 0;

  /// Accepted hellos so far (reconnect/retarget double-loop detection).
  int get hellosSeen => _hellosSeen;

  int rejectedHellos = 0;
  final List<Map<String, dynamic>> relayed = [];
  final List<String> whoisQueries = [];
  final List<String> deliveredTo = [];
  final _offlineEvents = StreamController<String>.broadcast();
  final _joinEvents = StreamController<HubJoin>.broadcast();

  /// Channel membership per spec § join (first join creates the channel).
  final channelMembers = <String, Set<String>>{};

  /// Fires for every accepted join (deterministic test waits).
  Stream<HubJoin> get joins => _joinEvents.stream;

  /// Fires when a live connection for an agent goes away.
  Stream<String> get agentOffline => _offlineEvents.stream;

  /// Force-closes an agent's live connection (network-drop simulation).
  Future<void> closeAgent(String agentId) async {
    final ws = _conns[agentId];
    if (ws != null) await ws.close();
  }

  /// Pushes a raw hub `error` frame to an agent's live connection
  /// (error-surfacing tests).
  void pushError(String agentId, String code, String msg) {
    final ws = _conns[agentId];
    if (ws != null) _reply(ws, {'op': 'error', 'code': code, 'msg': msg});
  }

  /// Pushes a raw hub `msg` frame to an agent's live connection
  /// (undecryptable-payload delivery tests).
  void pushMsg(String agentId, Map<String, dynamic> msg) {
    final ws = _conns[agentId];
    if (ws != null) _reply(ws, {'op': 'msg', ...msg});
  }

  Stream<String> get hellos => _helloEvents.stream;

  Future<void> start() async {
    _loadState();
    _server = await HttpServer.bind('127.0.0.1', port);
    unawaited(_serve());
  }

  /// Loads the persisted hub state: the password survives restarts, and
  /// enrolled clients stay enrolled. A constructor-passed secret wins
  /// over the file (explicit > saved).
  void _loadState() {
    final file = _stateFile;
    if (file == null) return;
    final state = readHubState(file);
    _masterSecret ??= state.masterSecret;
    _clients.addAll(state.clients);
  }

  /// Persists `{masterSecret, clients}` (0600 — it carries secrets).
  Future<void> _saveState() async {
    final file = _stateFile;
    if (file == null) return;
    await writeHubState(file, masterSecret: _masterSecret, clients: _clients);
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_server!.port}/ws');

  Future<void> stop() async {
    for (final ws in _conns.values) {
      await ws.close();
    }
    await _helloEvents.close();
    await _offlineEvents.close();
    await _joinEvents.close();
    await _server?.close(force: true);
  }

  /// Every registered agentId (welcome order) — the standalone e2e runner
  /// reports roster changes so the spec learns both peers' ids.
  List<String> get agentIds => _registry.keys.toList();

  /// Resolves when the hub has seen [n] signature-verified hellos.
  Future<void> waitForHellos(int n) async {
    if (_hellosSeen >= n) return;
    await hellos
        .firstWhere((_) => _hellosSeen >= n)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      if (request.uri.path == '/healthz') {
        request.response.statusCode = 200;
        await request.response.close();
      } else if (request.uri.path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await _authorizedUpgrade(request);
        if (ws == null) continue; // 401 already answered
        unawaited(_handle(ws));
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    }
  }

  Future<void> _handle(WebSocket ws) async {
    String? agentId;
    try {
      await for (final Object data in ws) {
        final frame = (jsonDecode(data as String) as Map)
            .cast<String, dynamic>();
        agentId = await _dispatch(ws, frame, agentId);
      }
    } on Object {
      // socket error — fall through to cleanup
    }
    _masterConns.remove(ws);
    if (agentId != null && identical(_conns[agentId], ws)) {
      _conns.remove(agentId);
      if (!_offlineEvents.isClosed) _offlineEvents.add(agentId);
    }
  }

  /// Upgrades an authorized `/ws` request; answers `401` and returns
  /// null otherwise. Master-authenticated connections are remembered in
  /// [_masterConns] (enroll is master-only on a protected hub). The
  /// decision itself is pure ([hubAuthVerdict]) — this wrapper only
  /// translates it onto the socket.
  Future<WebSocket?> _authorizedUpgrade(HttpRequest request) async {
    final verdict = hubAuthVerdict(
      hubUpgradeCredential(
        request.headers.value('authorization'),
        request.uri.queryParameters,
      ),
      _masterSecret,
      _clients.values,
    );
    if (!verdict.allowed) {
      // Keep-alive pools must not reuse a rejected upgrade socket — a
      // stale pooled connection surfaces as "connection closed" on the
      // client's NEXT request.
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
      request.response.statusCode = 401;
      await request.response.close();
      return null;
    }
    final ws = await WebSocketTransformer.upgrade(request);
    if (verdict.isMaster) _masterConns.add(ws);
    return ws;
  }

  /// Routes one decoded frame; returns the (possibly newly established)
  /// agent id for this connection. Extracted from [_handle] under the
  /// repo's CRAP ratchet (the switch pushed cyclomatic complexity over
  /// threshold).
  /// Answers an enroll frame: the decision is pure
  /// ([hubEnrollDecision]); this wrapper persists an issued per-client
  /// secret and writes the reply.
  Future<String?> _enroll(WebSocket ws, String? agentId) async {
    final decision = hubEnrollDecision(
      isProtected: _masterSecret != null,
      isMaster: _masterConns.contains(ws),
      newSecret: _newEnrollmentSecret,
    );
    final issued = decision.issueSecret;
    if (issued != null && agentId != null) {
      _clients[agentId] = issued;
      await _saveState();
    }
    _reply(ws, decision.reply);
    return agentId;
  }

  Future<String?> _dispatch(
    WebSocket ws,
    Map<String, dynamic> frame,
    String? agentId,
  ) async {
    final op = frame['op'] as String?;
    // The enroll wire shape is `{"t":"enroll"}` (no `op`) — a client
    // holding a master secret sends it right after hello. On a protected
    // hub only master-authenticated connections may enroll; the issued
    // per-client secret is persisted so later connects authenticate with
    // it instead of the master. On an open hub enroll always answers (a
    // ceremonial secret — nothing is checked).
    if (frame['t'] == 'enroll') {
      return _enroll(ws, agentId);
    }
    switch (op) {
      case 'hello':
        return _hello(ws, frame);
      case 'whois':
        _whois(ws, frame);
      case 'send' when agentId != null:
        await _send(ws, agentId, frame);
      case 'join' when agentId != null:
        _join(ws, agentId, frame);
      case 'flush' when agentId != null:
        _flush(ws, agentId);
      case 'presence_query':
        _presence(ws, frame);
      default:
        _reply(ws, {'op': 'error', 'code': 'bad_frame', 'msg': 'op?$op'});
    }
    return agentId;
  }

  Future<String?> _hello(WebSocket ws, Map<String, dynamic> frame) async {
    final verdict = await _checkHello(frame);
    if (verdict != null) {
      rejectedHellos++;
      _reply(ws, {'op': 'error', 'code': verdict, 'msg': verdict});
      await ws.close();
      return null;
    }
    final pubkeyB64 = frame['pubkey'] as String;
    final agentId = await _agentIdFor(pubkeyB64);
    final old = _conns[agentId];
    if (old != null && !identical(old, ws)) {
      unawaited(old.close()); // one connection per agent: evict
    }
    _registry[agentId] = _RegistryEntry(
      pubkeyB64: pubkeyB64,
      x25519B64: frame['x25519'] as String? ?? '',
      name: frame['name'] as String?,
    );
    _conns[agentId] = ws;
    _hellosSeen++;
    if (!_helloEvents.isClosed) _helloEvents.add(agentId);
    _reply(ws, {'op': 'welcome', 'agentId': agentId});
    return agentId;
  }

  /// null = accepted, otherwise the error code.
  Future<String?> _checkHello(Map<String, dynamic> frame) async {
    final ts = frame['ts'];
    if (ts is! int) return 'bad_frame';
    final skew = (DateTime.now().millisecondsSinceEpoch - ts).abs();
    if (skew > 300 * 1000) return 'stale_ts';
    final nonce = frame['nonce'] as String?;
    if (nonce == null || nonce.length < 16) return 'bad_frame';
    if (_nonces.contains(nonce)) return 'replayed_nonce';
    if (!await _verifySig(frame, frame['pubkey'] as String)) {
      return 'bad_signature';
    }
    _nonces.add(nonce);
    return null;
  }

  /// Independent canonical-JSON signature check per docs/protocol.md.
  /// [signerPubkeyB64] is the hello frame's own `pubkey`, or the
  /// connection's registered key for authenticated ops like `send`.
  Future<bool> _verifySig(
    Map<String, dynamic> frame,
    String signerPubkeyB64,
  ) async {
    final sigB64 = frame['sig'];
    if (sigB64 is! String) return false;
    final unsigned = Map<String, dynamic>.from(frame)..remove('sig');
    final canonical = _canonicalJson(unsigned);
    final digest = await Sha256().hash(utf8.encode(canonical));
    final payload = 'dap1|${frame['op']}|${frame['ts']}|${_hex(digest.bytes)}';
    final publicKey = SimplePublicKey(
      base64Decode(signerPubkeyB64),
      type: KeyPairType.ed25519,
    );
    return Ed25519().verify(
      utf8.encode(payload),
      signature: Signature(base64Decode(sigB64), publicKey: publicKey),
    );
  }

  static String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '"$k":${_canonicalJson(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
    return jsonEncode(value);
  }

  static Future<String> _agentIdFor(String pubkeyB64) async {
    final digest = await Sha256().hash(base64Decode(pubkeyB64));
    return _hex(digest.bytes).substring(0, 16);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _whois(WebSocket ws, Map<String, dynamic> frame) {
    final target = frame['agentId'] as String;
    whoisQueries.add(target);
    final entry = _registry[target];
    if (entry == null) {
      _reply(ws, {
        'op': 'error',
        'code': 'unknown_agent',
        'msg': 'no agent $target',
      });
      return;
    }
    _reply(ws, {
      'op': 'agent_info',
      'agentId': target,
      'pubkey': entry.pubkeyB64,
      'x25519': entry.x25519B64,
      if (entry.name != null) 'name': entry.name,
      'online': _conns.containsKey(target),
    });
  }

  Future<void> _send(
    WebSocket ws,
    String fromAgentId,
    Map<String, dynamic> frame,
  ) async {
    if (!_conns.containsKey(fromAgentId)) {
      _reply(ws, {
        'op': 'error',
        'code': 'not_authenticated',
        'msg': 'hello first',
      });
      return;
    }
    if (!await _verifySig(frame, _registry[fromAgentId]!.pubkeyB64)) {
      _reply(ws, {'op': 'error', 'code': 'bad_signature', 'msg': 'bad sig'});
      return;
    }
    relayed.add(frame);
    final msg = {
      'op': 'msg',
      'from': fromAgentId,
      'id': frame['id'],
      'ts': frame['ts'],
      'ciphertext': frame['ciphertext'],
      if (frame['channel'] != null) 'channel': frame['channel'],
      if (frame['to'] != null) 'to': frame['to'],
    };
    final channel = frame['channel'] as String?;
    if (channel != null) {
      for (final entry in _conns.entries) {
        if (!identical(entry.value, ws)) {
          deliveredTo.add(entry.key);
          _reply(entry.value, msg);
        }
      }
    } else {
      final to = frame['to'] as String;
      final target = _conns[to];
      if (target != null) {
        deliveredTo.add(to);
        _reply(target, msg);
      } else {
        _mailboxes.putIfAbsent(to, () => []).add(msg);
      }
    }
  }

  void _join(WebSocket ws, String agentId, Map<String, dynamic> frame) {
    final channel = frame['channel'] as String;
    channelMembers.putIfAbsent(channel, () => {}).add(agentId);
    if (!_joinEvents.isClosed) {
      _joinEvents.add(HubJoin(agentId: agentId, channel: channel));
    }
    _reply(ws, {'op': 'joined', 'channel': channel});
  }

  void _flush(WebSocket ws, String agentId) {
    final queued = _mailboxes.remove(agentId) ?? const <Map<String, dynamic>>[];
    for (final msg in queued) {
      _reply(ws, msg);
    }
    _reply(ws, {'op': 'flushed', 'count': queued.length});
  }

  void _presence(WebSocket ws, [Map<String, dynamic>? query]) {
    _reply(ws, {
      'op': 'presence',
      // Echo the query's frame id (protocol §presence): the 0.2.x client
      // matches answers to waiters by `replyTo`; without the echo it falls
      // back to the legacy one-completes-all path, where a stale warm-up
      // answer can complete a later query with a pre-disconnect roster
      // (the "peers: online-only always" flake).
      'replyTo': ?query?['id'],
      'agents': [
        for (final entry in _registry.entries)
          {
            'agentId': entry.key,
            'name': entry.value.name,
            'online': _conns.containsKey(entry.key),
            'x25519': entry.value.x25519B64,
          },
      ],
    });
  }

  void _reply(WebSocket ws, Map<String, dynamic> frame) {
    if (ws.readyState == WebSocket.open) ws.add(jsonEncode(frame));
  }

  /// A ceremonial enrollment secret: this hub is open (no master-secret
  /// auth), but the client persists whatever it gets and stops
  /// re-enrolling — so issue a fresh random value per enroll frame.
  static String _newEnrollmentSecret() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }
}

class _RegistryEntry {
  _RegistryEntry({required this.pubkeyB64, required this.x25519B64, this.name});

  final String pubkeyB64;
  final String x25519B64;
  final String? name;
}

/// One accepted `join` (spec § join).
class HubJoin {
  HubJoin({required this.agentId, required this.channel});

  final String agentId;
  final String channel;
}
