// The DAP/1 hub: connection registry, frame dispatch, persistence.
//
// Pure Dart port of the Go hub (relay.go + store.go + mailbox.go). The
// hub stores and forwards ciphertext only — it never sees plaintext.
// Single-isolate Dart removes every mutex of the Go original; frame
// dispatch is sequential per connection by construction.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'auth.dart';
import 'config.dart';
import 'connection.dart';
import 'crypto_utils.dart';
import 'frames.dart';
import 'session.dart';

part 'hub_auth.dart';
part 'hub_channels.dart';
part 'hub_presence.dart';
part 'hub_admin.dart';

/// Hard inbound frame cap (Go relay.go maxFrameBytes).
const maxFrameBytes = 1 << 20;

/// Offline mailbox capacity per agent; overflow drops oldest
/// (Go mailbox.go mailboxCap).
const mailboxCap = 100;

/// The durable identity record of one agent (survives disconnects).
final class AgentEntry {
  String pubkey = '';
  String x25519 = '';
  String name = '';
  bool online = false;
  int lastSeen = 0;
}

/// A chat channel. The hub holds only the channel's PUBLIC key (senders
/// use it); members hold the private key out-of-band. [allowed] is the
/// pubkey ACL (empty = any authenticated agent).
final class HubChannel {
  HubChannel({required this.name, this.pubkey = ''});

  final String name;
  String pubkey;
  List<String> allowed = [];
  final Set<String> members = {};

  /// The ACL check with constant-time pubkey comparison.
  bool allows(String pubkey) =>
      allowed.isEmpty || allowed.any((a) => constEq(a, pubkey));
}

/// The result of matching an upgrade bearer token (port of matchBearer).
typedef DapBearerMatch = ({DapAuthKind kind, String boundName});

/// The whole server state (port of the Go `hub` struct).
final class DapHub {
  DapHub({
    required DapHubConfig config,
    int Function()? nowMs,
    void Function(String line)? log,
    Random? random,
  })  : _config = config,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _log = log ?? _noopLog,
        _random = random ?? Random.secure() {
    if (config.masterSecret.isEmpty) {
      throw ArgumentError(
        'dap_hub: master secret is required (DapHubConfig.masterSecret)',
      );
    }
  }

  final DapHubConfig _config;
  final int Function() _nowMs;
  final void Function(String) _log;
  final Random _random;

  /// Connected clients by agentId (one connection per agent).
  final Map<String, ClientSession> clients = {};

  /// The durable agent registry. Intentionally NOT pruned: an offline
  /// agent stays addressable (whois, DM→mailbox) for the hub's lifetime.
  final Map<String, AgentEntry> agents = {};

  /// The channel registry (persisted).
  final Map<String, HubChannel> channels = {};

  /// Offline mailboxes (bounded, in-memory v1).
  final Map<String, List<Map<String, Object?>>> mailbox = {};

  /// Agents whose mailbox overflowed since the last flush.
  final Set<String> mailboxDropped = {};

  /// Enrolled name → sha256 hex of the issued secret (hashes only).
  final Map<String, String> secrets = {};

  final NonceCache _nonces = NonceCache();
  final SendIdCache _sendIds = SendIdCache();

  static void _noopLog(String _) {}

  int get _now => _nowMs();

  /// Restores the channel registry and issued-secret hashes from the
  /// configured stores. A missing/corrupt document is not an error.
  Future<void> load() async {
    await _loadChannels();
    await _loadSecrets();
  }

  /// Runs one client connection for its lifetime: reads, dispatches,
  /// then deregisters. [kind]/[boundName] come from [matchBearer] at the
  /// transport's upgrade step.
  Future<void> serve(
    DapConnection connection, {
    required DapAuthKind kind,
    String boundName = '',
  }) async {
    final session = ClientSession(
      connection: connection,
      authKind: kind,
      boundName: boundName,
    );
    _log('ws_open');
    try {
      await for (final message in connection.messages) {
        if (message is! String) {
          _sendErr(session, DapCodes.badFrame, 'text frames only');
          continue;
        }
        if (message.length > maxFrameBytes) {
          await _reject(session, DapCodes.badFrame, 'frame too large');
          break;
        }
        await _dispatch(session, message);
      }
    } on Object {
      // A transport error ends the connection the same way EOF does.
    } finally {
      _deregister(session);
      _log('ws_close agent=${_logAgent(session)}');
    }
  }

  /// Routes one raw frame to its handler (port of dispatch).
  Future<void> _dispatch(ClientSession session, String text) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      _sendErr(session, DapCodes.badFrame, 'invalid JSON');
      return;
    }
    if (decoded is! Map<String, Object?>) {
      _sendErr(session, DapCodes.badFrame, 'frame must be a JSON object');
      return;
    }
    final frame = DapFrame(decoded);
    final op = frame.op;
    if (!session.authed && op != 'hello') {
      _sendErr(session, DapCodes.notAuthenticated, 'send hello first');
      return;
    }
    _touchLastSeen(session.agentId);
    final handler = _handlers[op];
    if (handler == null) {
      _sendErr(session, DapCodes.badFrame, 'unknown op $op');
      return;
    }
    await handler(session, frame);
  }

  /// The op dispatch table (hello included; the frozen enroll wire shape
  /// arrives under its `t` name).
  late final Map<String, FutureOr<void> Function(ClientSession, DapFrame)>
      _handlers = {
    'hello': _handleHello,
    'whois': (s, f) => _handleWhois(s, f),
    'presence_query': (s, f) => _handlePresenceQuery(s, f),
    'join': (s, f) => _handleJoin(s, f),
    'send': _handleSend,
    'flush': (s, f) => _handleFlush(s),
    'enroll': (s, f) => _handleEnroll(s),
  };

  /// Stamps the sender's registry entry once per authenticated inbound
  /// frame — liveness reflects ACTIVITY, not connect time.
  void _touchLastSeen(String agentId) {
    final entry = agents[agentId];
    if (entry != null) entry.lastSeen = _now;
  }

  /// Emits a spec error frame (non-fatal).
  void _sendErr(ClientSession session, String code, String message) {
    _log('err agent=${_logAgent(session)} code=$code msg=$message');
    session.sendFrame(errorFrame(code, message));
  }

  /// Answers a failed hello: the error frame is written, THEN the
  /// connection drops (the Go reject ordering guarantee).
  Future<void> _reject(ClientSession session, String code, String message) {
    _log('auth_fail agent=${_logAgent(session)} code=$code msg=$message');
    return session.reject(errorFrame(code, message));
  }

  /// Installs an authenticated client, evicting any previous connection
  /// held by the same agentId, then announces presence.
  void _register(ClientSession session) {
    final old = clients[session.agentId];
    if (old != null && old != session) {
      unawaited(old.close());
      _log('evict agent=${session.agentId}');
    }
    clients[session.agentId] = session;
    final entry = _upsertAgent(session);
    final peers = _presencePeers(session.agentId);
    _sendPresence(peers, session.agentId, entry, online: true);
  }

  /// Removes a dead client unless a newer connection replaced it.
  void _deregister(ClientSession session) {
    unawaited(session.close());
    if (clients[session.agentId] != session) return;
    clients.remove(session.agentId);
    final entry = agents[session.agentId];
    if (entry == null) return;
    entry.online = false;
    entry.lastSeen = _now;
    final peers = _presencePeers(session.agentId);
    _sendPresence(peers, session.agentId, entry, online: false);
  }

  /// Creates or refreshes the identity record.
  AgentEntry _upsertAgent(ClientSession session) {
    final entry = agents.putIfAbsent(session.agentId, AgentEntry.new);
    entry.pubkey = session.pubkey;
    entry.x25519 = session.x25519;
    entry.name = session.name;
    entry.online = true;
    entry.lastSeen = _now;
    return entry;
  }

  /// Connected members sharing any channel with [agentId] (itself
  /// excluded) — the audience of a presence broadcast.
  List<ClientSession> _presencePeers(String agentId) {
    final seen = <ClientSession>{};
    for (final channel in channels.values) {
      if (!channel.members.contains(agentId)) continue;
      for (final memberId in channel.members) {
        final peer = clients[memberId];
        if (peer != null && memberId != agentId) seen.add(peer);
      }
    }
    return seen.toList();
  }

  String _logAgent(ClientSession session) =>
      session.agentId.isEmpty ? '-' : session.agentId;
}
