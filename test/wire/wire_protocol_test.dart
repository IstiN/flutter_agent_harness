// Agent Wire Protocol v1 — conformance tests (issue #1101 slice 1).
//
// UT-1: every fixture kind round-trips with golden fixtures; unknown-field
//       and unknown-kind tolerance asserted.
// UT-2: hello/welcome handshake, downgrade negotiation, loud unsupported
//       version error.
// E4:   secret-class fields are marked and redactable for logs.
// Framing: NDJSON line rules.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/tools/request_secret_tool.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';
import 'package:test/test.dart';

import 'golden_fixtures.dart';

void main() {
  final eventFixtures = loadGoldenFixtures(eventFixturesDir);
  final commandFixtures = loadGoldenFixtures(commandFixturesDir);

  GoldenFixture fixtureFor(String dir, String name) => loadGoldenFixtures(
    dir,
  ).firstWhere((f) => f.path.endsWith('$name.json'));

  group('UT-1: golden event round-trips', () {
    test('fixture corpus is non-empty and versioned v1', () {
      expect(eventFixtures, isNotEmpty);
      expect(commandFixtures, isNotEmpty);
      for (final f in [...eventFixtures, ...commandFixtures]) {
        expect(f.protocolVersion, 1, reason: f.path);
      }
    });

    for (final fixture in eventFixtures) {
      test('round-trip ${fixture.kind} (${fixture.path.split('/').last})', () {
        final protocol = AgentWireProtocol();
        if (fixture.kind == 'unknown_event') {
          // unknown_event is the documented degradation form; decoding it
          // surfaces the passthrough, and it can be re-encoded.
          final decoded = protocol.decodeEvent(fixture.frame);
          expect(decoded, isA<UnknownWireEvent>());
          final unknown = decoded as UnknownWireEvent;
          expect(unknown.kind, 'future_widget');
          expect(
            protocol.encodeUnknownEvent(
              originalKind: 'future_widget',
              payload: {'size': 3},
            ),
            fixture.frame,
          );
          return;
        }
        final decoded = protocol.decodeEvent(fixture.frame);
        if (requestEventKinds.contains(fixture.kind)) {
          // Host-interaction requests decode to RequestWireEvent and
          // re-encode from their native payloads to the same frame.
          expect(decoded, isA<RequestWireEvent>(), reason: fixture.path);
          final request = decoded as RequestWireEvent;
          expect(request.kind, fixture.kind);
          final reEncoded = switch (fixture.kind) {
            'approval_request' => protocol.encodeApprovalRequest(
              id: request.requestId,
              request: request.approval!,
            ),
            'ask_request' => protocol.encodeAskRequest(
              id: request.requestId,
              questions: request.questions,
            ),
            _ => protocol.encodeSecretRequest(
              id: request.requestId,
              name: request.secretName!,
              reason: request.secretReason!,
            ),
          };
          expect(reEncoded, fixture.frame, reason: fixture.path);
          return;
        }
        expect(decoded, isA<KnownWireEvent>(), reason: fixture.path);
        final event = (decoded as KnownWireEvent).event;
        final reEncoded = protocol.encodeEvent(event);
        expect(reEncoded, fixture.frame, reason: fixture.path);
      });
    }

    test('natively-built events encode to their golden frames', () {
      final protocol = AgentWireProtocol();
      // Request frames are pinned through their native payload builders
      // in the round-trip branch above.
      final corpus = eventFixtures.where(
        (f) => f.kind != 'unknown_event' && !requestEventKinds.contains(f.kind),
      );
      for (final fixture in corpus) {
        final fileName = fixture.path.split('/').last.replaceAll('.json', '');
        final native = fixture.kind == 'message_update'
            ? nativeMessageUpdateFor(fileName)
            : nativeEventFor(fixture.kind);
        expect(
          protocol.encodeEvent(native),
          fixture.frame,
          reason: 'native $fileName must encode to its golden frame',
        );
      }
      expect(
        protocol.encodeApprovalRequest(
          id: 'ap_1',
          request: nativeApprovalRequest(),
        ),
        fixtureFor(eventFixturesDir, 'approval_request').frame,
      );
      expect(
        protocol.encodeAskRequest(id: 'ask_1', questions: nativeAskQuestions()),
        fixtureFor(eventFixturesDir, 'ask_request').frame,
      );
      final (name, reason) = nativeSecretRequest();
      expect(
        protocol.encodeSecretRequest(id: 'sec_1', name: name, reason: reason),
        fixtureFor(eventFixturesDir, 'secret_request').frame,
      );
    });

    group('unknown-field tolerance', () {
      for (final fixture in eventFixtures) {
        test('${fixture.kind} ignores unknown fields', () {
          final protocol = AgentWireProtocol();
          final withExtra = <String, dynamic>{
            ...fixture.frame,
            'x_future_field': {'a': [1, 2]},
          };
          final decoded = protocol.decodeEvent(withExtra);
          expect(
            decoded,
            fixture.kind == 'unknown_event'
                ? isA<UnknownWireEvent>()
                : requestEventKinds.contains(fixture.kind)
                ? isA<RequestWireEvent>()
                : isA<KnownWireEvent>(),
            reason: fixture.path,
          );
        });
      }
    });

    test('unknown event kind degrades to documented passthrough', () {
      final protocol = AgentWireProtocol();
      final decoded = protocol.decodeEvent({
        'v': 1,
        'kind': 'brand_new_kind',
        'stuff': true,
      });
      expect(decoded, isA<UnknownWireEvent>());
      final unknown = decoded as UnknownWireEvent;
      expect(unknown.kind, 'brand_new_kind');
      expect(unknown.raw['stuff'], true);
    });

    group('golden command frames', () {
      for (final fixture in commandFixtures) {
        test('round-trip ${fixture.kind}', () {
          final protocol = AgentWireProtocol();
          final decoded = protocol.decodeCommand(fixture.frame);
          expect(protocol.encodeCommand(decoded), fixture.frame);
        });
      }

      test('unknown command kind surfaces as passthrough', () {
        final protocol = AgentWireProtocol();
        final decoded = protocol.decodeCommand({
          'v': 1,
          'kind': 'future_command',
          'x': 1,
        });
        expect(decoded, isA<WireUnknownCommand>());
        expect((decoded as WireUnknownCommand).kind, 'future_command');
      });

      test('malformed command frames fail loud', () {
        final protocol = AgentWireProtocol();
        expect(
          () => protocol.decodeCommand({'v': 1, 'kind': 'prompt'}),
          throwsA(isA<WireProtocolException>()),
        );
        expect(
          () => protocol.decodeCommand({'v': 1, 'kind': 'prompt', 'text': 42}),
          throwsA(isA<WireProtocolException>()),
        );
        expect(
          () => protocol.decodeCommand({'v': 1, 'kind': 'ask_response', 'id': 'a'}),
          throwsA(isA<WireProtocolException>()),
        );
      });
    });

    test('fixture loader fails loud on missing keys', () async {
      final tmp = await Directory.systemTemp.createTemp('wire-fixture-');
      addTearDown(() => tmp.delete(recursive: true));
      File('${tmp.path}/broken.json').writeAsStringSync('{"kind":"x"}');
      expect(
        () => loadGoldenFixtures(tmp.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing required key "protocolVersion"'),
          ),
        ),
      );
    });

    test('fixture loader fails loud on kind mismatch', () async {
      final tmp = await Directory.systemTemp.createTemp('wire-fixture-');
      addTearDown(() => tmp.delete(recursive: true));
      File('${tmp.path}/broken.json').writeAsStringSync(
        '{"kind":"prompt","protocolVersion":1,"frame":{"v":1,"kind":"steer"}}',
      );
      expect(
        () => loadGoldenFixtures(tmp.path),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('UT-2: handshake and versioning', () {
    test('v1 hello negotiates to v1 welcome', () {
      final protocol = AgentWireProtocol();
      final hello = protocol.hello(versions: [1], caps: ['streaming']);
      expect(hello, {
        'v': 1,
        'kind': 'hello',
        'versions': [1],
        'caps': ['streaming'],
      });
      final accepted = AgentWireProtocol.acceptHello(hello, caps: ['streaming']);
      expect(accepted.protocol.version, 1);
      expect(accepted.welcome, {
        'v': 1,
        'kind': 'welcome',
        'version': 1,
        'caps': ['streaming'],
      });
    });

    test('multi-version client is downgraded to the shared version', () {
      // A v2-capable client talking to a v1-only server: negotiation picks
      // the highest shared version and every later frame is framed at it.
      final accepted = AgentWireProtocol.acceptHello(
        AgentWireProtocol(version: 1).hello(versions: [2, 1]),
      );
      expect(accepted.protocol.version, 1);
      expect(accepted.welcome['version'], 1);
    });

    test('unsupported version is a LOUD handshake error', () {
      expect(
        () => AgentWireProtocol.acceptHello(
          AgentWireProtocol(version: 1).hello(versions: [99]),
        ),
        throwsA(isA<WireVersionError>()),
      );
      expect(
        () => AgentWireProtocol.acceptHello(
          AgentWireProtocol(version: 1).hello(versions: [2]),
        ),
        throwsA(isA<WireVersionError>()),
      );
    });

    test('malformed hello frames fail loud with the reason', () {
      expect(
        () => AgentWireProtocol.acceptHello({'v': 1, 'kind': 'welcome'}),
        throwsA(isA<WireProtocolException>()),
      );
      expect(
        () => AgentWireProtocol.acceptHello({'v': 1, 'kind': 'hello'}),
        throwsA(isA<WireProtocolException>()),
      );
      expect(
        () => AgentWireProtocol.acceptHello({
          'v': 1,
          'kind': 'hello',
          'versions': [],
        }),
        throwsA(isA<WireProtocolException>()),
      );
      expect(
        () => AgentWireProtocol.acceptHello({
          'v': 1,
          'kind': 'hello',
          'versions': ['1'],
        }),
        throwsA(isA<WireProtocolException>()),
      );
      expect(
        () => AgentWireProtocol.acceptHello({
          'v': 99,
          'kind': 'hello',
          'versions': [1],
        }),
        throwsA(isA<WireVersionError>()),
      );
    });

    test('protocol refuses construction at an unsupported version', () {
      expect(
        () => AgentWireProtocol(version: 2),
        throwsA(isA<WireVersionError>()),
      );
    });

    test('negotiated protocol frames every event at its version', () {
      // Post-handshake every frame must carry the negotiated version — the
      // downgrade filter's visible effect at v1.
      final accepted = AgentWireProtocol.acceptHello(
        AgentWireProtocol(version: 1).hello(versions: [2, 1]),
      );
      final frame = accepted.protocol.encodeEvent(nativeEventFor('agent_start'));
      expect(frame['v'], accepted.protocol.version);
    });
  });

  group('E4: secrets over the wire', () {
    test('secret-class fields are marked', () {
      expect(AgentWireProtocol.isSecretField('secret_response', 'value'), isTrue);
      expect(AgentWireProtocol.isSecretField('model_request', 'rawWireDump'), isTrue);
      expect(AgentWireProtocol.isSecretField('secret_response', 'name'), isFalse);
      expect(AgentWireProtocol.isSecretField('prompt', 'text'), isFalse);
    });

    test('redactForLog strips secret values, never mutates the input', () {
      final protocol = AgentWireProtocol();
      const secret = 'super-secret-value';
      final frame = protocol.encodeCommand(
        const WireSecretResponseCommand(
          id: 'sec_1',
          result: RequestSecretResult(name: 'TOK', value: secret),
        ),
      );
      final redacted = AgentWireProtocol.redactForLog(frame);
      expect(jsonEncode(redacted), isNot(contains(secret)));
      expect(redacted['value'], '[REDACTED]');
      // The live frame keeps the value (the engine needs it); only LOG
      // copies are redacted.
      expect(frame['value'], secret);
      expect(jsonEncode(frame), contains(secret));
    });

    test('model_request rawWireDump is redactable', () {
      final protocol = AgentWireProtocol();
      final frame = protocol.encodeEvent(nativeEventFor('model_request'));
      final redacted = AgentWireProtocol.redactForLog(frame);
      expect(redacted['rawWireDump'], '[REDACTED]');
      expect(jsonEncode(redacted), isNot(contains('raw-wire-dump')));
    });

    test('fixtures never carry a live secret', () {
      for (final fixture in [...eventFixtures, ...commandFixtures]) {
        final secretFields =
            fixture.frame.keys
                .where(
                  (field) => AgentWireProtocol.isSecretField(
                    fixture.frame['kind'] as String,
                    field,
                  ),
                )
                .toList();
        if (secretFields.isEmpty) continue;
        // Secret-class fields in the corpus are placeholders that
        // redaction rewrites — nothing here is a real credential.
        final redacted = AgentWireProtocol.redactForLog(fixture.frame);
        for (final field in secretFields) {
          expect(redacted[field], '[REDACTED]', reason: fixture.path);
          expect(
            jsonEncode(redacted),
            isNot(contains(fixture.frame[field])),
            reason: fixture.path,
          );
        }
      }
    });
  });

  group('NDJSON framing', () {
    test('frameLine emits one newline-terminated JSON object', () {
      final line = AgentWireProtocol.frameLine({'v': 1, 'kind': 'abort'});
      expect(line.endsWith('\n'), isTrue);
      expect(line.trim().split('\n'), hasLength(1));
      expect(jsonDecode(line.trim()), {'v': 1, 'kind': 'abort'});
    });

    test('parseLine round-trips frameLine', () {
      final frame = fixtureFor(commandFixturesDir, 'prompt').frame;
      final parsed = AgentWireProtocol.parseLine(AgentWireProtocol.frameLine(frame));
      expect(parsed, frame);
    });

    test('parseLine skips blank lines', () {
      expect(AgentWireProtocol.parseLine(''), isNull);
      expect(AgentWireProtocol.parseLine('   \n'), isNull);
    });

    test('parseLine fails loud on garbage and non-objects', () {
      expect(
        () => AgentWireProtocol.parseLine('not json'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AgentWireProtocol.parseLine('[1,2]'),
        throwsA(isA<WireProtocolException>()),
      );
    });
  });
}
