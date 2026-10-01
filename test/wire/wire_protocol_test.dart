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

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/rate_limit_info.dart';
import 'package:flutter_agent_harness/src/tools/request_secret_tool.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';
import 'package:test/test.dart';

import 'golden_fixtures.dart';

void main() {
  final eventFixtures = loadGoldenFixtures(eventFixturesDir);
  final commandFixtures = loadGoldenFixtures(commandFixturesDir);

  GoldenFixture fixtureFor(String dir, String name) =>
      loadGoldenFixtures(dir).firstWhere((f) => f.path.endsWith('$name.json'));

  group('UT-1: golden event round-trips', () {
    test('fixture corpus is non-empty and versioned v1', () {
      expect(eventFixtures, isNotEmpty);
      expect(commandFixtures, isNotEmpty);
      for (final f in [...eventFixtures, ...commandFixtures]) {
        expect(f.protocolVersion, 1, reason: f.path);
      }
    });

    test('all 12 nested message_update variants have goldens', () {
      const variants = [
        'start',
        'text_start',
        'text_delta',
        'text_end',
        'thinking_start',
        'thinking_delta',
        'thinking_end',
        'tool_call_start',
        'tool_call_delta',
        'tool_call_end',
        'done',
        'error',
      ];
      for (final variant in variants) {
        expect(
          () => fixtureFor(eventFixturesDir, 'message_update_$variant'),
          returnsNormally,
          reason: 'missing golden for message_update_$variant',
        );
      }
      expect(
        eventFixtures.where((f) => f.kind == 'message_update'),
        hasLength(variants.length),
      );
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
        if (serverEventKinds.contains(fixture.kind)) {
          // Server-emitted kinds (fa wire-serve, #1103) have no native
          // engine event: hosts decode them as the passthrough and read
          // `code`/`message` off the raw frame.
          final decoded = protocol.decodeEvent(fixture.frame);
          expect(decoded, isA<UnknownWireEvent>(), reason: fixture.path);
          expect((decoded as UnknownWireEvent).kind, fixture.kind);
          expect(decoded.raw['code'], isA<String>(), reason: fixture.path);
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
        (f) =>
            f.kind != 'unknown_event' &&
            !requestEventKinds.contains(f.kind) &&
            !serverEventKinds.contains(f.kind),
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
            'x_future_field': {
              'a': [1, 2],
            },
          };
          final decoded = protocol.decodeEvent(withExtra);
          expect(
            decoded,
            fixture.kind == 'unknown_event' ||
                    serverEventKinds.contains(fixture.kind)
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
          () => protocol.decodeCommand({
            'v': 1,
            'kind': 'ask_response',
            'id': 'a',
          }),
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
      expect(() => loadGoldenFixtures(tmp.path), throwsA(isA<StateError>()));
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
      final accepted = AgentWireProtocol.acceptHello(
        hello,
        caps: ['streaming'],
      );
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

    test('the hello frame version is accepted, then ignored', () {
      // The frame's own `v` caps only this frame's encoding: a hello SENT
      // in a frame version outside this server's support is accepted when
      // the `versions` array names a shared one — negotiation reads the
      // array, not the frame version.
      final accepted = AgentWireProtocol.acceptHello({
        'v': 99,
        'kind': 'hello',
        'versions': [1],
      });
      expect(accepted.protocol.version, 1);
      expect(accepted.welcome['version'], 1);
      // No shared version in the array — the single loud gate.
      expect(
        () => AgentWireProtocol.acceptHello({
          'v': 99,
          'kind': 'hello',
          'versions': [99],
        }),
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
        () => AgentWireProtocol.acceptHello({'v': 'x', 'kind': 'hello'}),
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
      final frame = accepted.protocol.encodeEvent(
        nativeEventFor('agent_start'),
      );
      expect(frame['v'], accepted.protocol.version);
    });
  });

  group('E4: secrets over the wire', () {
    test('isSecretField marks rawBody anywhere', () {
      expect(
        AgentWireProtocol.isSecretField('secret_response', 'value'),
        isTrue,
      );
      expect(
        AgentWireProtocol.isSecretField('model_request', 'rawWireDump'),
        isTrue,
      );
      expect(AgentWireProtocol.isSecretField('message_end', 'rawBody'), isTrue);
      // The anywhere-rule is NOT dead for registry kinds: a rawBody under
      // secret_response must still be marked (?? fell through on false).
      expect(
        AgentWireProtocol.isSecretField('secret_response', 'rawBody'),
        isTrue,
      );
      expect(
        AgentWireProtocol.isSecretField('secret_response', 'name'),
        isFalse,
      );
      expect(AgentWireProtocol.isSecretField('prompt', 'text'), isFalse);
    });

    test('redactForLog anywhere-rule survives registry kinds', () {
      // ?? binds looser than ||: a registry kind with secretFields=={value}
      // must STILL redact a stray rawBody (the round-2 precedence bug).
      final protocol = AgentWireProtocol();
      final frame = protocol.encodeCommand(nativeCommandFor('secret_response'));
      frame['rawBody'] = 'TOP-LEVEL-STRAY';
      final redacted = AgentWireProtocol.redactForLog(frame);
      expect(redacted['rawBody'], '[REDACTED:secret_response]');
      expect(frame['rawBody'], 'TOP-LEVEL-STRAY');
      // Nested stray under a registry kind too.
      final nested = AgentWireProtocol.redactForLog({
        'v': 1,
        'kind': 'secret_response',
        'id': 'x',
        'wrapper': {'rawBody': 'NESTED'},
      });
      expect(
        (nested['wrapper'] as Map)['rawBody'],
        '[REDACTED:secret_response]',
      );
    });

    test('markers are kind-qualified per the layered pipeline format', () {
      // Unknown-kind frames still get a parseable marker.
      final foreign = AgentWireProtocol.redactForLog({
        'v': 1,
        'kind': 'foreign_kind',
        'rawBody': 'x',
      });
      expect(foreign['rawBody'], '[REDACTED:foreign_kind]');
      // A frame without a kind at all degrades to the unknown label.
      final kindless = AgentWireProtocol.redactForLog({'rawBody': 'x'});
      expect(kindless['rawBody'], '[REDACTED:unknown]');
      // Markers match the pipeline's existing-marker pattern.
      expect(
        RegExp(
          r'^\[REDACTED:[^\]\n]*\]$',
        ).hasMatch(foreign['rawBody'] as String),
        isTrue,
      );
    });

    test('session_control params are loud-optional', () {
      final protocol = AgentWireProtocol();
      // Absent params = empty map (encoder omits when empty).
      final noParams = protocol.decodeCommand({
        'v': 1,
        'kind': 'session_control',
        'op': 'compact',
      });
      expect((noParams as WireSessionControlCommand).params, isEmpty);
      // A PRESENT non-map is malformed.
      expect(
        () => protocol.decodeCommand({
          'v': 1,
          'kind': 'session_control',
          'op': 'compact',
          'params': 'nope',
        }),
        throwsA(isA<WireProtocolException>()),
      );
    });

    test('repair report decoder is loud on missing keys', () {
      final protocol = AgentWireProtocol();
      final repair = fixtureFor(eventFixturesDir, 'tool_pairing_repair').frame;
      // Missing droppedResultIds silently becoming [] is malformed.
      expect(
        () => protocol.decodeEvent({
          ...repair,
          'report': {
            ...(repair['report'] as Map<String, dynamic>)
              ..remove('droppedResultIds'),
          },
        }),
        throwsA(isA<WireProtocolException>()),
      );
      // A rename entry without `to` is malformed, not an empty id.
      expect(
        () => protocol.decodeEvent({
          ...repair,
          'report': {
            ...(repair['report'] as Map<String, dynamic>),
            'renamedIds': [
              {'from': 'a'},
            ],
          },
        }),
        throwsA(isA<WireProtocolException>()),
      );
    });

    test('rateLimit.rawBody never rides a wire frame', () {
      final protocol = AgentWireProtocol();
      AssistantMessage rateLimited() => AssistantMessage(
        content: const [TextContent(text: 'quota')],
        api: 'openai-completions',
        provider: 'openai',
        model: 'gpt-test',
        usage: const Usage(
          input: 1,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 1,
          cost: UsageCost(),
        ),
        stopReason: StopReason.error,
        errorMessage: 'usage limit reached',
        rateLimit: const RateLimitInfo(
          planType: 'free',
          rawBody: 'LIVE-429-RAW-BODY',
        ),
        timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
      );
      // Single-message embeddings…
      final messageEnd = protocol.encodeEvent(MessageEndEvent(rateLimited()));
      expect(jsonEncode(messageEnd), isNot(contains('LIVE-429-RAW-BODY')));
      expect(jsonEncode(messageEnd), isNot(contains('rawBody')));
      // …and list embeddings (agent_end)…
      final agentEnd = protocol.encodeEvent(AgentEndEvent([rateLimited()]));
      expect(jsonEncode(agentEnd), isNot(contains('LIVE-429-RAW-BODY')));
      // …while the structured rate-limit data still rides.
      expect((messageEnd['message'] as Map<String, dynamic>)['rateLimit'], {
        'planType': 'free',
      });
      // The live in-process object keeps the diagnostics payload.
      expect(rateLimited().rateLimit!.rawBody, 'LIVE-429-RAW-BODY');
    });

    test('redactForLog strips a nested rawBody from a foreign frame', () {
      // A frame that arrived from another host may carry the diagnostics
      // body nested under rateLimit inside a message; the log copy must
      // still lose it.
      final redacted = AgentWireProtocol.redactForLog({
        'v': 1,
        'kind': 'message_end',
        'message': {
          'role': 'assistant',
          'rateLimit': {'planType': 'free', 'rawBody': 'FOREIGN-RAW-BODY'},
        },
        'messages': [
          {
            'role': 'assistant',
            'rateLimit': {'rawBody': 'FOREIGN-RAW-2'},
          },
        ],
      });
      expect(jsonEncode(redacted), isNot(contains('FOREIGN-RAW-BODY')));
      expect(jsonEncode(redacted), isNot(contains('FOREIGN-RAW-2')));
      expect(
        ((redacted['message'] as Map<String, dynamic>)['rateLimit']
            as Map<String, dynamic>)['rawBody'],
        '[REDACTED:message_end]',
      );
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
      expect(redacted['value'], '[REDACTED:secret_response]');
      // The live frame keeps the value (the engine needs it); only LOG
      // copies are redacted.
      expect(frame['value'], secret);
      expect(jsonEncode(frame), contains(secret));
    });

    test('model_request rawWireDump is redactable', () {
      final protocol = AgentWireProtocol();
      final frame = protocol.encodeEvent(nativeEventFor('model_request'));
      final redacted = AgentWireProtocol.redactForLog(frame);
      expect(redacted['rawWireDump'], '[REDACTED:model_request]');
      expect(jsonEncode(redacted), isNot(contains('raw-wire-dump')));
    });

    test('fixtures never carry a live secret', () {
      for (final fixture in [...eventFixtures, ...commandFixtures]) {
        final secretFields = fixture.frame.keys
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
          expect(
            redacted[field],
            '[REDACTED:${fixture.frame['kind']}]',
            reason: fixture.path,
          );
          expect(
            jsonEncode(redacted),
            isNot(contains(fixture.frame[field])),
            reason: fixture.path,
          );
        }
      }
    });
  });

  group('declared exception contract', () {
    test('unsupported frame versions throw WireVersionError', () {
      final protocol = AgentWireProtocol();
      expect(
        () => protocol.decodeEvent({'v': 2, 'kind': 'agent_start'}),
        throwsA(isA<WireVersionError>()),
      );
      expect(
        () => protocol.decodeCommand({'v': 2, 'kind': 'prompt', 'text': 'hi'}),
        throwsA(isA<WireVersionError>()),
      );
      expect(
        () => protocol.decodeEvent({'kind': 'agent_start'}),
        throwsA(isA<WireVersionError>()),
      );
    });

    test('malformed known frames never escape as raw TypeError', () {
      final protocol = AgentWireProtocol();
      // Non-string optional field: was an unchecked `as String?` cast.
      final modelRequest = fixtureFor(eventFixturesDir, 'model_request').frame;
      expect(
        () => protocol.decodeEvent({...modelRequest, 'rawWireDump': 42}),
        throwsA(isA<WireProtocolException>()),
      );
      // A nested fromJson TypeError is wrapped into the declared type
      // (toolCall.arguments as a non-map is a hard cast in types.dart).
      final toolCallEnd = fixtureFor(
        eventFixturesDir,
        'message_update_tool_call_end',
      ).frame;
      expect(
        () => protocol.decodeEvent({
          ...toolCallEnd,
          'event': {
            ...(toolCallEnd['event'] as Map<String, dynamic>),
            'toolCall': {
              ...((toolCallEnd['event'] as Map<String, dynamic>)['toolCall']
                  as Map<String, dynamic>),
              'arguments': 'not-a-map',
            },
          },
        }),
        throwsA(isA<WireProtocolException>()),
      );
      // Unknown-kind tolerance (E3) is untouched by the wrap.
      expect(
        protocol.decodeEvent({'v': 1, 'kind': 'future_widget', 'x': 1}),
        isA<UnknownWireEvent>(),
      );
    });

    test('nested event decode is loud on corrupt payloads', () {
      final protocol = AgentWireProtocol();
      // Unknown stop reason degrades LOUDLY, not to StopReason.stop.
      final done = fixtureFor(eventFixturesDir, 'message_update_done').frame;
      expect(
        () => protocol.decodeEvent({
          ...done,
          'event': {
            ...(done['event'] as Map<String, dynamic>),
            'reason': 'banana',
          },
        }),
        throwsA(isA<WireProtocolException>()),
      );
      // Optional blobs decode only from objects.
      final modelRequest = fixtureFor(eventFixturesDir, 'model_request').frame;
      expect(
        () => protocol.decodeEvent({...modelRequest, 'promptBlob': 'x'}),
        throwsA(isA<WireProtocolException>()),
      );
      // Index-kind nested events require their content index.
      final textDelta = fixtureFor(
        eventFixturesDir,
        'message_update_text_delta',
      ).frame;
      expect(
        () => protocol.decodeEvent({
          ...textDelta,
          'event': {...(textDelta['event'] as Map<String, dynamic>)}
            ..remove('contentIndex'),
        }),
        throwsA(isA<WireProtocolException>()),
      );
    });

    test('nested FormatException surfaces as the declared type', () {
      final protocol = AgentWireProtocol();
      // messageFromJson throws FormatException on an unknown role - it
      // must not escape decodeEvent raw.
      final agentEnd = fixtureFor(eventFixturesDir, 'agent_end').frame;
      expect(
        () => protocol.decodeEvent({
          ...agentEnd,
          'messages': [
            {'role': 'martian', 'content': []},
          ],
        }),
        throwsA(isA<WireProtocolException>()),
      );
    });

    test('ask decoders are loud on missing keys', () {
      final protocol = AgentWireProtocol();
      final askRequest = fixtureFor(eventFixturesDir, 'ask_request').frame;
      Map<String, dynamic> clobbered(Map<String, dynamic> question) => {
        ...askRequest,
        'questions': [question],
      };
      // Missing question text silently becoming '' hid producer bugs.
      expect(
        () => protocol.decodeEvent(
          clobbered({
            'options': [
              {'label': 'SQLite'},
            ],
            'multiSelect': false,
          }),
        ),
        throwsA(isA<WireProtocolException>()),
      );
      // Missing options silently becoming [] did too.
      expect(
        () => protocol.decodeEvent(
          clobbered({'question': 'Which database?', 'multiSelect': false}),
        ),
        throwsA(isA<WireProtocolException>()),
      );
      // Missing multiSelect silently becoming false did too.
      expect(
        () => protocol.decodeEvent(
          clobbered({
            'question': 'Which database?',
            'options': [
              {'label': 'SQLite'},
            ],
          }),
        ),
        throwsA(isA<WireProtocolException>()),
      );
      // An option without a label is malformed, not an empty label.
      expect(
        () => protocol.decodeEvent(
          clobbered({
            'question': 'Which database?',
            'options': [
              {'description': 'no label here'},
            ],
            'multiSelect': false,
          }),
        ),
        throwsA(isA<WireProtocolException>()),
      );
      // Same philosophy for answers, but `selected` is absent-legal: the
      // encoder omits it for freeText-only answers, so a missing key is
      // the empty default while a WRONG-TYPED key is loud.
      final askResponse = fixtureFor(commandFixturesDir, 'ask_response').frame;
      final freeTextOnly = protocol.decodeCommand({
        ...askResponse,
        'cancelled': false,
        'answers': [
          {'freeText': 'postgres'},
        ],
      });
      expect(freeTextOnly, isA<WireAskResponseCommand>());
      expect(
        (freeTextOnly as WireAskResponseCommand).answers?.single.selected,
        isEmpty,
      );
      expect(
        () => protocol.decodeCommand({
          ...askResponse,
          'cancelled': false,
          'answers': [
            {'selected': 'postgres'},
          ],
        }),
        throwsA(isA<WireProtocolException>()),
      );
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
      final parsed = AgentWireProtocol.parseLine(
        AgentWireProtocol.frameLine(frame),
      );
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
