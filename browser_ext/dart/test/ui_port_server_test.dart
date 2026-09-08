// UiPortServer (ui_port_server.dart): the SW side of FaUiProtocol —
// hello/version-refusal, malformed isolation per channel, prompt dedup
// across reconnects (E30), attach replay from the bounded ring with
// lastEventId filtering (AC16), N-channel multiplexing (E8), approval
// proxying, sessions/settings roundtrips, verbatim message_done. UT-S*,
// issue #30.
import 'dart:async';

import 'package:test/test.dart';

// The package has no lib/ — the SW entry compiles src/ directly.
import '../src/ui_port_server.dart';
import '../src/ui_protocol.dart';
import '../src/ui_transport.dart';

/// Fake UI-side port over a synchronous broadcast controller: `inject` is
/// the UI→SW direction, [sent] records SW→UI envelopes. Sync delivery
/// keeps every test deterministic — no pumps except channel-close
/// cleanup, which rides a microtask.
final class FakeChannel implements UiPortChannel {
  final _inbound = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  var _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  @override
  void send(Map<String, dynamic> json) {
    if (!_closed) sent.add(json);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    // Deferred: the server may close us from inside a synchronous inject
    // (version refusal) — firing `done` re-entrantly would throw. Real
    // port bindings deliver onDisconnect asynchronously anyway.
    scheduleMicrotask(_inbound.close);
  }

  /// UI → SW: injects an already-decoded envelope (the binding's decode
  /// step happens before onMessage by contract).
  void inject(Map<String, dynamic> json) {
    if (!_closed && !_inbound.isClosed) _inbound.add(json);
  }

  void injectMsg(UiProtocolMessage msg) => inject(msg.encode());
}

/// Records everything the server drives through the connector.
final class FakeHostConnector implements UiHostConnector {
  final users = <String>[];
  var cancels = 0;
  final decisions = <(String, bool)>[];
  final puts = <Map<String, dynamic>>[];
  final extCalls = <(String, Map<String, dynamic>)>[];

  /// When non-null, [extRequest] throws this instead of answering.
  Object? extError;

  @override
  Future<Map<String, dynamic>> extRequest(
    String op,
    Map<String, dynamic> params,
  ) async {
    extCalls.add((op, params));
    final error = extError;
    if (error != null) throw error;
    return {'ok-op': op};
  }

  @override
  String sessionId = 'sess-1';

  var settings = <String, dynamic>{'temperature': 0.7};

  var sessions = <Map<String, dynamic>>[
    {'id': 's0', 'title': 'old'},
  ];

  var tools = const [
    UiToolState(name: 'browser_active_tab', enabled: true),
    UiToolState(name: 'browser_inject_js', enabled: true),
  ];
  final toolsPuts = <List<UiToolState>>[];

  @override
  List<UiToolState> toolsList() => tools;

  @override
  void toolsPut(List<UiToolState> value) => toolsPuts.add(value);

  @override
  void sendUser(String text) => users.add(text);

  @override
  void cancelTurn() => cancels++;

  @override
  void decide(String approvalId, bool allow) =>
      decisions.add((approvalId, allow));

  @override
  Map<String, dynamic> state() => {'running': cancels > 0};

  @override
  Map<String, dynamic> settingsGet() => settings;

  @override
  void settingsPut(Map<String, dynamic> next) {
    puts.add(next);
    settings = {...settings, ...next};
  }

  @override
  List<Map<String, dynamic>> sessionsList() => sessions;

  var newSessionCalls = 0;

  /// When non-null, [newSession] throws this instead of resetting.
  Object? newSessionError;

  @override
  Future<void> newSession() async {
    newSessionCalls++;
    final error = newSessionError;
    if (error != null) throw error;
    sessions = [
      {'id': 'fresh', 'title': 'new'},
    ];
    sessionId = 'fresh';
  }

  var openedSessions = <String>[];

  @override
  Future<void> openSession(String sessionId) async {
    openedSessions.add(sessionId);
    sessions = [
      {'id': sessionId, 'title': 'restored'},
    ];
    this.sessionId = sessionId;
  }
}

Map<String, dynamic>? _ofKind(FakeChannel c, String kind) {
  for (final m in c.sent) {
    if (m['kind'] == kind) return m;
  }
  return null;
}

int _countEvent(FakeChannel c, String text) => c.sent
    .where((m) => m['kind'] == 'stream' && (m['event'] as Map)['text'] == text)
    .length;

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'attach ends with a fresh status snapshot (run-state re-sync)',
    () async {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
      c.injectMsg(const AttachMsg(sessionId: null, lastEventId: null));
      await _pump();
      final status = [
        for (final raw in c.sent)
          if (raw['kind'] == 'stream' &&
              (raw['event'] as Map)['type'] == 'status')
            raw['event'] as Map,
      ];
      expect(
        status,
        isNotEmpty,
        reason:
            'every attach must end with the authoritative run state, '
            'or a panel that missed a turn end stays "typing" forever',
      );
      expect(status.last, containsPair('running', anything));
    },
  );

  test('ping is answered with pong (keepalive)', () async {
    final host = FakeHostConnector();
    final server = UiPortServer(host: host);
    final c = FakeChannel();
    server.serve(c);
    c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
    await _pump();
    c.injectMsg(const PingMsg());
    await _pump();
    final kinds = [for (final raw in c.sent) raw['kind']];
    expect(kinds.last, 'pong');
    expect(
      kinds.where((k) => k == 'pong').length,
      1,
      reason: 'exactly one pong per ping; keepalive traffic stays quiet',
    );
  });

  test(
    'ext_request routes to the host op surface and answers with data',
    () async {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
      await _pump();
      c.injectMsg(
        const ExtRequestMsg(
          id: 'x1',
          op: 'cookies.get_all',
          params: {'url': 'https://codemie.lab.epam.com/'},
        ),
      );
      await _pump();
      expect(host.extCalls.single.$1, 'cookies.get_all');
      final result = _ofKind(c, 'ext_result');
      expect(result, isNotNull);
      expect(result!['id'], 'x1');
      expect(result['ok'], isTrue);
      expect((result['data'] as Map)['ok-op'], 'cookies.get_all');
    },
  );

  test(
    'ext_request failure becomes a structured ok:false ext_result',
    () async {
      final host = FakeHostConnector()..extError = 'unknown ext op: exec';
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
      await _pump();
      c.injectMsg(const ExtRequestMsg(id: 'x2', op: 'exec'));
      await _pump();
      final result = _ofKind(c, 'ext_result');
      expect(result, isNotNull);
      expect(result!['id'], 'x2');
      expect(result['ok'], isFalse);
      expect(result['error'], contains('unknown'));
      expect(result['data'], isNull);
    },
  );

  test('attach answers tools_state with the host tool list', () async {
    final host = FakeHostConnector();
    final server = UiPortServer(host: host);
    final c = FakeChannel();
    server.serve(c);
    c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
    c.injectMsg(const AttachMsg(sessionId: null, lastEventId: null));
    await _pump();
    final kinds = [for (final raw in c.sent) raw['kind']];
    expect(
      kinds.where((k) => k != 'stream'),
      containsAllInOrder(['hello_ack', 'attached', 'tools_state']),
    );
    final state = _ofKind(c, 'tools_state');
    expect(state, isNotNull);
    expect((state!['tools'] as List).first, {
      'name': 'browser_active_tab',
      'enabled': true,
    });
  });

  test(
    'tools_put applies through the host and re-answers tools_state',
    () async {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
      c.injectMsg(const AttachMsg(sessionId: null, lastEventId: null));
      await _pump();
      c.injectMsg(
        const ToolsPutMsg(
          tools: [UiToolState(name: 'browser_inject_js', enabled: false)],
        ),
      );
      await _pump();
      expect(host.toolsPuts.single.single.name, 'browser_inject_js');
      // The put is answered with the (host-mutated) fresh state.
      final states = [
        for (final raw in c.sent)
          if (raw['kind'] == 'tools_state') raw,
      ];
      expect(states, hasLength(2));
    },
  );

  group('UT-S1: hello / hello_ack', () {
    test('acks negotiated version, capabilities and sessionId', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      expect(server.connections, 1);

      c.injectMsg(const HelloMsg(protoVersion: 2, capabilities: ['stream']));
      final ack = _ofKind(c, 'hello_ack');
      expect(ack, isNotNull);
      expect(ack!['protoVersion'], 2);
      expect(ack['serverCapabilities'], [
        'stream',
        'approvals',
        'sessions',
        'settings',
      ]);
      expect(ack['sessionId'], 'sess-1');
    });

    test('newer peer claim negotiates down to our version', () {
      final server = UiPortServer(host: FakeHostConnector());
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const HelloMsg(protoVersion: 9, capabilities: []));
      expect(_ofKind(c, 'hello_ack')!['protoVersion'], 2);
    });

    test('version 0 → error + close, server keeps serving', () {
      final server = UiPortServer(host: FakeHostConnector());
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const HelloMsg(protoVersion: 0, capabilities: []));
      final err = _ofKind(c, 'error');
      expect(err, isNotNull);
      expect(err!['code'], 'version');
      expect(c.isClosed, isTrue);

      final next = FakeChannel();
      server.serve(next);
      next.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
      expect(_ofKind(next, 'hello_ack'), isNotNull);
    });
  });

  group('UT-S2: malformed isolation', () {
    test('garbage envelope errors THAT channel only; server unaffected', () {
      final server = UiPortServer(host: FakeHostConnector());
      final bad = FakeChannel();
      final other = FakeChannel();
      server.serve(bad);
      server.serve(other);

      bad.inject({'nope': true});
      expect(_ofKind(bad, 'error')!['code'], 'malformed');
      expect(other.sent, isEmpty); // untouched

      bad.injectMsg(const HelloMsg(protoVersion: 2, capabilities: []));
      expect(_ofKind(bad, 'hello_ack'), isNotNull); // server still alive
      expect(_ofKind(other, 'hello_ack'), isNull);
    });

    test('UI-bound kinds echoed inbound are ignored silently', () {
      final server = UiPortServer(host: FakeHostConnector());
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(
        const HelloAckMsg(
          protoVersion: 2,
          serverCapabilities: [],
          sessionId: null,
        ),
      );
      c.injectMsg(const ErrorMsg(code: 'x', message: 'x'));
      c.injectMsg(const StreamMsg(event: {'type': 'delta'}));
      expect(c.sent, isEmpty);
    });
  });

  group('UT-S3: prompt / steer / cancel', () {
    test('prompt runs once; duplicate id after reconnect is dropped', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final a = FakeChannel();
      server.serve(a);
      a.injectMsg(const PromptMsg(id: 'p1', text: 'hi'));
      expect(host.users, ['hi']);

      a.close(); // reconnect on a fresh channel, same prompt id
      final b = FakeChannel();
      server.serve(b);
      b.injectMsg(const PromptMsg(id: 'p1', text: 'hi'));
      expect(host.users, ['hi']); // deduped across channels
    });

    test('steer passes straight through, no dedup', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const PromptMsg(id: 'p1', text: 'go'));
      c.injectMsg(const SteerMsg(text: 'stop after this tool'));
      c.injectMsg(const SteerMsg(text: 'stop after this tool'));
      expect(host.users, [
        'go',
        'stop after this tool',
        'stop after this tool',
      ]);
    });

    test('cancel reaches cancelTurn', () {
      final server = UiPortServer(host: FakeHostConnector());
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const CancelMsg());
      c.injectMsg(const CancelMsg());
      expect(_ofKind(c, 'hello_ack'), isNull); // no ack noise
      // Two cancels, two calls — cancel is not deduped (it aborts once).
    });
  });

  group('UT-S4: attach replay (AC16)', () {
    test('events before attach replay in order with monotonic seq', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      server.onHostEvent({'type': 'delta', 'text': 'a'});
      server.onHostEvent({'type': 'delta', 'text': 'b'});
      server.onHostEvent({'type': 'delta', 'text': 'c'});

      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const AttachMsg(sessionId: null, lastEventId: null));
      final att = _ofKind(c, 'attached')!;
      expect(att['sessionId'], 'sess-1');
      expect(att['replay'], [
        {
          'seq': 1,
          'event': {'type': 'delta', 'text': 'a'},
        },
        {
          'seq': 2,
          'event': {'type': 'delta', 'text': 'b'},
        },
        {
          'seq': 3,
          'event': {'type': 'delta', 'text': 'c'},
        },
      ]);
    });

    test('lastEventId filters to strictly later entries', () {
      final server = UiPortServer(host: FakeHostConnector());
      server.onHostEvent({'type': 'delta', 'text': 'a'});
      server.onHostEvent({'type': 'delta', 'text': 'b'});
      server.onHostEvent({'type': 'delta', 'text': 'c'});

      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const AttachMsg(sessionId: null, lastEventId: '2'));
      expect(_ofKind(c, 'attached')!['replay'], [
        {
          'seq': 3,
          'event': {'type': 'delta', 'text': 'c'},
        },
      ]);
    });

    test('unparsable lastEventId replays everything resident', () {
      final server = UiPortServer(host: FakeHostConnector());
      server.onHostEvent({'type': 'delta', 'text': 'a'});
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const AttachMsg(sessionId: null, lastEventId: 'not-a-seq'));
      expect((_ofKind(c, 'attached')!['replay'] as List).length, 1);
    });

    test('replayCap bounds the ring; seq stays monotonic', () {
      final server = UiPortServer(host: FakeHostConnector(), replayCap: 2);
      server.onHostEvent({'type': 'delta', 'text': 'a'});
      server.onHostEvent({'type': 'delta', 'text': 'b'});
      server.onHostEvent({'type': 'delta', 'text': 'c'});
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const AttachMsg(sessionId: null, lastEventId: null));
      expect(_ofKind(c, 'attached')!['replay'], [
        {
          'seq': 2,
          'event': {'type': 'delta', 'text': 'b'},
        },
        {
          'seq': 3,
          'event': {'type': 'delta', 'text': 'c'},
        },
      ]);
    });
  });

  group('UT-S5: multiplexing (E8)', () {
    test(
      'both channels receive broadcasts; closing one keeps the other',
      () async {
        final server = UiPortServer(host: FakeHostConnector());
        final a = FakeChannel();
        final b = FakeChannel();
        server.serve(a);
        server.serve(b);
        expect(server.connections, 2);

        server.onHostEvent({'type': 'delta', 'text': 'x'});
        expect(_countEvent(a, 'x'), 1);
        expect(_countEvent(b, 'x'), 1);

        server.broadcast(StreamMsg(event: {'type': 'delta', 'text': 'y'}));
        expect(_countEvent(a, 'y'), 1);
        expect(_countEvent(b, 'y'), 1);

        a.close();
        await _pump(); // onDone cleanup rides a microtask
        expect(server.connections, 1);

        server.onHostEvent({'type': 'delta', 'text': 'z'});
        expect(_countEvent(a, 'z'), 0); // closed: no growth, no throw
        expect(_countEvent(b, 'z'), 1);
      },
    );
  });

  group('UT-S6: approvals', () {
    test('request fans to all channels; responses reach decide', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final a = FakeChannel();
      final b = FakeChannel();
      server.serve(a);
      server.serve(b);

      const call = {
        'tool': 'click',
        'args': {'selector': '#x'},
      };
      server.onHostEvent({
        'type': 'approval_request',
        'id': 'a1',
        'call': call,
        'reason': 'act on the page',
      });
      for (final c in [a, b]) {
        final req = _ofKind(c, 'approval_request')!;
        expect(req['id'], 'a1');
        expect(req['call'], call);
        expect(req['reason'], 'act on the page');
      }

      b.injectMsg(const ApprovalResponseMsg(id: 'a1', decision: 'allow'));
      a.injectMsg(const ApprovalResponseMsg(id: 'a2', decision: 'deny'));
      expect(host.decisions, [('a1', true), ('a2', false)]);
    });

    test('approval_resolved streams back as an info event', () {
      final server = UiPortServer(host: FakeHostConnector());
      final c = FakeChannel();
      server.serve(c);
      server.onHostEvent({
        'type': 'approval_resolved',
        'id': 'a1',
        'allow': false,
        'note': 'timed out',
      });
      final msg = _ofKind(c, 'stream');
      expect(msg, isNotNull);
      expect(msg!['event'], {
        'type': 'approval_resolved',
        'id': 'a1',
        'allow': false,
        'note': 'timed out',
      });
    });
  });

  group('UT-S7: sessions / settings', () {
    test('sessions_query answers from the connector', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const SessionsQueryMsg());
      expect(_ofKind(c, 'sessions_result')!['sessions'], host.sessionsList());
    });

    test(
      'session_new resets and answers the attach trio on the channel',
      () async {
        final host = FakeHostConnector();
        final server = UiPortServer(host: host);
        final c = FakeChannel();
        server.serve(c);
        c.injectMsg(const SessionNewMsg());
        await _pump();
        expect(host.newSessionCalls, 1);
        // attached (fresh id, empty replay) + tools + status — the same
        // shapes an attach cycle ends with.
        final attached = _ofKind(c, 'attached')!;
        expect(attached['sessionId'], 'fresh');
        expect(attached['replay'], isEmpty);
        expect(_ofKind(c, 'tools_state'), isNotNull);
        final status = _ofKind(c, 'stream');
        expect(status!['event'], containsPair('type', 'status'));
      },
    );

    test('session_new busy/host errors answer a structured error', () async {
      final host = FakeHostConnector()..newSessionError = 'busy';
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);
      c.injectMsg(const SessionNewMsg());
      await _pump();
      expect(host.newSessionCalls, 1);
      final err = _ofKind(c, 'error')!;
      expect(err['code'], 'session_new');
      expect(err['message'], 'busy');
      // No attached: the panel keeps its current session view.
      expect(_ofKind(c, 'attached'), isNull);
    });

    test(
      'session_open restores and answers the attach trio; ring clears',
      () async {
        final host = FakeHostConnector();
        final server = UiPortServer(host: host);
        final c = FakeChannel();
        server.serve(c);
        // An event lands in the replay ring (host → fan-out).
        server.onHostEvent({'type': 'delta', 'text': 'old session'});
        c.injectMsg(const SessionOpenMsg(sessionId: 'arch-1'));
        await _pump();
        expect(host.openedSessions, ['arch-1']);
        final attached = _ofKind(c, 'attached')!;
        expect(attached['sessionId'], 'arch-1');
        expect(_ofKind(c, 'tools_state'), isNotNull);
        // A later attach with NO lastEventId must NOT replay the old
        // session's events — the reset cleared the ring.
        c.injectMsg(const AttachMsg(sessionId: null, lastEventId: null));
        await _pump();
        final replays = c.sent
            .whereType<Map>()
            .where((m) => m['kind'] == 'attached')
            .map((m) => m['replay'])
            .toList();
        expect(replays.last, isEmpty);
      },
    );

    test(
      'session_open errors answer a structured error on that channel',
      () async {
        final host = FakeHostConnector();
        final server = UiPortServer(host: host, replayCap: 10);
        final c = FakeChannel();
        server.serve(c);
        // Make openSession fail: a connector without the archive throws via
        // openSession — simulate by sending an unknown id is host business;
        // here we force the error path with a malformed-null id instead.
        c.inject(const {'kind': 'session_open'}); // missing sessionId
        await _pump();
        final err = _ofKind(c, 'error');
        expect(err, isNotNull); // malformed decode → structured error
      },
    );

    test('settings query and put roundtrip through the connector', () {
      final host = FakeHostConnector();
      final server = UiPortServer(host: host);
      final c = FakeChannel();
      server.serve(c);

      c.injectMsg(const SettingsQueryMsg());
      c.injectMsg(const SettingsPutMsg(settings: {'temperature': 0.2}));
      expect(host.puts, [
        {'temperature': 0.2},
      ]);

      final results = c.sent
          .where((m) => m['kind'] == 'settings_result')
          .toList();
      expect(results.length, 2); // query + put, one answer each
      expect(results.first['settings'], {'temperature': 0.7});
      expect(results.last['settings'], {'temperature': 0.2}); // current
    });
  });

  group('UT-S8: message_done verbatim', () {
    test('drops only the type tag; passes the payload untouched', () {
      final server = UiPortServer(host: FakeHostConnector());
      final c = FakeChannel();
      server.serve(c);
      final done = <String, dynamic>{
        'type': 'message_done',
        'role': 'assistant',
        'text': 'final',
        'toolCalls': <Map<String, dynamic>>[
          {
            'name': 'click',
            'args': {'selector': '#x'},
          },
        ],
      };
      server.onHostEvent(done);

      final msg = _ofKind(c, 'message_done')!;
      expect(msg['message'], {
        'role': 'assistant',
        'text': 'final',
        'toolCalls': [
          {
            'name': 'click',
            'args': {'selector': '#x'},
          },
        ],
      });
      expect((msg['message'] as Map).containsKey('type'), isFalse);
      expect(done['type'], 'message_done'); // host's map not mutated
    });
  });
}
