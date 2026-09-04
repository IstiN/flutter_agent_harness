// Bridge wire protocol (pure Dart): frame round-trips, strict decode,
// token/mailbox helpers, reconnect backoff, and the bounded LRU deduper.
@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeFrame round-trips', () {
    final cases = <String, Map<String, dynamic>>{
      'hello': {
        'agentId': 'e1',
        'name': 'My Extension',
        'proto': 1,
        'token': 'ab' * 32,
        'caps': ['tabs', 'dom', 'cdp'],
      },
      'welcome': {
        'mailbox': 'browser-ext/e1',
        'server': 'fa/1.0.0',
        'capabilities': ['mail', 'browser'],
      },
      'mail': {
        'from': 'main',
        'text': 'hi',
        'ts': '2026-01-01T00:00:00.000Z',
        'msgId': 'm1',
      },
      'mail with user kind': {
        'from': 'app',
        'text': 'hi',
        'ts': '2026-01-01T00:00:00.000Z',
        'msgId': 'm2',
        'kind': 'user',
      },
      'acked': {},
      'ping': {},
      'pong': {},
      'browserReq': {
        'req': 'navigate',
        'args': {'url': 'https://example.test'},
      },
      'browserRes ok': {
        'ok': true,
        'result': {'tabId': 7},
      },
      'browserRes error': {'ok': false, 'error': 'boom', 'code': 'no_tab'},
      'error': {'code': 'bad_token', 'error': 'pairing token rejected'},
    };

    for (final MapEntry(key: name, value: fields) in cases.entries) {
      test('encode→decode preserves a $name frame', () {
        final frame = BridgeFrame(
          id: '123-abcdef1',
          op: name.split(' ').first,
          fields: fields,
        );
        final decoded = BridgeFrame.decode(frame.encode());
        expect(decoded.id, '123-abcdef1');
        expect(decoded.op, frame.op);
        expect(decoded.fields, fields);
      });
    }

    test('the wire envelope carries v first, then id and op', () {
      final json =
          jsonDecode(BridgeFrame(id: '1-aa', op: 'ping').encode())
              as Map<String, dynamic>;
      expect(json['v'], bridgeProtocolVersion);
      expect(json['id'], '1-aa');
      expect(json['op'], 'ping');
      expect(json.keys.take(3), ['v', 'id', 'op']);
    });

    test(
      'envelope keys are reserved: a payload shadow never leaks on the wire',
      () {
        final frame = BridgeFrame(
          id: '1-bb',
          op: 'mail',
          fields: {'to': 'main', 'v': 'not the protocol version'},
        );
        final decoded = BridgeFrame.decode(frame.encode());
        expect(decoded.str('to'), 'main');
        // The envelope v wins; the payload shadow is not round-tripped.
        expect(decoded.fields.containsKey('v'), isFalse);
      },
    );
  });

  group('BridgeFrame.decode strictness', () {
    test('non-JSON text is a bad_frame', () {
      expect(
        () => BridgeFrame.decode('this is not json'),
        throwsA(
          isA<BridgeProtocolException>().having(
            (e) => e.code,
            'code',
            BridgeErrorCode.badFrame,
          ),
        ),
      );
    });

    test('a non-object JSON body is a bad_frame', () {
      expect(
        () => BridgeFrame.decode('[1,2,3]'),
        throwsA(
          isA<BridgeProtocolException>().having(
            (e) => e.code,
            'code',
            BridgeErrorCode.badFrame,
          ),
        ),
      );
    });

    test('a version mismatch is a proto error echoing the frame id', () {
      try {
        BridgeFrame.decode(jsonEncode({'v': 2, 'id': '9-ff', 'op': 'ping'}));
        fail('should have thrown');
      } on BridgeProtocolException catch (error) {
        expect(error.code, BridgeErrorCode.proto);
        expect(error.inReplyTo, '9-ff');
      }
    });

    test('a missing or empty id is a bad_frame', () {
      for (final id in [null, '']) {
        expect(
          () =>
              BridgeFrame.decode(jsonEncode({'v': 1, 'id': id, 'op': 'ping'})),
          throwsA(
            isA<BridgeProtocolException>().having(
              (e) => e.code,
              'code',
              BridgeErrorCode.badFrame,
            ),
          ),
        );
      }
    });

    test('a missing op is a bad_frame echoing the id', () {
      try {
        BridgeFrame.decode(jsonEncode({'v': 1, 'id': '5-ee'}));
        fail('should have thrown');
      } on BridgeProtocolException catch (error) {
        expect(error.code, BridgeErrorCode.badFrame);
        expect(error.inReplyTo, '5-ee');
      }
    });

    test('str and map accessors tolerate missing or mistyped fields', () {
      final frame = BridgeFrame(
        id: '1-cc',
        op: 'hello',
        fields: {'token': 42, 'args': 'not a map'},
      );
      expect(frame.str('token'), isNull);
      expect(frame.map('args'), isNull);
      expect(frame.str('agentId'), isNull);
    });
  });

  group('error codes', () {
    test('wire names are stable snake_case strings', () {
      expect(BridgeErrorCode.badToken.wire, 'bad_token');
      expect(BridgeErrorCode.noTarget.wire, 'no_target');
      expect(BridgeErrorCode.nodeVanished.wire, 'node_vanished');
      expect(BridgeErrorCode.restrictedPage.wire, 'restricted_page');
      expect(BridgeErrorCode.badOp.wire, 'bad_op');
    });

    test('fromWire round-trips every code and rejects unknowns', () {
      for (final code in BridgeErrorCode.values) {
        expect(BridgeErrorCode.fromWire(code.wire), code);
      }
      expect(BridgeErrorCode.fromWire('totally_bogus'), isNull);
    });

    test('every code has a unique wire name', () {
      expect(
        BridgeErrorCode.values.map((c) => c.wire).toSet().length,
        BridgeErrorCode.values.length,
      );
    });
  });

  group('pairing tokens and mailbox ids', () {
    test('pairingToken is 64 lowercase hex chars and fresh every time', () {
      final first = pairingToken();
      final second = pairingToken();
      expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(first, isNot(second));
    });

    test('randomMailboxSuffix is 8 lowercase hex chars', () {
      expect(randomMailboxSuffix(), matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('deriveMailboxId namespaces and sanitizes the agent id', () {
      expect(deriveMailboxId('e1'), 'browser-ext/e1');
      expect(deriveMailboxId('explore:a1'), 'browser-ext/explore_a1');
      expect(deriveMailboxId('a b/c'), 'browser-ext/a_b_c');
    });
  });

  group('bridgeBackoff', () {
    test('doubles from 1s and caps at 30s (contract table)', () {
      final expected = [
        for (var attempt = 1; attempt <= 12; attempt++)
          switch (attempt) {
            1 => const Duration(seconds: 1),
            2 => const Duration(seconds: 2),
            3 => const Duration(seconds: 4),
            4 => const Duration(seconds: 8),
            5 => const Duration(seconds: 16),
            _ => const Duration(seconds: 30),
          },
      ];
      expect([
        for (var attempt = 1; attempt <= 12; attempt++) bridgeBackoff(attempt),
      ], expected);
    });

    test('extreme attempts stay at the cap (clamp before shift)', () {
      // `1 << (attempt - 1)` collapses to 0 under 64-bit shift semantics
      // once attempt passes ~64 — the regression the DAP client hit.
      expect(bridgeBackoff(64), const Duration(seconds: 30));
      expect(bridgeBackoff(65), const Duration(seconds: 30));
      expect(bridgeBackoff(10000), const Duration(seconds: 30));
      expect(bridgeBackoff(0), const Duration(seconds: 1));
    });
  });

  group('MailDeduper', () {
    test('a re-observed id inside the window is a duplicate', () {
      final deduper = MailDeduper();
      expect(deduper.isDuplicate('m1'), isFalse);
      expect(deduper.isDuplicate('m1'), isTrue);
      expect(deduper.isDuplicate('m1'), isTrue);
      expect(deduper.isDuplicate('m2'), isFalse);
    });

    test(
      'eviction is LRU: a re-observed id survives, a stale one falls out',
      () {
        final deduper = MailDeduper(capacity: 3);
        for (final id in ['a', 'b', 'c']) {
          expect(deduper.isDuplicate(id), isFalse);
        }
        // Re-observe `a` — it moves to the newest slot.
        expect(deduper.isDuplicate('a'), isTrue);
        // Inserting `d` evicts `b` (oldest), not the refreshed `a`.
        expect(deduper.isDuplicate('d'), isFalse);
        expect(deduper.isDuplicate('b'), isFalse); // evicted → forwarded again
        expect(deduper.isDuplicate('a'), isTrue); // still remembered
      },
    );

    test('the default window is the contract capacity of 512', () {
      final deduper = MailDeduper();
      expect(deduper.capacity, 512);
      for (var i = 0; i < 512; i++) {
        expect(deduper.isDuplicate('id-$i'), isFalse);
      }
      for (var i = 0; i < 512; i++) {
        expect(deduper.isDuplicate('id-$i'), isTrue);
      }
      // The 513th id evicts id-0; re-seeing it forwards again.
      expect(deduper.isDuplicate('id-512'), isFalse);
      expect(deduper.isDuplicate('id-0'), isFalse);
    });
  });

  group('nextFrameId', () {
    test('is <epochMs>-<8 hex rand> (sortable, collision-safe)', () {
      final id = nextFrameId();
      expect(id, matches(RegExp(r'^\d+-[0-9a-f]{8}$')));
      final ms = int.parse(id.split('-').first);
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(now - ms, lessThan(5000));
    });

    test('successive ids never share a full id (collision-safe)', () {
      final ids = {for (var i = 0; i < 1000; i++) nextFrameId()};
      expect(ids, hasLength(1000));
    });

    test('fresh ids differ from earlier ones', () {
      final a = nextFrameId();
      final b = nextFrameId();
      expect(a, isNot(b));
    });
  });
}
