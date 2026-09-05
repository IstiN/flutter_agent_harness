// UI-side transport (ui_transport.dart): the worker-relay reconnect state
// machine (UT-P4: scripted fake channel + immediate delay scheduler — drop
// mid-stream, backoff per schedule, Reconnected, offline queue flushed once
// in order, duplicate prompt ids dropped), the plain-web local stream
// transport (events re-emitted as port-identical envelopes, dedup), and
// detectTransport's matrix (UT-P5).
import 'dart:async';

import 'package:test/test.dart';

import '../src/ui_protocol.dart';
import '../src/ui_transport.dart';

/// Scripted chrome.runtime.Port: records sends, replays inbound envelopes.
/// close() completes the inbound stream — the same signal the real binding
/// maps port onDisconnect onto.
final class FakeChannel implements UiPortChannel {
  final sent = <Map<String, dynamic>>[];
  final _inbound = StreamController<Map<String, dynamic>>();
  var _closed = false;

  @override
  void send(Map<String, dynamic> json) {
    if (_closed) throw StateError('port closed');
    sent.add(json);
  }

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inbound.close();
  }

  @override
  bool get isClosed => _closed;

  void receive(UiProtocolMessage message) => _inbound.add(message.encode());
  void receiveRaw(Map<String, dynamic> json) => _inbound.add(json);

  List<String> get sentKinds => [
    for (final message in sent) message['kind'] as String,
  ];
}

/// Flushes every microtask (the injected delay resolves via microtasks, so
/// one zero-duration timer drains a whole retry step).
Future<void> pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

HelloAckMsg _ack() => HelloAckMsg(
  protoVersion: uiProtocolVersion,
  serverCapabilities: const [],
  sessionId: null,
);

void main() {
  group('WorkerRelayTransport (UT-P4 state machine)', () {
    test('UT-P4: drop mid-stream reconnects per schedule and flushes the '
        'offline queue once, in order', () async {
      final channels = <FakeChannel>[];
      final delays = <Duration>[];
      final transport = WorkerRelayTransport(
        portFactory: () {
          final channel = FakeChannel();
          channels.add(channel);
          return channel;
        },
        delay: (delay) {
          delays.add(delay);
          return Future<void>.value();
        },
      );
      final states = <FaTransportState>[];
      final messages = <UiProtocolMessage>[];
      var drops = 0;
      final reconnected = <Reconnected>[];
      transport.events.listen((event) {
        switch (event) {
          case StateChanged(:final state):
            states.add(state);
          case ProtocolMessageReceived(:final message):
            messages.add(message);
          case Dropped():
            drops++;
          case Reconnected():
            reconnected.add(event);
        }
      });

      // connect: hello handshake, then attach (no remembered session yet).
      final connecting = transport.connect();
      await pump();
      expect(channels, hasLength(1));
      expect(channels[0].sentKinds, ['hello']);
      channels[0].receive(_ack());
      channels[0].receive(const AttachedMsg(sessionId: 's1', replay: []));
      await connecting;
      await pump();
      expect(transport.sessionId, 's1');

      // sendPrompt while attached: prompt on the wire, phase streaming.
      transport.sendPrompt('p1', 'hello fa');
      await pump();
      expect(channels[0].sentKinds, ['hello', 'attach', 'prompt']);

      // Stream events arrive as `stream` envelopes, event map verbatim.
      final delta = {'type': 'delta', 'text': 'he'};
      channels[0].receive(StreamMsg(event: delta));
      await pump();
      final streamEvents = [
        for (final message in messages)
          if (message is StreamMsg) message.event,
      ];
      expect(streamEvents.single, equals(delta));
      expect(transport.state, const TransportStreaming());

      // Force the channel closed mid-stream (E30): drop, then two failing
      // reopen attempts on the backoff schedule before one succeeds.
      channels[0].close();
      await pump();
      expect(channels, hasLength(2));
      expect(channels[1].sentKinds, ['hello']); // reopen restarts at hello
      channels[1].close();
      await pump();
      expect(channels, hasLength(3));
      channels[2].close();
      await pump();
      expect(channels, hasLength(4));

      // Composed while offline: queued in memory, survives the drop.
      transport.sendPrompt('p2', 'composed offline');
      transport.sendPrompt('p2', 'composed offline'); // double-send: dropped
      await pump();

      expect(delays, const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 500),
        Duration(seconds: 2),
      ]);
      expect(states, const [
        TransportConnecting(),
        TransportAttached(),
        TransportStreaming(),
        TransportReconnecting(nextAttemptIn: Duration(milliseconds: 100)),
        TransportReconnecting(nextAttemptIn: Duration(milliseconds: 500)),
        TransportReconnecting(nextAttemptIn: Duration(seconds: 2)),
      ]); // the closing attached arrives after the reopen below
      expect(drops, 3); // one Dropped per physical channel loss

      // The fourth channel completes hello/attach: Reconnected, then the
      // offline queue flushes exactly once, in order.
      channels[3].receive(_ack());
      channels[3].receive(const AttachedMsg(sessionId: 's1', replay: []));
      await pump();
      expect(reconnected.single.sessionId, 's1');
      expect(channels[3].sentKinds, ['hello', 'attach', 'prompt']);
      expect(channels[3].sent.last['id'], 'p2');
      expect(channels[3].sent.last['text'], 'composed offline');

      // p1 ran once in total; the duplicate p2 never reached any channel.
      final prompts = [
        for (final channel in channels)
          for (final message in channel.sent)
            if (message['kind'] == 'prompt') message,
      ];
      expect(prompts, hasLength(2)); // p1 + flushed p2
      expect(prompts.map((p) => p['id']), ['p1', 'p2']);
      expect(transport.state, const TransportAttached());
    });

    test('backoff caps at 15s forever', () async {
      final delays = <Duration>[];
      final retryTicks = <Completer<void>>[];
      final transport = WorkerRelayTransport(
        portFactory: () => throw StateError('worker gone'),
        delay: (delay) {
          delays.add(delay);
          // Manual firing: an always-immediate scheduler with a
          // permanently-throwing factory would loop forever and starve
          // the isolate's microtask queue.
          final tick = Completer<void>();
          retryTicks.add(tick);
          return tick.future;
        },
      );
      transport.connect(); // stays pending by contract while retrying
      for (var i = 0; i < 6; i++) {
        retryTicks.removeAt(0).complete();
        await pump();
      }
      expect(delays.take(5), const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 500),
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 15),
      ]);
      expect(delays[5], const Duration(seconds: 15));
    });

    test(
      'setSessionId drives attach; steer/cancel wire through when live',
      () async {
        final channel = FakeChannel();
        final transport = WorkerRelayTransport(portFactory: () => channel);
        transport.setSessionId('s-nine');
        final connecting = transport.connect();
        await pump();
        channel.receive(_ack());
        channel.receive(const AttachedMsg(sessionId: 's-nine', replay: []));
        await connecting;
        expect(channel.sentKinds, ['hello', 'attach']);
        expect(channel.sent.last['sessionId'], 's-nine');
        transport.steer('focus on the table');
        transport.cancel();
        await pump();
        expect(channel.sentKinds, ['hello', 'attach', 'steer', 'cancel']);
        expect(transport.state, const TransportAttached());
      },
    );
    test('steer/cancel while reconnecting are ignored, not queued', () async {
      final channels = <FakeChannel>[];
      final transport = WorkerRelayTransport(
        portFactory: () {
          final channel = FakeChannel();
          channels.add(channel);
          return channel;
        },
        delay: (_) => Future<void>.value(),
      );
      transport.connect();
      await pump();
      channels[0].receive(_ack());
      channels[0].receive(const AttachedMsg(sessionId: 's1', replay: []));
      await pump();
      channels[0].close();
      await pump();
      transport.steer('lost');
      transport.cancel();
      await pump();
      expect(channels[1].sentKinds, ['hello']); // nothing queued, nothing sent
    });

    test('attach replay surfaces as verbatim stream envelopes', () async {
      final channel = FakeChannel();
      final transport = WorkerRelayTransport(portFactory: () => channel);
      final messages = <UiProtocolMessage>[];
      transport.events.listen(
        (event) => switch (event) {
          ProtocolMessageReceived(:final message) => messages.add(message),
          _ => (),
        },
      );
      transport.connect();
      await pump();
      channel.receive(_ack());
      final replayed = {'type': 'delta', 'text': 'still streaming'};
      channel.receive(AttachedMsg(sessionId: 's1', replay: [replayed]));
      await pump();
      final stream = [
        for (final message in messages)
          if (message is StreamMsg) message.event,
      ];
      expect(stream.single, equals(replayed));
      expect(transport.state, const TransportStreaming()); // turn still live
    });

    test(
      'garbage inbound degrades to an error envelope, never throws',
      () async {
        final channel = FakeChannel();
        final transport = WorkerRelayTransport(portFactory: () => channel);
        final messages = <UiProtocolMessage>[];
        transport.events.listen(
          (event) => switch (event) {
            ProtocolMessageReceived(:final message) => messages.add(message),
            _ => (),
          },
        );
        transport.connect();
        await pump();
        channel.receive(_ack());
        channel.receive(const AttachedMsg(sessionId: 's1', replay: []));
        channel.receiveRaw({'nope': 1});
        await pump();
        expect(messages.whereType<ErrorMsg>().single.code, 'malformed');
        expect(transport.state, const TransportAttached());
      },
    );

    test(
      'unagreeable hello_ack fails connect() once and stops the loop',
      () async {
        final channel = FakeChannel();
        final transport = WorkerRelayTransport(
          portFactory: () => channel,
          delay: (_) => Future<void>.value(),
        );
        final connecting = transport.connect();
        await pump();
        channel.receive(
          const HelloAckMsg(
            protoVersion: 0,
            serverCapabilities: [],
            sessionId: null,
          ),
        );
        await expectLater(connecting, throwsA(isA<UiProtocolVersionError>()));
        expect(transport.state, const TransportDisconnected());
        expect(channel.isClosed, isTrue); // torn down, no further retries
        await pump();
        expect(channel.sentKinds, ['hello']); // no attach attempt followed
      },
    );
  });

  group('LocalStreamTransport (plain web, E31)', () {
    test('prompt reaches the stream function; events re-emit as port-identical '
        'envelopes; message_done ends the streaming phase', () async {
      final controller = StreamController<Map<String, dynamic>>();
      final prompts = <(String, String)>[];
      final transport = LocalStreamTransport(
        onPrompt: (id, text) {
          prompts.add((id, text));
          return controller.stream;
        },
      );
      final states = <FaTransportState>[];
      final messages = <UiProtocolMessage>[];
      transport.events.listen((event) {
        switch (event) {
          case StateChanged(:final state):
            states.add(state);
          case ProtocolMessageReceived(:final message):
            messages.add(message);
          case Dropped() || Reconnected():
            fail('local mode has no link to drop');
        }
      });

      await transport.connect();
      expect(transport.state, const TransportAttached());

      transport.sendPrompt('p1', 'hi');
      expect(prompts, const [('p1', 'hi')]);
      await pump();
      expect(transport.state, const TransportStreaming());

      final delta = {'type': 'delta', 'text': 'he'};
      controller.add(delta);
      controller.add(const {
        'type': 'message_done',
        'role': 'assistant',
        'text': 'he',
      });
      await pump();
      final stream = [
        for (final message in messages)
          if (message is StreamMsg) message.event,
      ];
      expect(stream.single, equals(delta)); // verbatim, as if from a port
      expect(messages.whereType<MessageDoneMsg>().single.message['text'], 'he');
      expect(states, const [
        TransportConnecting(),
        TransportAttached(),
        TransportStreaming(),
        TransportAttached(),
      ]);

      transport.sendPrompt('p1', 'hi'); // deduped after the turn too
      await pump();
      expect(prompts, const [('p1', 'hi')]);
      await controller.close();
    });

    test('a failing stream function surfaces as an error envelope', () async {
      final transport = LocalStreamTransport(
        onPrompt: (id, text) => throw StateError('boom'),
      );
      final messages = <UiProtocolMessage>[];
      transport.events.listen(
        (event) => switch (event) {
          ProtocolMessageReceived(:final message) => messages.add(message),
          _ => (),
        },
      );
      await transport.connect();
      transport.sendPrompt('p1', 'hi'); // must not throw into the UI loop
      await pump();
      final error = messages.whereType<ErrorMsg>().single;
      expect(error.code, 'local');
      expect(error.message, contains('boom'));
      expect(transport.state, const TransportAttached());
    });
  });

  group('detectTransport (UT-P5)', () {
    Stream<Map<String, dynamic>> local(String id, String text) =>
        const Stream.empty();

    test('null factory → local (no chrome.runtime at all)', () {
      expect(detectTransport(local: local), isA<LocalStreamTransport>());
    });

    test('throwing factory → local (E12: capability misdetection)', () {
      expect(
        detectTransport(
          portFactory: () => throw StateError('chrome.runtime missing'),
          local: local,
        ),
        isA<LocalStreamTransport>(),
      );
    });

    test('malformed factory (returns null) → local', () {
      expect(
        detectTransport(portFactory: () => null, local: local),
        isA<LocalStreamTransport>(),
      );
    });

    test(
      'working factory → worker relay, reusing the probed channel',
      () async {
        var built = 0;
        final channels = <FakeChannel>[];
        final transport = detectTransport(
          portFactory: () {
            built++;
            final channel = FakeChannel();
            channels.add(channel);
            return channel;
          },
          local: local,
        );
        expect(transport, isA<WorkerRelayTransport>());
        final connecting = (transport as WorkerRelayTransport).connect();
        await pump();
        expect(built, 1); // probe and first connect share one port
        expect(channels, hasLength(1));
        channels[0].receive(_ack());
        channels[0].receive(const AttachedMsg(sessionId: 's1', replay: []));
        await connecting;
      },
    );

    test(
      'forceOverride true forces the relay even with a throwing factory',
      () {
        expect(
          detectTransport(
            portFactory: () => throw StateError('ignored'),
            forceOverride: true,
            local: local,
          ),
          isA<WorkerRelayTransport>(),
        );
      },
    );

    test('forceOverride false forces local even with a working factory', () {
      expect(
        detectTransport(
          portFactory: FakeChannel.new,
          forceOverride: false,
          local: local,
        ),
        isA<LocalStreamTransport>(),
      );
    });

    test('a forced choice without its prerequisite is an argument error', () {
      expect(() => detectTransport(forceOverride: true), throwsArgumentError);
      expect(() => detectTransport(forceOverride: false), throwsArgumentError);
    });
  });
}
