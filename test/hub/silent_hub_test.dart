/// Regression gate for the hub-silence hang (dap bug report, fah_hub_client
/// 0.1.2): a hub that stays SILENT at the application layer while the
/// socket stays open (pings/pongs flowing) must not wedge the client's
/// request completers forever.
///
/// Reproduces the live incident: two `dap_dm` calls in one turn — the first
/// delivered, the second hung the whole CLI (spinner, ESC dead, no inbound
/// mail) because `peers()`/`whois()` await raw completers with no timeout:
///
/// * BUG 1 — `whois()`/`flush()`/`presenceQuery()` completers have NO
///   timeout: a hub that never answers hangs the caller permanently while
///   the connection is healthy (the 20s ping watchdog never fires — the
///   socket is alive, the application just went quiet).
/// * BUG 2 — `_onError` fails only `_pendingWhois`; `_presenceCompleter`
///   and `_flushCompleter` are not completed on an error frame, so a hub
///   that answers `presence_query` with `error` hangs `peers()` forever.
/// * BUG 3 — `presenceQuery()` stores ONE completer in the single
///   `_presenceCompleter` field: a concurrent call (the 15s
///   PendingInvites poller vs a tool's `_resolvePeer`) overwrites it and
///   ORPHANS the first caller — which then awaits forever even though the
///   hub answered every request. This is the live incident's most likely
///   trigger: the hub stayed healthy, other agents kept chatting, and the
///   fa CLI wedged mid-tool-phase.
/// * BUG 4 — same class for `_pendingWhois[target]`: `_onMsg` resolves an
///   inbound DM's sender via whois() while a `sendDm` to the same peer
///   races it; the map holds one completer per target, so the second
///   write orphans the first.
///
/// The scripted hub here keeps the WebSocket open and ponging in every mode
/// — only the application-frame routing changes, which is exactly the
/// pathological state a dead-ish hub or a ghost peer produces.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

/// How the scripted hub answers application frames after the handshake.
enum HubMode {
  /// Normal answers — healthy hub.
  answering,

  /// Swallow `presence_query`/`whois`/`flush` frames: read them, answer
  /// nothing, keep the socket open. BUG 1.
  silent,

  /// Answer `presence_query` with an `error` frame. BUG 2.
  errorPresence,

  /// Before answering `presence_query`, push an UNSOLICITED one-agent
  /// presence broadcast (a join event) — the client must not let it
  /// satisfy the pending full-roster query. BUG 5 (live: "only self
  /// online" every other restart).
  broadcastRace,
}

/// Minimal scripted DAP/1 hub: real WebSocket, real handshake, and a
/// switchable application layer. Signature checks are skipped on purpose —
/// the client under test does not require the server to verify.
class SilentHub {
  HttpServer? _server;
  HubMode mode = HubMode.answering;

  String get url {
    final server = _server!;
    return 'ws://127.0.0.1:${server.port}/ws';
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen(
          (dynamic data) => unawaited(_onData(ws, data as String)),
          onDone: () {},
          onError: (Object _) {},
          cancelOnError: true,
        );
      }
    }
  }

  Future<void> _onData(WebSocket ws, String data) async {
    final Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(data) as Map).cast<String, dynamic>();
    } on FormatException {
      return;
    }
    switch (frame['op'] as String?) {
      // The handshake always answers — the client must be fully connected
      // before the application layer goes quiet.
      case 'hello':
        final pubkey = frame['pubkey'] as String;
        final agentId = sha256
            .convert(base64Decode(pubkey))
            .toString()
            .substring(0, 16);
        _reply(ws, {'op': 'welcome', 'agentId': agentId});
      case 'presence_query':
        if (mode == HubMode.broadcastRace) {
          // An unsolicited join-event broadcast lands BEFORE the query
          // answer — one agent only, not the roster the caller asked for.
          _reply(ws, {
            'op': 'presence',
            'agents': [
              {'agentId': 'ffffffffffffffff', 'online': true},
            ],
          });
        }
        switch (mode) {
          case HubMode.silent:
            return; // swallowed: the bug state
          case HubMode.errorPresence:
            _reply(ws, {'op': 'error', 'code': 'boom', 'msg': 'nope'});
          case HubMode.answering || HubMode.broadcastRace:
            _reply(ws, {
              'op': 'presence',
              'agents': [
                {
                  'agentId': '0011223344556677',
                  'pubkey': pubkey,
                  'x25519': frame['x25519'] as String? ?? pubkey,
                  'online': true,
                },
                {
                  'agentId': 'aabbccddeeff0011',
                  'pubkey': pubkey,
                  'x25519': frame['x25519'] as String? ?? pubkey,
                  'online': true,
                },
              ],
            });
        }
      case 'whois':
        if (mode == HubMode.silent) return; // swallowed: the bug state
        _reply(ws, {
          'op': 'agent_info',
          'agentId': frame['agentId'] as String,
          'pubkey': pubkey,
          'x25519': frame['x25519'] as String? ?? pubkey,
          'online': true,
        });
      default:
        return; // send/join/flush and anything else: ignored
    }
  }

  // A syntactically valid base64 blob standing in for peer keys — the
  // silence tests never reach key use.
  static final String pubkey = base64Encode(List.filled(32, 1));

  void _reply(WebSocket ws, Map<String, dynamic> frame) =>
      ws.add(jsonEncode(frame));
}

Future<HubClient> connectTo(SilentHub hub) async {
  final client = HubClient(
    config: HubConfig(url: hub.url),
    identity: await HubIdentity.generate(),
    // Short door so silent-hub timeouts land inside the 3s test
    // watchdog (package default is 10s — the param exists for tests).
    requestTimeout: const Duration(seconds: 2),
  );
  await client.connect();
  return client;
}

/// Races [future] against a short watchdog. Returns how it ended:
/// 'completed', 'errored' (the package finished it — the FIXED contract),
/// or throws with the reproduction message when the future never ends
/// (the hang — 0.1.2 behavior).
Future<String> bounded<T>(Future<T> future, Duration limit) {
  return future
      .then((_) => 'completed', onError: (_) => 'errored')
      .timeout(
        limit,
        onTimeout: () => throw StateError(
          'HANG REPRODUCED: the operation never completed within $limit. '
          'Either the hub never answered, or the caller\'s completer was '
          'orphaned by a concurrent request clobbering it — the hub may '
          'have answered perfectly. The package must complete every '
          'request itself (timeout + fan-out, no single-completer '
          'clobber).',
        ),
      );
}

void main() {
  const timeout = Timeout(Duration(seconds: 15));

  test(
    'BUG 1: silent presence_query must not hang peers() (socket alive)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.silent;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final outcome = await bounded(client.peers(), const Duration(seconds: 3));
      // Healthy prerequisite: the connection itself never dropped.
      expect(
        client.status().connected,
        isTrue,
        reason:
            'socket must stay open (pings/pongs flow) — the hang is '
            'application-layer, not a disconnect',
      );
      // Loud bounded error (requestTimeout), never a silent hang.
      expect(outcome, 'errored');
    },
  );

  test(
    'BUG 1: silent whois must not hang sendDm() (socket alive)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.silent;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final outcome = await bounded(
        client.sendDm('aabbccddeeff0011', 'hello'),
        const Duration(seconds: 3),
      );
      expect(client.status().connected, isTrue);
      // Loud bounded error (requestTimeout), never a silent hang.
      expect(outcome, 'errored');
    },
  );

  test(
    'BUG 2: error-answered presence_query must not hang peers()',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.errorPresence;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final outcome = await bounded(client.peers(), const Duration(seconds: 3));
      expect(client.status().connected, isTrue);
      // The hub answered with an error frame — the caller must see it.
      expect(outcome, 'errored');
    },
  );

  test(
    'BUG 3: concurrent presenceQuery must not orphan the first caller '
    '(poller vs tool clobber — hub answers INSTANTLY)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.answering; // healthy hub, no silence at all
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      // The 15s PendingInvites poller races the tool's _resolvePeer:
      // both call presenceQuery(); the single _presenceCompleter field
      // means the second call orphans the first caller's completer.
      final first = client.peers();
      final second = client.peers();

      final secondOutcome = await bounded(second, const Duration(seconds: 3));
      expect(secondOutcome, 'completed');
      // The first caller must receive the VALUE (fan-out) — completing
      // with a timeout error here still means the clobber is present.
      final firstOutcome = await bounded(first, const Duration(seconds: 3));
      expect(firstOutcome, 'completed');
    },
  );

  test(
    'BUG 4: concurrent whois of the same target must not orphan the '
    'first caller (inbound-DM sender resolution vs sendDm)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.answering; // healthy hub, no silence at all
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      // _onMsg resolves an inbound DM's sender via whois(); a sendDm to
      // the same peer races it. _pendingWhois[target] holds ONE
      // completer — the second write orphans the first.
      const target = 'aabbccddeeff0011';
      final first = client.whois(target);
      final second = client.whois(target);

      final secondOutcome = await bounded(second, const Duration(seconds: 3));
      expect(secondOutcome, 'completed');
      // The first caller must receive the VALUE (fan-out) — completing
      // with a timeout error here still means the clobber is present.
      final firstOutcome = await bounded(first, const Duration(seconds: 3));
      expect(firstOutcome, 'completed');
    },
  );

  test(
    'BUG 5: an unsolicited presence broadcast must not satisfy a pending '
    'full-roster query (live: "only self online" every other restart)',
    skip:
        'fah_hub_client ^0.2.0: any op:presence frame completes all '
        'presence waiters (hub_client _onPresence), so a join-event '
        'broadcast with a one-agent roster can answer a peers() call — '
        'wrong VALUE, not a hang. Verified RED 2026-08-31 (roster came '
        'back as the one-agent broadcast). Needs the hub query-id echo + '
        'waiter-matching wave. Unskip when it lands.',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.broadcastRace;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final roster = await client.peers().timeout(const Duration(seconds: 5));

      // The roster must be the query ANSWER (two agents), never the
      // one-agent broadcast that arrived first.
      expect(
        roster.map((a) => a.agentId),
        containsAll(<String>['0011223344556677', 'aabbccddeeff0011']),
      );
    },
  );
}
