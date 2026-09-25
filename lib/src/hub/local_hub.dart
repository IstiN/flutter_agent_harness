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
import 'dart:typed_data';

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

/// Default bind-retry budget for [LocalHub.start] (gh-936): five attempts
/// spanning ~1.5 s of backoff ride out a port held by a dying process
/// (a cancelled run's hub between close and exit) without turning the
/// start into a hard failure.
const int hubBindMaxAttempts = 5;

/// The base wait of the bind-retry backoff — doubled every attempt
/// (100, 200, 400, 800 ms over the default five attempts).
const Duration hubBindBackoffBase = Duration(milliseconds: 100);

/// Binds an HTTP server with [shared] semantics (gh-936), retrying with
/// exponential backoff while the port is held by SOMETHING ELSE.
///
/// Why `shared: true` by default: two overlapping runs of the same suite
/// (a cancelled CI dispatch and its successor, two local test legs) both
/// reach for the same fixed/allocated loopback port, and without
/// SO_REUSEPORT the loser hard-fails with "Shared flag to bind() needs
/// to be true if binding multiple times" — the failure that red four
/// PTY legs in one night (gh-936). A shared bind makes overlapping hubs
/// coexist; the `fa hub serve` idempotence probe (healthz before bind)
/// keeps the ordinary double-start calm, so the residual split-bind
/// window (two SIMULTANEOUS starts) degrades instead of crashing.
/// Callers that need an exclusive bind pass `shared: false` — the retry
/// then still absorbs transient holders before surfacing the failure.
Future<HttpServer> bindHttpServerWithRetry(
  InternetAddress address,
  int port, {
  required bool shared,
  int attempts = hubBindMaxAttempts,
  Duration backoff = hubBindBackoffBase,
}) async {
  assert(attempts >= 1, 'attempts must be at least 1');
  SocketException? lastError;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await HttpServer.bind(address, port, shared: shared);
    } on SocketException catch (error) {
      lastError = error;
      if (attempt < attempts) {
        await Future<void>.delayed(backoff * attempt);
      }
    }
  }
  throw lastError!;
}

/// Monotonic per-process write counter for [writeHubState]'s unique
/// temp names.
int _hubStateWriteSeq = 0;

/// Persists `{masterSecret, clients}` (0600 — the file carries secrets).
/// Best-effort: IO failures never take the hub down.
///
/// Temp + chmod + rename: the file must never be world-readable for
/// even a moment, and content-first/chmod-second on the live path
/// leaves exactly that window while `hub.json` carries the master
/// secret (issue #794 review).
Future<void> writeHubState(
  File file, {
  required String? masterSecret,
  required Map<String, String> clients,
}) async {
  try {
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    // Unique temp name: two overlapping writes must not race one
    // shared .tmp (A renames it away; B's rename then throws and its
    // enrollment is silently lost — issue #794 review round 5). The
    // write counter keeps same-microsecond writes apart; microseconds
    // keep restarts apart.
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}'
      '.${_hubStateWriteSeq++}.tmp',
    );
    await tmp.writeAsString(
      jsonEncode({'masterSecret': masterSecret, 'clients': clients}),
      flush: true,
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', tmp.path]);
    }
    await tmp.rename(file.path);
  } on Object {
    // Persistence is best-effort; the in-memory state still serves.
    // (A leftover uniquely-named .tmp from a crashed write is never
    // read — harmless.)
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
  LocalHub({
    this.port = 0,
    this.bind = 'loopback',
    this._masterSecret,
    this._stateFile,
    this.bindMaxAttempts = hubBindMaxAttempts,
    this.bindBackoff = hubBindBackoffBase,
    this.relayAllowAnyHost = false,
    this.relayConcurrency = 4,
    this.relayQueueLimit = 32,
    this.relayMaxBodyBytes = relayDefaultMaxBodyBytes,
    this.relayConnectTimeout = relayDefaultConnectTimeout,
    this.relayIdleTimeout = relayDefaultIdleTimeout,
  }) : assert(
         bindMaxAttempts >= 1,
         'bindMaxAttempts must be at least 1',
       ),
       assert(
         bindBackoff > Duration.zero,
         'bindBackoff must be positive',
       ),
       assert(
         relayConcurrency > 0,
         'relayConcurrency must be positive — 0 wedges the pool forever',
       ),
       assert(relayQueueLimit >= 0, 'relayQueueLimit must not be negative'),
       assert(relayMaxBodyBytes > 0, 'relayMaxBodyBytes must be positive'),
       assert(
         relayConnectTimeout > Duration.zero,
         'relayConnectTimeout must be positive',
       ),
       assert(
         relayIdleTimeout > Duration.zero,
         'relayIdleTimeout must be positive',
       );

  /// The port to bind (`0` = ephemeral, tests).
  final int port;

  /// Bind-retry budget (gh-936): a port held by a DYING process (a
  /// cancelled run's hub still between close and exit, a TIME_WAIT
  /// lingerer) must not hard-fail the start — the bind retries
  /// [bindMaxAttempts] times with [bindBackoff] exponential backoff
  /// before giving up. Injected so tests can shrink the wait.
  final int bindMaxAttempts;

  /// The base wait of the bind-retry backoff (doubled every attempt).
  final Duration bindBackoff;

  /// Relay destination dev opt-in (issue #792 AC3): when true, the
  /// `/relay` destination allowlist is lifted so a development taskpane
  /// can reach a local mock provider. Off in production — a relay is a
  /// provider transport, not a general-purpose fetch tool.
  final bool relayAllowAnyHost;

  /// Bounded relay handling (issue #794): at most [relayConcurrency]
  /// relays run at once; overflow queues up to [relayQueueLimit] deep
  /// and answers 503 beyond that — backpressure, not OOM. A request
  /// body larger than [relayMaxBodyBytes] is a 413; the upstream leg
  /// gets a [relayConnectTimeout] and a per-chunk [relayIdleTimeout]
  /// (which also bounds a stalled client body). Defaults are modest.
  final int relayConcurrency;
  final int relayQueueLimit;
  final int relayMaxBodyBytes;
  final Duration relayConnectTimeout;
  final Duration relayIdleTimeout;

  /// Upstream requests aborted because the relay client went away
  /// mid-flight (cancel-on-disconnect, issue #794 AC3).
  int relayUpstreamAborts = 0;

  /// Relays currently holding a pool slot (tests observe backpressure
  /// and release through this).
  int get relayInFlight => _relayActive;

  /// Relays currently parked in the overflow queue (tests synchronize
  /// occupancy ladders on this instead of sleeping).
  int get relayQueueDepth => _relayWaiters.length;

  int _relaySeq = 0;
  int _relayActive = 0;
  final _relayWaiters = <Completer<bool>>[];

  /// The bearer credential `/relay` demands on every scope (issue #792):
  /// the master secret when one is configured, else an ephemeral per-serve
  /// secret ([relaySecret]) — fail-closed, never "null means skip".
  String? _relaySecret;

  /// The relay bearer the operator (or the taskpane) must present.
  /// Ephemeral when no master secret is configured; `fa hub serve` prints
  /// and persists it (pid state file) so clients can pair.
  String? get relaySecret => _relaySecret;

  /// The listener scope (issue #402 AC4): `'loopback'` (default) binds
  /// 127.0.0.1 only; `'lan'` binds all interfaces so LAN peers — the iOS
  /// app above all — can reach the hub. Off by default: a LAN-reachable
  /// hub is an explicit host decision.
  final String bind;
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
    _server = await bindHttpServerWithRetry(
      bind == 'lan' ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
      shared: true,
      attempts: bindMaxAttempts,
      backoff: bindBackoff,
    );
    // Issue #792: the relay authenticates on EVERY scope. A protected hub
    // demands its master secret; an open loopback hub still gets an
    // ephemeral per-serve secret — loopback is an address, not an auth
    // method (any local process can hit it).
    _relaySecret ??= _masterSecret ?? _newEnrollmentSecret();
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
    // A queued relay waits forever otherwise; the hub is going away, so
    // every waiter is released as dropped (issue #794 review).
    for (final waiter in _relayWaiters) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _relayWaiters.clear();
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
  /// [timeout] bounds the wait — the default 5s suits unit tests; PTY
  /// integration tests on loaded runners pass 30s (the CLI's dial
  /// rides a cold `dart` VM behind a TUI boot).
  Future<void> waitForHellos(
    int n, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_hellosSeen >= n) return;
    await hellos.firstWhere((_) => _hellosSeen >= n).timeout(timeout);
  }

  /// The accept loop NEVER awaits request work (issue #794): every
  /// request routes detached, so a slow relay, a hung upgrade, or a dead
  /// socket cannot delay the next accept. Per-request errors are
  /// contained here — one bad socket never kills the loop.
  Future<void> _serve() async {
    await for (final request in _server!) {
      unawaited(_route(request));
    }
  }

  Future<void> _route(HttpRequest request) async {
    try {
      if (request.uri.path == '/healthz') {
        request.response.statusCode = 200;
        await request.response.close();
      } else if (request.uri.path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await _authorizedUpgrade(request);
        if (ws == null) return; // 401 already answered
        unawaited(_handle(ws));
      } else if (request.uri.path == '/relay') {
        await _relayDispatch(request);
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } on Object catch (error) {
      // The socket died mid-handler — or a handler had a bug. Both stay
      // out of the serve loop, but a programming error must not vanish
      // without a trace in a long-lived daemon (issue #794 review).
      stderr.writeln(
        'hub: handler error on ${request.method} ${request.uri.path}: '
        '$error',
      );
      try {
        await request.response.close();
      } on Object {
        // Already gone.
      }
    }
  }

  /// The relay gate (issue #794): bounded concurrency with queue
  /// backpressure, a per-request run id on every response, and named
  /// limit errors logged with that id. The CHEAP verdicts (OPTIONS,
  /// bearer, origin) run BEFORE any pool slot is touched — unauthenticated
  /// garbage and browser preflights must not occupy workers or queue
  /// slots (issue #794 review).
  Future<void> _relayDispatch(HttpRequest request) async {
    final runId = 'relay-${++_relaySeq}';
    request.response.headers.set('x-fah-relay-id', runId);
    void log(String line) => stderr.writeln('hub [$runId]: $line');
    final origin = request.headers.value('origin');
    if (!await _relayGate(
      request,
      requireCredential: () => _relaySecret,
      origin: origin,
    )) {
      return; // answered (preflight / 401 / 403) without any slot cost
    }
    final slot = await _acquireRelaySlot(request);
    if (slot == _RelaySlot.refused) {
      log('relay worker queue full (${_relayWaiters.length} waiters) — 503');
      await _relayError(
        request,
        HttpStatus.serviceUnavailable,
        'relay busy — try again',
        bodyConsumed: false,
        relayAllowedOrigin(origin),
      );
      return;
    }
    if (slot == _RelaySlot.dropped) {
      // The slot was released without a worker: the client disconnected
      // while queued, or the hub is stopping (waiters completed false).
      // Nothing is left to answer — the log stays generic so a shutdown
      // does not read as phantom client churn (issue #794 review r5).
      log('queued relay dropped (client gone or hub stopping)');
      return;
    }
    try {
      await handleRelayBody(
        request,
        allowedOrigin: relayAllowedOrigin(origin),
        allowAnyHost: relayAllowAnyHost,
        limits: (
          maxBodyBytes: relayMaxBodyBytes,
          connectTimeout: relayConnectTimeout,
          idleTimeout: relayIdleTimeout,
        ),
        log: log,
        onUpstreamAbort: () => relayUpstreamAborts++,
      );
    } finally {
      _releaseRelaySlot();
    }
  }

  /// One relay slot: free slots go straight through; overflow queues
  /// ([_relayWaiters]); a full queue refuses (backpressure → 503). A
  /// client that disconnects while queued is dropped instead of being
  /// handed a worker later (issue #794 review) — `response.done` DOES
  /// complete for a client-gone socket.
  Future<_RelaySlot> _acquireRelaySlot(HttpRequest request) async {
    if (_relayWaiters.isEmpty && _relayActive < relayConcurrency) {
      _relayActive++;
      return _RelaySlot.granted;
    }
    if (_relayWaiters.length >= relayQueueLimit) return _RelaySlot.refused;
    final waiter = Completer<bool>();
    _relayWaiters.add(waiter);
    unawaited(
      request.response.done.whenComplete(() {
        if (!waiter.isCompleted) {
          _relayWaiters.remove(waiter);
          waiter.complete(false); // dropped — answer nothing
        }
      }),
    );
    return await waiter.future ? _RelaySlot.granted : _RelaySlot.dropped;
  }

  void _releaseRelaySlot() {
    if (_relayWaiters.isNotEmpty) {
      _relayWaiters.removeAt(0).complete(true);
    } else if (_relayActive > 0) {
      _relayActive--;
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

/// The CORS answer for a relay request's [origin]: the allowlisted taskpane
/// origins get their origin echoed back (never `*` — a hostile page must
/// not be able to read this proxy), anything else gets null (= no CORS
/// headers = the browser blocks the read).
// ponytail: exact fa1.dev + localhost dev; extend the list when the pane
// gains another production origin.
String? relayAllowedOrigin(String? origin) {
  if (origin == null) return null;
  final uri = Uri.tryParse(origin);
  final host = uri?.host ?? '';
  const allowedHosts = {'fa1.dev'};
  final localhost = host == 'localhost' || host.endsWith('.localhost');
  return (allowedHosts.contains(host) || localhost) ? origin : null;
}

/// Bounded relay handling knobs (issue #794). A host tunes them per hub;
/// defaults are modest on purpose: a 10 MiB body cap and 10 s connect /
/// 30 s idle windows on the upstream leg.
typedef RelayLimits = ({
  int maxBodyBytes,
  Duration connectTimeout,
  Duration idleTimeout,
});

/// The upstream connect window for one relay hop — the single literal
/// behind both [relayDefaultLimits] and the [LocalHub.relayConnectTimeout]
/// constructor default (issue #794 review: two 10 s literals).
const Duration relayDefaultConnectTimeout = Duration(seconds: 10);

/// The default relay body cap — the single literal behind
/// [relayDefaultLimits.maxBodyBytes] and the [LocalHub] constructor
/// default (issue #794 review: the 10 MiB cap lived as two literals).
const relayDefaultMaxBodyBytes = 10 * 1024 * 1024;

/// The default per-chunk idle window on the upstream leg — shared the
/// same way (record fields cannot feed const constructor defaults
/// directly, so the knobs are named and the record assembles them).
const relayDefaultIdleTimeout = Duration(seconds: 30);

/// The relay limits everything runs with unless told otherwise — the
/// SINGLE source of truth for [handleRelayRequest]'s default and the
/// [LocalHub] constructor defaults (issue #794 review: the 10 MiB body
/// cap lived as two literals).
const RelayLimits relayDefaultLimits = (
  maxBodyBytes: relayDefaultMaxBodyBytes,
  connectTimeout: relayDefaultConnectTimeout,
  idleTimeout: relayDefaultIdleTimeout,
);

/// The redirect-hop cap (issue #792 AC4): a chain longer than this is a
/// loop — named 502. Shared by the hop policy and the bad-hop rejection
/// so the cap is defined once.
const relayMaxRedirectHops = 5;

/// The relay CLIENT stopped taking data mid-answer (issue #794 review):
/// on some platforms a dead keep-alive peer's writes neither error nor
/// close — the flush just never completes. Racing each flush against the
/// idle window turns that silence into a detectable, bounded event.
class RelayClientGone implements Exception {
  const RelayClientGone();

  @override
  String toString() => 'relay client stopped taking data';
}

/// The outcome of asking for a relay worker slot
/// ([LocalHub._acquireRelaySlot]):
///
/// - [granted]: run the relay.
/// - [refused]: the queue is full — answer 503 backpressure.
/// - [dropped]: the client disconnected while queued — answer nothing.
enum _RelaySlot { granted, refused, dropped }

/// A named relay limit breach (issue #794): [status] is the HTTP shape
/// (413 oversized body, 408 stalled request, 503 queue backpressure,
/// 504 upstream timeout) and [name] is the wire error string.
class RelayLimitExceeded implements Exception {
  const RelayLimitExceeded(this.status, this.name);

  final int status;
  final String name;

  @override
  String toString() => '$name ($status)';
}

/// One `POST /relay` call (issue #633): the desktop add-in taskpane has no
/// extension to carry its provider HTTP, so the pane proxies it through
/// the local hub, which fetches CORS-free by construction. The body is the
/// SW-bridge request envelope `{url, method?, headers?, bodyB64?}`; the
/// upstream answer is streamed back raw (status + content-type + body), so
/// provider SSE flows through incrementally.
///
/// Authentication (issue #792): `/relay` demands a bearer credential on
/// EVERY scope — the master secret when the hub is protected, else the
/// ephemeral per-serve [LocalHub.relaySecret]. A null credential (the hub
/// never started) authenticates nothing: fail closed, 401 everything.
/// A present but non-allowlisted `Origin` is a 403 REJECTION before any
/// upstream work — the old behavior answered minus CORS headers, which
/// still executed the fetch for the hostile page's benefit.
///
/// The gate (OPTIONS / bearer / origin) lives in the top-level
/// [_relayGate]; the body read + upstream forward in
/// [handleRelayBody] — the hub runs the gate BEFORE its pool slot is
/// touched so unauthenticated garbage never occupies a worker
/// (issue #794 review).

/// The cheap relay verdicts every request must pass before it may do
/// any relay work: the OPTIONS preflight, the bearer check, and the
/// origin allowlist. Returns false when the request was ANSWERED here
/// (preflight / 401 / 403). The hub runs this BEFORE pool-slot
/// acquisition so unauthenticated garbage and browser preflights never
/// occupy a worker or a queue slot (issue #794 review).
Future<bool> _relayGate(
  HttpRequest request, {
  required String? Function() requireCredential,
  required String? origin,
}) async {
  final allowedOrigin = relayAllowedOrigin(origin);
  if (request.method == 'OPTIONS') {
    await _relayPreflight(request, allowedOrigin);
    return false;
  }
  final credential = requireCredential();
  if (credential == null ||
      credential.isEmpty ||
      request.headers.value('authorization') != 'Bearer $credential') {
    // Keep-alive pools must not reuse a rejected socket (same shape as
    // the rejected WS upgrade — a stale pooled connection surfaces as
    // "connection closed" on the client's NEXT request).
    request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    _relayMarkRejection(request);
    await _drainRequestBounded(request);
    request.response.statusCode = 401;
    await request.response.close();
    return false;
  }
  if (origin != null && allowedOrigin == null) {
    await _drainRequestBounded(request);
    request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    _relayMarkRejection(request);
    request.response.statusCode = 403;
    request.response.write('{"error":"origin not allowed"}');
    await request.response.close();
    return false;
  }
  return true;
}

Future<void> handleRelayRequest(
  HttpRequest request, {
  required String? Function() requireCredential,
  required String? origin,
  bool allowAnyHost = false,
  RelayLimits limits = relayDefaultLimits,
  void Function(String line)? log,
  void Function()? onUpstreamAbort,
}) async {
  final allowedOrigin = relayAllowedOrigin(origin);
  if (!await _relayGate(
    request,
    requireCredential: requireCredential,
    origin: origin,
  )) {
    return;
  }
  await handleRelayBody(
    request,
    allowedOrigin: allowedOrigin,
    allowAnyHost: allowAnyHost,
    limits: limits,
    log: log,
    onUpstreamAbort: onUpstreamAbort,
  );
}

/// The EXPENSIVE tail of [handleRelayRequest] — the body read and the
/// upstream forward — everything that must run under a pool slot. The
/// cheap verdicts (OPTIONS / bearer / origin) live in the hub's
/// [_relayGate], which runs BEFORE slot acquisition (issue #794 review):
/// unauthenticated garbage never reaches this function through the hub.
Future<void> handleRelayBody(
  HttpRequest request, {
  required String? allowedOrigin,
  bool allowAnyHost = false,
  RelayLimits limits = relayDefaultLimits,
  void Function(String line)? log,
  void Function()? onUpstreamAbort,
}) async {
  final parsed = await _relayEnvelope(request, allowedOrigin, limits, log: log);
  if (parsed == null) return;
  if (!relayDestinationAllowed(parsed.$1, allowAnyHost: allowAnyHost)) {
    request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    _relayMarkRejection(request);
    request.response.statusCode = 403;
    _relayCors(request, allowedOrigin);
    request.response.write('{"error":"destination not allowed"}');
    await request.response.close();
    return;
  }
  await _relayForward(
    request,
    parsed.$1,
    parsed.$2,
    allowedOrigin,
    allowAnyHost: allowAnyHost,
    limits: limits,
    log: log,
    onUpstreamAbort: onUpstreamAbort,
  );
}

/// The known provider hosts a relay destination may name (issue #792):
/// exact match or any subdomain. A relay is a provider transport — the
/// taskpane holds no other legitimate destination.
const _relayAllowedHosts = <String>{
  // Anthropic / OpenAI / ChatGPT
  'api.anthropic.com',
  'api.openai.com',
  'auth.openai.com',
  'chatgpt.com',
  // OpenRouter / Google / MiniMax
  'openrouter.ai',
  'generativelanguage.googleapis.com',
  'platform.minimax.io',
  // GitHub Copilot / models
  'api.github.com',
  'github.com',
  'api.githubcopilot.com',
  'api.enterprise.githubcopilot.com',
  'api.business.githubcopilot.com',
  // FA / Codemie / Aiin
  'fa1.dev',
  'codemie.lab.epam.com',
  'api.aiin.by',
  'auth.aiin.by',
};

/// The destination verdict for one relay envelope (issue #792 AC3):
/// only allowlisted provider hosts, and never loopback, private,
/// link-local (cloud metadata `169.254.169.254` included), or
/// unspecified addresses — denied BEFORE any outbound attempt.
/// [allowAnyHost] is the explicit development opt-in.
// ponytail: every literal IP denies in one gate (loopback, RFC 1918,
// link-local, unspecified, public literals alike — providers are named
// hosts, never addresses); DNS that resolves a public name to an
// internal IP still passes — resolve-and-verify each hop if that
// matters someday.
bool relayDestinationAllowed(Uri url, {bool allowAnyHost = false}) {
  if (allowAnyHost) return true;
  final host = url.host.toLowerCase();
  if (host.isEmpty) return false;
  if (InternetAddress.tryParse(host) != null) return false;
  if (host == 'localhost' || host.endsWith('.localhost')) return false;
  return _relayAllowedHosts.any(
    (allowed) => host == allowed || host.endsWith('.$allowed'),
  );
}

/// CORS grant for a relay response — only when the origin was allowlisted
/// (never `*`).
void _relayCors(HttpRequest request, String? allowedOrigin) {
  if (allowedOrigin == null) return;
  request.response.headers
    ..set('Access-Control-Allow-Origin', allowedOrigin)
    ..set('Vary', 'Origin');
}

/// OPTIONS preflight: 204 plus the full method/header grant so the
/// browser sends the real POST.
Future<void> _relayPreflight(HttpRequest request, String? allowedOrigin) async {
  request.response.statusCode = 204;
  _relayCors(request, allowedOrigin);
  if (allowedOrigin != null) {
    request.response.headers
      ..set('Access-Control-Allow-Methods', 'POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
      ..set('Access-Control-Max-Age', '600');
  }
  await request.response.close();
}

/// Bounded drain of an over-cap relay body: a client that finished
/// within the window gets the 413 on a clean close; one still pumping
/// is cut off (its named answer is then close-only — see
/// [_relayError]). True = the body arrived COMPLETE.
Future<bool> _relayDrainOverCap(
  StreamSubscription<Uint8List> sub,
  Completer<void> consumed,
) async {
  try {
    await consumed.future.timeout(_relayDrainWindow);
    return true; // upload done: the 413 rides HttpResponse
  } on TimeoutException {
    await sub.cancel(); // still pumping: cut the read
  } on Object {
    // A stall (408) raced the cap — over-cap wins: 413.
  }
  return false;
}

/// Reads and validates the bridge envelope; answers 400 and returns null
/// when the body is not JSON or the url is missing/non-http(s).
///
/// Bounded (issue #794): the body streams in under a hard byte cap
/// (413 beyond [RelayLimits.maxBodyBytes]) and a per-chunk idle window
/// (408 when the client stalls mid-body — no slowloris pinning a
/// worker).
Future<(Uri, Map<String, dynamic>)?> _relayEnvelope(
  HttpRequest request,
  String? allowedOrigin,
  RelayLimits limits, {
  void Function(String line)? log,
}) async {
  // Whether the request body arrived COMPLETE (so the named answer can
  // ride a clean HttpResponse close); a body still inbound makes
  // HttpResponse.close destroy the socket — an RST that eats the
  // answer — and makes the named answer close-only (see _relayError).
  var bodyComplete = false;
  try {
    final builder = BytesBuilder(copy: false);
    final capHit = Completer<void>();
    final consumed = Completer<void>();
    late final StreamSubscription<Uint8List> sub;
    sub = request
        .timeout(
          limits.idleTimeout,
          onTimeout: (sink) => sink.addError(
            const RelayLimitExceeded(
              HttpStatus.requestTimeout,
              'relay request stalled',
            ),
          ),
        )
        .listen(
          (chunk) {
            if (capHit.isCompleted) return; // over the cap: drain, don't buffer
            builder.add(chunk);
            if (builder.length > limits.maxBodyBytes) {
              builder.clear(); // no unbounded buffer behind the cap
              capHit.complete(); // the read must end NOW — see below
            }
          },
          onError: consumed.completeError,
          onDone: consumed.complete,
          cancelOnError: true,
        );
    // Whichever ends the read first: the body completing (a stall
    // errors as the 408 above), or the cap firing. Stream events arrive
    // in LATER turns, so an over-cap flag checked in place is always
    // false — the cap must WIN the race, or a client pumping past it
    // pins the worker for the whole upload (issue #794 review round 5,
    // measured: 4 MiB at 32 KiB / 20 ms held the slot 2.6 s).
    await Future.any<void>([consumed.future, capHit.future]);
    if (capHit.isCompleted) {
      // Over the cap: drain a bounded window — a client that finished
      // anyway gets the 413 on a clean close; one still pumping is cut
      // off (the answer is then close-only, see _relayError). Either
      // way the worker is freed NOW, not after the upload.
      bodyComplete = await _relayDrainOverCap(sub, consumed);
      throw const RelayLimitExceeded(
        HttpStatus.requestEntityTooLarge,
        'relay body too large',
      );
    }
    bodyComplete = true;
    final envelope = (jsonDecode(utf8.decode(builder.takeBytes())) as Map)
        .cast<String, dynamic>();
    final url = Uri.tryParse('${envelope['url']}') ?? Uri();
    if (!url.isScheme('https') && !url.isScheme('http')) {
      throw const FormatException('url must be http(s)');
    }
    return (url, envelope);
  } on RelayLimitExceeded catch (error) {
    log?.call('${error.name} → ${error.status}');
    await _relayError(
      request,
      error.status,
      error.name,
      allowedOrigin,
      // The answer rides the normal HttpResponse only when the request
      // body arrived complete; a stalled (408) or still-pumping (413
      // past the drain window) body makes the named answer close-only (see _relayError) —
      // see _relayError (issue #794 review).
      bodyConsumed: bodyComplete,
    );
    return null;
  } on FormatException {
    request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    _relayMarkRejection(request);
    request.response.statusCode = 400;
    _relayCors(request, allowedOrigin);
    request.response.write(
      '{"error":"expecting {url, method?, headers?, '
      'bodyB64?} with an http(s) url"}',
    );
    await request.response.close();
    return null;
  }
}

/// Answers a NAMED limit error (issue #794): 413 / 408 / 503 / 504
/// shapes carry `{"error": "<name>"}`. [bodyConsumed]: whether the
/// request body was fully read on the answering path — an UNconsumed
/// body gets a bounded drain first, and if it still never finishes,
/// the answer goes CLOSE-ONLY: dart:io offers no way to deliver an
/// HTTP answer for an unconsumed request body (HttpResponse.close
/// destroys the socket; detachSocket either throws mid-cancel or
/// auto-commits a 200 before the hand-write — both measured, issue
/// #794 review). The write below is then best-effort and may surface
/// to the client as a bare close; the deterministic guarantee is the
/// named log line and the freed worker. Swallows socket failures —
/// the client being gone is often WHY this answers.
Future<void> _relayError(
  HttpRequest request,
  int status,
  String name,
  String? allowedOrigin, {
  bool bodyConsumed = true,
}) async {
  final answerable = bodyConsumed || await _drainRequestBounded(request);
  try {
    _relayMarkRejection(request);
    if (answerable) {
      _relayCors(request, allowedOrigin);
    }
    request.response.statusCode = status;
    request.response.write('{"error":"$name"}');
    await request.response.close();
  } on Object {
    // The socket died first; nothing to answer.
  }
}

/// The bounded window a limit-hit request body may take to finish
/// arriving before its named answer is attempted close-only (see
/// [_relayError] for why delivery is then not guaranteed).
const _relayDrainWindow = Duration(milliseconds: 250);

/// Best-effort bounded drain of an unread request body; returns whether
/// the request body is COMPLETE afterwards. Answering a request whose
/// body is still inbound + closing the socket makes dart:io destroy it
/// — an RST that eats the answer before the client reads it — the drain
/// keeps that close a clean FIN whenever the body can actually finish.
// ponytail: fixed 250ms drain window — enough for a fully-sent body
// already in kernel buffers; longer waits only help deliberately
// stalled clients, who got the limit for exactly that.
Future<bool> _drainRequestBounded(HttpRequest request) async {
  try {
    await request.drain<void>().timeout(
      _relayDrainWindow,
      onTimeout: () => throw TimeoutException('drain'),
    );
    return true;
  } on Object {
    return false; // stalled body (timeout) or gone client
  }
}

/// Headers for one relay hop: the envelope's headers verbatim, minus
/// the credential-bearing ones once a redirect has left the original
/// host — or downgraded its scheme (https -> http). Header names match
/// case-insensitively.
Map<String, String> _relayHopHeaders(
  Map<String, dynamic> envelope,
  Uri original,
  Uri current,
) {
  final headers = <String, String>{
    for (final entry in ((envelope['headers'] as Map?) ?? const {}).entries)
      '${entry.key}': '${entry.value}',
  };
  // Credentials also die on a scheme downgrade: https -> http on the
  // SAME host hands the bearer to plaintext (issue #792 review).
  final hostChanged = current.host.toLowerCase() != original.host.toLowerCase();
  final schemeDowngraded =
      original.scheme == 'https' && current.scheme == 'http';
  if (hostChanged || schemeDowngraded) {
    headers.removeWhere((name, _) {
      final lower = name.toLowerCase();
      return lower == 'authorization' || lower == 'cookie';
    });
  }
  return headers;
}

/// The redirect target of [res], or null when [res] is not a redirect
/// (301/302/303/307/308 are the contract — `isRedirect` is unreliable
/// under `followRedirects = false`).
Uri? _relayRedirectLocation(HttpClientResponse res) {
  const redirectCodes = {301, 302, 303, 307, 308};
  final location = redirectCodes.contains(res.statusCode)
      ? res.headers.value(HttpHeaders.locationHeader)
      : null;
  return location == null ? null : Uri.parse(location);
}

/// The method a redirect asks for: 301/302/303 demote to GET (the
/// browser shape); 307/308 replay the original method.
String _relayRedirectMethod(int statusCode, String method) =>
    statusCode == HttpStatus.movedTemporarily ||
        statusCode == HttpStatus.seeOther ||
        statusCode == HttpStatus.movedPermanently
    ? 'GET'
    : method;

/// Marks a hub-GENERATED relay rejection so clients can tell it apart
/// from an upstream answer that merely shares the status: a provider 401
/// is the CALLER's credential problem and streams through verbatim; a
/// relay 401 is the transport's (issue #792 review).
void _relayMarkRejection(HttpRequest request) {
  request.response.headers.set('x-fah-relay', 'rejection');
}

/// Answers a relay rejection on the client response: [status] + CORS +
/// a small `{"error": ...}` JSON body. Rejected sockets are never
/// reused (Connection: close).
Future<void> _relayReject(
  HttpRequest request,
  int status,
  String error,
  String? allowedOrigin,
) async {
  request.response.headers.set(HttpHeaders.connectionHeader, 'close');
  _relayMarkRejection(request);
  request.response.statusCode = status;
  _relayCors(request, allowedOrigin);
  request.response.write('{"error":"$error"}');
  await request.response.close();
}

/// Issues one relay hop and returns its answer; the open and the
/// response-header wait both ride the connect window (issue #794).
Future<HttpClientResponse> _relayIssueHop(
  HttpClient upstream,
  String method,
  Uri current, {
  required Map<String, dynamic> envelope,
  required Uri original,
  required List<int>? body,
  required RelayLimits limits,
  void Function(HttpClientRequest req)? onIssued,
}) async {
  final req = await upstream
      .openUrl(method, current)
      .timeout(
        limits.connectTimeout,
        onTimeout: () => throw const RelayLimitExceeded(
          HttpStatus.gatewayTimeout,
          'upstream connect timeout',
        ),
      );
  req.followRedirects = false;
  onIssued?.call(req);
  _relayHopHeaders(envelope, original, current).forEach(req.headers.set);
  final hasBody = body != null && method != 'GET' && method != 'HEAD';
  if (hasBody) req.add(body);
  return req.close().timeout(
    limits.connectTimeout,
    onTimeout: () => throw const RelayLimitExceeded(
      HttpStatus.gatewayTimeout,
      'upstream connect timeout',
    ),
  );
}

/// Bounded drain of an upstream hop body (redirects); a provider that
/// stops mid-drain cannot hold the hop (issue #794).
Future<void> _relayDrainBounded(HttpClientResponse res, RelayLimits limits) =>
    res.drain<void>().timeout(
      limits.idleTimeout,
      onTimeout: () => throw const RelayLimitExceeded(
        HttpStatus.gatewayTimeout,
        'upstream idle timeout',
      ),
    );

/// Proxies the raw upstream response (status + content-type + streamed
/// body, so SSE rides through incrementally); 502 when unreachable.
///
/// Redirects are followed MANUALLY (issue #792): each hop is re-checked
/// against the same destination rules before it is issued, so a provider
/// 3xx cannot silently walk the request into internal space. On a host
/// change the credential headers are dropped (they belong to the host
/// that asked for them).
///
/// Bounded (issue #794): the upstream leg gets a connect timeout and a
/// per-chunk idle timeout (named 504s), and when the relay client goes
/// away mid-flight the upstream request is ABORTED — no orphaned
/// sockets burning a worker.
Future<void> _relayForward(
  HttpRequest request,
  Uri url,
  Map<String, dynamic> envelope,
  String? allowedOrigin, {
  required bool allowAnyHost,
  RelayLimits limits = relayDefaultLimits,
  void Function(String line)? log,
  void Function()? onUpstreamAbort,
}) async {
  final upstream = HttpClient()
    // Belt over the per-hop .timeout windows: an idle-socket connect
    // attempt dies here too, before the request object even exists
    // (issue #792 review).
    ..connectionTimeout = limits.connectTimeout;
  final state = _RelayHopState();
  try {
    await _relayFollowHops(
      request,
      url,
      envelope,
      allowedOrigin,
      upstream: upstream,
      allowAnyHost: allowAnyHost,
      limits: limits,
      state: state,
      onUpstreamAbort: onUpstreamAbort,
      log: log,
    );
  } on RelayLimitExceeded catch (error) {
    state.relaySettled = true; // the client gets a named answer
    await _relayForwardFailure(
      request,
      error.status,
      error.name,
      allowedOrigin,
      log,
    );
  } on RelayClientGone {
    // The flush-stall race fired: the relay client stopped taking data
    // mid-answer (on some platforms the only detectable form of a dead
    // keep-alive peer). The upstream is already aborted via
    // onClientGone; the answer is moot — end quietly, log the fact.
    state.relaySettled = true;
    log?.call('relay client stopped taking data — upstream aborted');
    await _relayQuietClose(request);
  } on Object {
    // Includes the abort path: the relay client disconnected, so the
    // aborted upstream surfaces here. That is a routine disconnect, not
    // an upstream outage: no 502, no error log (issue #794 review). A
    // genuine upstream failure answers 502 Bad Gateway — the proxy
    // semantic; the hub itself is fine.
    state.relaySettled = true;
    if (state.clientGone) {
      await _relayQuietClose(request);
      return;
    }
    await _relayForwardFailure(
      request,
      HttpStatus.badGateway,
      'upstream unreachable',
      allowedOrigin,
      log,
    );
  } finally {
    upstream.close(force: true);
  }
}

/// Mutable per-forward relay state shared by the hop loop and its
/// callbacks (the disconnect watch, the respond arm) — one small cell
/// instead of closures capturing closures.
class _RelayHopState {
  /// The in-flight upstream request of the CURRENT hop; aborted when
  /// the relay client goes away.
  HttpClientRequest? upstreamReq;

  /// Set once the disconnect watch is armed (exactly once per relay).
  bool watchArmed = false;

  /// Set once the relay has ANSWERED its client (any shape). A
  /// response.done that fires before that is a client disconnect.
  bool relaySettled = false;

  /// Set when the failure is the relay CLIENT going away (write-driven
  /// flush error, flush-stall race, or response.done before the answer)
  /// — a routine disconnect, not an upstream outage: the answer goes
  /// nowhere, and the log must not cry 502.
  bool clientGone = false;
}

/// The redirect-following loop of [_relayForward]: issues hops, answers
/// the relay client from the first terminal response, and re-checks
/// every redirect target against the same destination rules before it
/// is issued (issue #792 AC4).
Future<void> _relayFollowHops(
  HttpRequest request,
  Uri url,
  Map<String, dynamic> envelope,
  String? allowedOrigin, {
  required HttpClient upstream,
  required bool allowAnyHost,
  required RelayLimits limits,
  required _RelayHopState state,
  void Function()? onUpstreamAbort,
  void Function(String line)? log,
}) async {
  var current = url;
  var method = _relayMethodFor(envelope);
  final body = _relayRequestBody(envelope);
  _relayArmDisconnectWatch(request, state, onUpstreamAbort: onUpstreamAbort);
  for (var hop = 0; ; hop++) {
    final res = await _relayIssueHop(
      upstream,
      method,
      current,
      envelope: envelope,
      original: url,
      body: body,
      limits: limits,
      onIssued: (req) => state.upstreamReq = req,
    );
    final location = _relayRedirectLocation(res);
    // Done: the client is being served.
    if (location == null) {
      await _relayAnswerFromUpstream(
        request,
        res,
        allowedOrigin,
        limits,
        state: state,
        onUpstreamAbort: onUpstreamAbort,
      );
      return;
    }
    method = _relayRedirectMethod(res.statusCode, method);
    final next = current.resolveUri(location);
    if (!_relayHopAllowed(hop, next, allowAnyHost: allowAnyHost)) {
      await _relayRejectBadHop(request, res, hop, allowedOrigin, limits, log);
      return;
    }
    await _relayDrainBounded(res, limits);
    current = next;
  }
}

/// The relay HTTP method (POST unless the envelope says otherwise).
String _relayMethodFor(Map<String, dynamic> envelope) =>
    '${envelope['method'] ?? 'POST'}';

/// Arms the cancel-on-disconnect watch exactly once per relay (issue
/// #794): response.done completes when the relay client goes away — on
/// current SDKs NORMALLY, not as an error — so whenComplete is the
/// signal, not onError. A settled relay aborts nothing. (A SILENTLY
/// dead keep-alive peer never fires this on some platforms — that side
/// is bounded by the flush-stall race in _relayRespond.)
void _relayArmDisconnectWatch(
  HttpRequest request,
  _RelayHopState state, {
  void Function()? onUpstreamAbort,
}) {
  if (state.watchArmed) {
    return;
  }
  state.watchArmed = true;
  unawaited(
    request.response.done.whenComplete(() {
      if (state.relaySettled) {
        return; // settled relay: nothing to abort, nothing to count
      }
      state.clientGone = true;
      state.upstreamReq?.abort();
      onUpstreamAbort?.call();
    }),
  );
}

/// Serves the relay client from the terminal upstream response. Settle
/// before AND after — a disconnect mid-stream surfaces as done while
/// _relayRespond runs.
Future<void> _relayAnswerFromUpstream(
  HttpRequest request,
  HttpClientResponse res,
  String? allowedOrigin,
  RelayLimits limits, {
  required _RelayHopState state,
  void Function()? onUpstreamAbort,
}) async {
  state.relaySettled = true;
  await _relayRespond(
    request,
    res,
    allowedOrigin,
    limits,
    onClientGone: () {
      // Write-driven disconnect (see _relayRespond): kill the upstream
      // and count the abort.
      state.clientGone = true;
      state.upstreamReq?.abort();
      onUpstreamAbort?.call();
    },
  );
  state.relaySettled = true;
}

/// The redirect policy for one hop: [hop] within the cap AND the target
/// allowed by the same destination rules as the original URL (issue
/// #792 AC4).
bool _relayHopAllowed(int hop, Uri next, {required bool allowAnyHost}) =>
    hop < relayMaxRedirectHops &&
    relayDestinationAllowed(next, allowAnyHost: allowAnyHost);

/// Ends a relay whose answer is moot: closing the response of a client
/// that is already gone must not throw.
Future<void> _relayQuietClose(HttpRequest request) async {
  try {
    await request.response.close();
  } on Object {
    // Already gone.
  }
}

/// The relay request body as bytes (null when the envelope carries none).
Uint8List? _relayRequestBody(Map<String, dynamic> envelope) =>
    envelope['bodyB64'] is String
    ? base64Decode(envelope['bodyB64'] as String)
    : null;

/// Rejects a relay whose redirect chain went bad ([hop] past the cap, or
/// the next hop is a denied destination — issue #792 AC4): the upstream
/// answer is drained so the socket closes cleanly, then a named 502/403
/// reaches the client.
Future<void> _relayRejectBadHop(
  HttpRequest request,
  HttpClientResponse res,
  int hop,
  String? allowedOrigin,
  RelayLimits limits,
  void Function(String line)? log,
) async {
  final tooMany = hop >= relayMaxRedirectHops;
  log?.call(
    tooMany
        ? 'redirect loop (>5 hops) → 502'
        : 'redirect to denied destination → 403',
  );
  await _relayDrainBounded(res, limits);
  await _relayReject(
    request,
    tooMany ? HttpStatus.badGateway : HttpStatus.forbidden,
    tooMany ? 'too many redirects' : 'redirect destination not allowed',
    allowedOrigin,
  );
}

/// Answers a relay that died before an upstream answer could be served:
/// [status]/[name] is a named limit rejection (RelayLimitExceeded) or the
/// plain 502 unreachable fallback.
Future<void> _relayForwardFailure(
  HttpRequest request,
  int status,
  String name,
  String? allowedOrigin,
  void Function(String line)? log,
) async {
  log?.call('$name → $status');
  await _relayError(request, status, name, allowedOrigin);
}

/// Streams the upstream answer to the relay client: status + content-type
/// + body, so SSE rides through incrementally. The stream rides an idle
/// timeout (issue #794): a provider that stops mid-answer cannot hold
/// the worker forever.
///
/// Disconnect detection is WRITE-driven: [HttpResponse.done] is NOT
/// signaled when a keep-alive client silently dies mid-response, so
/// every chunk is flushed and a failed flush means the client is gone —
/// [onClientGone] aborts the upstream. On some platforms a dead
/// keep-alive peer's flush neither errors nor completes — the future
/// just hangs — so every flush is ALSO raced against the idle window
/// (issue #794 review): silence that long means nobody is taking data,
/// the upstream is aborted, and the worker is freed. A live peer's
/// flush completes in microseconds (the data only has to reach the
/// kernel), so the race can never fire on a healthy client that is
/// merely slow to READ.
Future<void> _relayRespond(
  HttpRequest request,
  HttpClientResponse res,
  String? allowedOrigin,
  RelayLimits limits, {
  void Function()? onClientGone,
}) async {
  request.response.statusCode = res.statusCode;
  // The relay is a pipe: small flushed writes (SSE events!) must reach
  // the client immediately, not sit in the HTTP output buffer.
  request.response.bufferOutput = false;
  _relayCors(request, allowedOrigin);
  final contentType = res.headers.value('content-type');
  if (contentType != null) {
    request.response.headers.set('Content-Type', contentType);
  }
  try {
    await for (final chunk in res.timeout(
      limits.idleTimeout,
      onTimeout: (sink) => sink.addError(
        const RelayLimitExceeded(
          HttpStatus.gatewayTimeout,
          'upstream idle timeout',
        ),
      ),
    )) {
      try {
        request.response.add(chunk);
        await request.response.flush().timeout(
          limits.idleTimeout,
          onTimeout: () => throw const RelayClientGone(),
        );
      } on RelayLimitExceeded {
        rethrow;
      } on Object {
        // The flush failed (or stalled past the window): the relay
        // client is gone. Abort the upstream — no orphaned socket may
        // hold the worker.
        onClientGone?.call();
        rethrow;
      }
    }
    await request.response.close();
  } on RelayLimitExceeded {
    // Upstream stopped mid-answer: the 200 headers are committed, so
    // the named 504 cannot replace them — finish the TRUNCATED answer
    // instead of leaving the client hanging, then let the named error
    // shape ride the log.
    try {
      await request.response.close();
    } on Object {
      // The client is already gone; the socket needs nothing.
    }
    rethrow;
  }
}
