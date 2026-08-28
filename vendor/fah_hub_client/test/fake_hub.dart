/// In-memory DAP/1 hub for tests: HttpServer + WebSocketTransformer on
/// 127.0.0.1 ephemeral port. Implements hello (independent per-spec
/// signature + ts-freshness + nonce-replay checks), welcome, eviction,
/// channel fan-out, DM routing, join, offline mailboxes, flush, whois,
/// presence.
///
/// Signature verification here is deliberately re-implemented (not shared
/// with the client library) so wire-format bugs cannot cancel out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

class FakeHub {
  HttpServer? _server;

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
    _server = await HttpServer.bind('127.0.0.1', 0);
    unawaited(_serve());
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

  /// Resolves when the hub has seen [n] signature-verified hellos.
  Future<void> waitForHellos(int n) async {
    if (_hellosSeen >= n) return;
    await hellos.firstWhere((_) => _hellosSeen >= n)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      if (request.uri.path == '/healthz') {
        request.response.statusCode = 200;
        await request.response.close();
      } else if (request.uri.path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
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
        final frame = (jsonDecode(data as String) as Map).cast<String, dynamic>();
        final op = frame['op'] as String?;
        switch (op) {
          case 'hello':
            agentId = await _hello(ws, frame);
          case 'whois':
            _whois(ws, frame);
          case 'send' when agentId != null:
            await _send(ws, agentId, frame);
          case 'join' when agentId != null:
            _join(ws, agentId, frame);
          case 'flush' when agentId != null:
            _flush(ws, agentId);
          case 'presence_query':
            _presence(ws);
          default:
            _reply(ws, {'op': 'error', 'code': 'bad_frame', 'msg': 'op?$op'});
        }
      }
    } on Object {
      // socket error — fall through to cleanup
    }
    if (agentId != null && identical(_conns[agentId], ws)) {
      _conns.remove(agentId);
      if (!_offlineEvents.isClosed) _offlineEvents.add(agentId);
    }
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
    _reply(ws, {
      'op': 'welcome',
      'agentId': agentId,
    });
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
    if (!await _verifySig(frame, frame['pubkey'] as String)) return 'bad_signature';
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
    final payload =
        'dap1|${frame['op']}|${frame['ts']}|${_hex(digest.bytes)}';
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
      _reply(ws, {'op': 'error', 'code': 'not_authenticated', 'msg': 'hello first'});
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

  void _presence(WebSocket ws) {
    _reply(ws, {
      'op': 'presence',
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
