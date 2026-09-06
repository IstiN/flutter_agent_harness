// FaUiProtocol (ui_protocol.dart): envelope encode/decode round-trips for
// every kind with field fidelity, never-throw decode (unknown kind / byte
// garbage → structured error), version negotiation table, verbatim
// EventRelay streaming, PromptDeduper LRU semantics. UT-P1..P3, issue #30.
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';

// The package has no lib/ — the SW entry compiles src/ directly.
import '../src/ui_protocol.dart';

const _fragments = ['héllo', '日本語', '🦄', '𝕏', 'plain', ''];

Object? _randScalar(Random rng) => switch (rng.nextInt(5)) {
  0 => rng.nextInt(1 << 20),
  1 => (rng.nextInt(1000) - 500) + rng.nextDouble(),
  2 => _fragments[rng.nextInt(_fragments.length)] * (1 + rng.nextInt(3)),
  3 => rng.nextBool(),
  _ => null,
};

Map<String, dynamic> _randMap(Random rng, int depth) {
  final m = <String, dynamic>{};
  for (var i = rng.nextInt(5); i > 0; i--) {
    final key =
        '${_fragments[rng.nextInt(_fragments.length)]}#${rng.nextInt(50)}';
    m[key] = _randValue(rng, depth);
  }
  return m;
}

Object? _randValue(Random rng, int depth) {
  if (depth >= 2) return _randScalar(rng);
  return switch (rng.nextInt(7)) {
    0 => rng.nextInt(1 << 20),
    1 => (rng.nextInt(1000) - 500) + rng.nextDouble(),
    2 => _fragments[rng.nextInt(_fragments.length)] * (1 + rng.nextInt(3)),
    3 => rng.nextBool(),
    4 => null,
    5 => List.generate(rng.nextInt(4), (_) => _randValue(rng, depth + 1)),
    _ => _randMap(rng, depth + 1),
  };
}

void main() {
  group('UT-P1: encode/decode', () {
    test('round-trips every kind with field fidelity', () {
      final cases = <UiProtocolMessage>[
        const HelloMsg(protoVersion: 2, capabilities: ['stream', 'approvals']),
        const HelloAckMsg(
          protoVersion: 2,
          serverCapabilities: ['stream'],
          sessionId: 's1',
        ),
        // Optional field absent on the wire.
        const HelloAckMsg(
          protoVersion: 2,
          serverCapabilities: [],
          sessionId: null,
        ),
        const AttachMsg(sessionId: null, lastEventId: null),
        const AttachMsg(sessionId: 's1', lastEventId: 'evt-9'),
        const AttachedMsg(
          sessionId: 's1',
          replay: [
            {'type': 'text', 'delta': 'héllo'},
            {'n': 1},
          ],
        ),
        const PromptMsg(id: 'p1', text: 'héllo 🌍 日本語'),
        const SteerMsg(text: 'stop after this tool'),
        const CancelMsg(),
        const StreamMsg(event: {'type': 'text', 'delta': 'hi'}),
        const MessageDoneMsg(message: {'role': 'assistant', 'text': 'done'}),
        const ApprovalRequestMsg(
          id: 'a1',
          call: {
            'tool': 'fetch',
            'args': [1, 'x'],
          },
          reason: 'network access',
        ),
        const ApprovalResponseMsg(id: 'a1', decision: 'allow'),
        const ApprovalResponseMsg(
          id: 'a1',
          decision: 'deny',
          updates: {
            'args': [2],
          },
        ),
        const SessionsQueryMsg(),
        const SessionsResultMsg(
          sessions: [
            {'id': 's1', 'title': 'x'},
          ],
        ),
        const SettingsQueryMsg(),
        const SettingsPutMsg(settings: {'theme': 'dark', 'n': 3}),
        const SettingsResultMsg(settings: {'theme': 'dark', 'n': 3}),
        const ErrorMsg(code: 'boom', message: 'nope'),
      ];
      for (final msg in cases) {
        final back = UiProtocolMessage.decodeJson(jsonEncode(msg.encode()));
        expect(back.kind, msg.kind, reason: 'kind of ${msg.runtimeType}');
        expect(
          back.encode(),
          msg.encode(),
          reason: 'fields of ${msg.runtimeType}',
        );
      }
    });

    test('unknown kind decodes to a structured unknown_kind error', () {
      final err = UiProtocolMessage.decodeJson('{"kind":"wat","x":1}');
      expect(err, isA<ErrorMsg>());
      expect((err as ErrorMsg).code, 'unknown_kind');
      expect(err.message, contains('wat'));
    });

    test('non-string or missing kind is malformed, never thrown', () {
      for (final json in [
        {'kind': 42},
        {'noKind': true},
      ]) {
        final msg = UiProtocolMessage.decode(json);
        expect(msg, isA<ErrorMsg>(), reason: '$json');
        expect((msg as ErrorMsg).code, 'malformed', reason: '$json');
      }
    });

    test('malformed JSON never throws and yields malformed errors', () {
      for (final raw in [
        '{',
        'not json',
        '',
        '[1,2]',
        '"text"',
        '42',
        'null',
        'true',
        '{"kind":',
        // Wrong types on required fields.
        '{"kind":"prompt"}',
        '{"kind":"prompt","id":1,"text":"x"}',
        '{"kind":"hello","protoVersion":"2","capabilities":[]}',
        '{"kind":"stream","event":[1]}',
        '{"kind":"attached","sessionId":"s","replay":"nope"}',
        '{"kind":"hello","protoVersion":2,"capabilities":[1,2]}',
      ]) {
        final msg = UiProtocolMessage.decodeJson(raw);
        expect(msg, isA<ErrorMsg>(), reason: raw);
        expect((msg as ErrorMsg).code, 'malformed', reason: raw);
      }
    });

    test('protocol constants', () {
      expect(uiProtocolVersion, 2);
      expect(uiProtocolMinVersion, 1);
    });
  });

  group('UT-P1: version negotiation', () {
    test('equal versions agree', () {
      expect(negotiateVersion(2, 2), 2);
    });

    test('server-higher agrees on the client version', () {
      expect(negotiateVersion(2, 3), 2);
    });

    test('client-higher agrees on the minimum', () {
      expect(negotiateVersion(3, 2), 2);
    });

    test('floor version still negotiates', () {
      expect(negotiateVersion(1, 2), 1);
    });

    test('version 0 refuses and carries both claims', () {
      expect(
        () => negotiateVersion(0, 2),
        throwsA(
          isA<UiProtocolVersionError>()
              .having((e) => e.mine, 'mine', 0)
              .having((e) => e.theirs, 'theirs', 2),
        ),
      );
      expect(
        () => negotiateVersion(2, 0),
        throwsA(
          isA<UiProtocolVersionError>()
              .having((e) => e.mine, 'mine', 2)
              .having((e) => e.theirs, 'theirs', 0),
        ),
      );
    });
  });

  group('UT-P2: EventRelay verbatim streaming', () {
    test('forwards 200 randomized events byte-identical (seeded)', () {
      final rng = Random(42);
      final inputs = <Map<String, dynamic>>[];
      final outs = <Map<String, dynamic>>[];
      final relay = EventRelay(sink: outs.add);

      for (var i = 0; i < 200; i++) {
        final event = _randMap(rng, 0); // includes empty maps
        inputs.add(event);
        relay.emit(event);
      }

      expect(outs.length, 200);
      for (var i = 0; i < 200; i++) {
        expect(
          identical(outs[i], inputs[i]),
          isTrue,
          reason: 'event $i was rebuilt, not passed through',
        );
        expect(
          jsonEncode(outs[i]),
          jsonEncode(inputs[i]),
          reason: 'event $i not byte-identical',
        );
      }
    });
  });

  group('UT-P3: PromptDeduper', () {
    test('same id twice → true, false', () {
      final d = PromptDeduper();
      expect(d.register('p1'), isTrue);
      expect(d.register('p1'), isFalse);
    });

    test('1024 distinct ids evict id #1', () {
      final d = PromptDeduper();
      for (var i = 1; i <= 1024; i++) {
        expect(d.register('p$i'), isTrue, reason: 'p$i');
      }
      expect(d.register('p1'), isTrue); // evicted when the window filled
      expect(d.register('p1024'), isFalse); // newest of the window, resident
      expect(d.register('p1025'), isTrue); // fresh; evicts p3, new oldest
      expect(d.register('p3'), isTrue); // now gone
      expect(d.register('p1024'), isFalse); // still resident
    });

    test('out-of-order ids all distinct → all true', () {
      final d = PromptDeduper();
      for (final id in ['q3', 'a1', 'z9', 'b2', 'm5']) {
        expect(d.register(id), isTrue, reason: id);
      }
      expect(d.register('a1'), isFalse); // remembered regardless of order
    });

    test('repeat refreshes LRU recency', () {
      final d = PromptDeduper(capacity: 3);
      expect(d.register('a'), isTrue);
      expect(d.register('b'), isTrue);
      expect(d.register('a'), isFalse); // refresh: a becomes newest
      expect(d.register('c'), isTrue); // evicts b, not a
      expect(d.register('a'), isFalse); // a survived the eviction
      expect(d.register('b'), isTrue); // b is gone
    });
  });
}
