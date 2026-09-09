import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _a(List<ContentBlock> content) => AssistantMessage(
  content: content,
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.toolUse,
  timestamp: DateTime.utc(2026),
);

AssistantMessage _text(String text) => _a([TextContent(text: text)]);

ToolCall _c(String id, String name) =>
    ToolCall(id: id, name: name, arguments: const {'x': 1});

ToolResultMessage _r(String id, String name) => ToolResultMessage(
  toolCallId: id,
  toolName: name,
  content: [TextContent(text: 'ok')],
  timestamp: DateTime.utc(2026),
  isError: false,
);

UserMessage _u(String text) =>
    UserMessage.text(text, timestamp: DateTime.utc(2026));

void main() {
  group('validateToolPairing (wire-equivalent sequence)', () {
    test('a clean transcript validates empty', () {
      final messages = [
        _u('hi'),
        _a([TextContent(text: 'working'), _c('c1', 'bash'), _c('c2', 'read')]),
        _r('c1', 'bash'),
        _r('c2', 'read'),
        _u('go on'),
        _text('done'),
      ];
      expect(validateToolPairing(messages), isEmpty);
    });

    test(
      'whitespace user text and blockless assistants are wire-invisible',
      () {
        final messages = [
          _u('   '),
          _a([]),
          _a([_c('c1', 'bash')]),
          _r('c1', 'bash'),
        ];
        expect(validateToolPairing(messages), isEmpty);
      },
    );

    test('a leading orphan result is flagged (any position)', () {
      final violations = validateToolPairing([_r('ghost', 'bash')]);
      expect(violations.single.kind, ToolPairingViolationKind.orphanedResult);
      expect(violations.single.toolCallId, 'ghost');
    });

    test('an orphan mid-context is flagged even inside a merged group', () {
      final messages = [
        _u('summary of earlier work'),
        _r('bash_198', 'bash'),
        _a([_c('c1', 'read')]),
        _r('c1', 'read'),
      ];
      final violations = validateToolPairing(messages);
      expect(violations.single.kind, ToolPairingViolationKind.orphanedResult);
      expect(violations.single.toolCallId, 'bash_198');
    });

    test('a steering user message between call and result is flagged', () {
      // Same-role merge: the steering text and the tool_result land in ONE
      // wire user message with the text FIRST — strict endpoints reject it.
      final messages = [
        _a([_c('c1', 'bash')]),
        _u('steering question'),
        _r('c1', 'bash'),
      ];
      expect(
        validateToolPairing(messages).map((v) => v.kind),
        contains(ToolPairingViolationKind.interleavedResult),
      );
    });

    test('a steering message between two results of one batch is flagged', () {
      final messages = [
        _a([_c('c1', 'bash'), _c('c2', 'read')]),
        _r('c1', 'bash'),
        _u('steering'),
        _r('c2', 'read'),
      ];
      final kinds = validateToolPairing(messages).map((v) => v.kind).toSet();
      expect(kinds, contains(ToolPairingViolationKind.interleavedResult));
    });

    test('an unanswered trailing call is flagged', () {
      final violations = validateToolPairing([
        _a([_c('c1', 'bash')]),
      ]);
      expect(violations.single.kind, ToolPairingViolationKind.unansweredCall);
    });

    test('duplicate ids across calls and results are flagged', () {
      final messages = [
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
        _r('c1', 'bash'),
      ];
      final kinds = validateToolPairing(messages).map((v) => v.kind).toSet();
      expect(
        kinds,
        containsAll(<ToolPairingViolationKind>[
          ToolPairingViolationKind.duplicateCallId,
          ToolPairingViolationKind.duplicateResult,
        ]),
      );
    });
  });

  group('repairToolPairing — orphaned results (UT-repair)', () {
    test('returns the same instance and empty report when valid', () {
      final messages = [
        _u('hi'),
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
      ];
      final repaired = repairToolPairing(messages);
      expect(identical(repaired.messages, messages), isTrue);
      expect(repaired.report.isNotEmpty, isFalse);
    });

    test('E1: an orphan as the ONLY message becomes the note (message 0)', () {
      final repaired = repairToolPairing([_r('bash', 'bash')]);
      expect(repaired.messages, hasLength(1));
      expect(
        (repaired.messages.single as UserMessage).content as String,
        contains('a tool result for "bash" (id: bash) was dropped'),
      );
      expect(validateToolPairing(repaired.messages), isEmpty);
    });

    test(
      'production shape: orphan after a compaction summary user message',
      () {
        final messages = [
          _u('summary of earlier work'),
          _r('bash_198', 'bash'),
        ];
        final repaired = repairToolPairing(messages);
        expect(repaired.messages, hasLength(2));
        expect(repaired.messages[0], same(messages[0]));
        expect(
          repaired.messages[1],
          isA<UserMessage>().having(
            (m) => m.content as String,
            'note',
            contains('bash_198'),
          ),
        );
        expect(validateToolPairing(repaired.messages), isEmpty);
        expect(repaired.report.droppedResultIds, ['bash_198']);
        // The transcript is never modified.
        expect(messages, hasLength(2));
      },
    );

    test('middle position: orphan dropped, note appended, rest untouched', () {
      final messages = [
        _u('hi'),
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
        _r('ghost', 'read'),
        _u('go on'),
      ];
      final repaired = repairToolPairing(messages);
      expect(repaired.messages, hasLength(5));
      expect(repaired.messages[0], same(messages[0]));
      expect(repaired.messages[2], same(messages[2]));
      expect(repaired.messages[3], same(messages[4]));
      expect(
        repaired.messages[4],
        isA<UserMessage>().having(
          (m) => m.content as String,
          'note',
          contains('"read"'),
        ),
      );
      expect(validateToolPairing(repaired.messages), isEmpty);
    });

    test(
      'second block of a merged group: orphan dropped, real result kept',
      () {
        final messages = [
          _a([_c('c1', 'bash'), _c('c2', 'read')]),
          _r('c1', 'bash'),
          _r('ghost', 'read'),
        ];
        final repaired = repairToolPairing(messages);
        final results = repaired.messages
            .whereType<ToolResultMessage>()
            .toList();
        expect(results.map((r) => r.toolCallId), ['c1', 'c2']);
        expect(validateToolPairing(repaired.messages), isEmpty);
      },
    );

    test('E2: multiple orphans repaired in one pass with one note', () {
      final messages = [
        _r('ghost1', 'bash'),
        _u('hi'),
        _a([_c('c1', 'read')]),
        _r('c1', 'read'),
        _r('ghost2', 'write'),
      ];
      final repaired = repairToolPairing(messages);
      expect(repaired.report.droppedResultIds, ['ghost1', 'ghost2']);
      final notes = repaired.messages
          .whereType<UserMessage>()
          .map((m) => m.content as String)
          .where((t) => t.startsWith('[context note:'))
          .toList();
      expect(notes, hasLength(1));
      expect(notes.single, contains('"bash"'));
      expect(notes.single, contains('"write"'));
      expect(validateToolPairing(repaired.messages), isEmpty);
    });

    test('repair is idempotent', () {
      final messages = [
        _u('hi'),
        _a([_c('c1', 'bash')]),
        _r('ghost', 'bash'),
      ];
      final first = repairToolPairing(messages);
      final second = repairToolPairing(first.messages);
      expect(identical(second.messages, first.messages), isTrue);
      expect(second.report.isNotEmpty, isFalse);
    });
  });
  group('repairToolPairing — steering interleave', () {
    test(
      'a user message between call and result is hoisted after the result',
      () {
        final steering = _u('steering question');
        final messages = [
          _u('hi'),
          _a([_c('c1', 'bash')]),
          steering,
          _r('c1', 'bash'),
        ];
        final repaired = repairToolPairing(messages);
        expect(repaired.messages[1], isA<AssistantMessage>());
        expect(repaired.messages[3], same(steering));
        expect(repaired.messages[2], isA<ToolResultMessage>());
        expect(validateToolPairing(repaired.messages), isEmpty);
      },
    );

    test('a user message between two results of one batch is hoisted', () {
      final steering = _u('steering');
      final messages = [
        _a([_c('c1', 'bash'), _c('c2', 'read')]),
        _r('c1', 'bash'),
        steering,
        _r('c2', 'read'),
      ];
      final repaired = repairToolPairing(messages);
      final results = repaired.messages.whereType<ToolResultMessage>().toList();
      expect(results.map((r) => r.toolCallId), ['c1', 'c2']);
      expect(repaired.messages.last, same(steering));
      expect(validateToolPairing(repaired.messages), isEmpty);
    });
  });

  group('repairToolPairing — duplicate ids (UT-dupes)', () {
    test('later occurrences are uniquified symmetrically', () {
      final messages = [
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
      ];
      final repaired = repairToolPairing(messages);
      expect(validateToolPairing(repaired.messages), isEmpty);

      final first = repaired.messages[0] as AssistantMessage;
      final second = repaired.messages[2] as AssistantMessage;
      expect((first.content[0] as ToolCall).id, 'c1');
      expect((second.content[0] as ToolCall).id, 'c1_2');
      expect(
        repaired.messages.whereType<ToolResultMessage>().map(
          (r) => r.toolCallId,
        ),
        ['c1', 'c1_2'],
      );
      expect(repaired.report.renamedIds, [(from: 'c1', to: 'c1_2')]);
    });

    test('renames skip ids already in use', () {
      final messages = [
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
        _a([_c('c1_2', 'read')]),
        _r('c1_2', 'read'),
        _a([_c('c1', 'bash')]),
        _r('c1', 'bash'),
      ];
      final repaired = repairToolPairing(messages);
      expect(validateToolPairing(repaired.messages), isEmpty);
      expect(repaired.report.renamedIds, [(from: 'c1', to: 'c1_3')]);
      final ids = [
        for (final m in repaired.messages)
          if (m is AssistantMessage)
            ...(m.content.whereType<ToolCall>().map((c) => c.id)),
      ];
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('repairToolPairing — unanswered calls', () {
    test('a call without its result gets the synthetic interrupted result', () {
      final messages = [
        _u('hi'),
        _a([_c('c1', 'bash')]),
      ];
      final repaired = repairToolPairing(messages);
      final result = repaired.messages[2] as ToolResultMessage;
      expect(result.toolCallId, 'c1');
      expect(result.toolName, 'bash');
      expect(result.isError, isTrue);
      expect(result.content.single, isA<TextContent>());
      expect(repaired.report.synthesizedResultIds, ['c1']);
      expect(validateToolPairing(repaired.messages), isEmpty);
    });
  });

  group('isToolPairingProviderError (E5 signatures)', () {
    test('matches the four known gateway families', () {
      expect(
        isToolPairingProviderError(
          'messages.0.content.1: unexpected tool_use_id found in tool_result '
          'blocks: bash_198. Each tool_result block must have a corresponding '
          'tool_use block in the previous message',
        ),
        isTrue,
      );
      expect(
        isToolPairingProviderError(
          'Expected toolResult blocks at messages.0.content for the following '
          'Ids: bash_198',
        ),
        isTrue,
      );
      expect(
        isToolPairingProviderError(
          '400 Bad Request: tool_call_id is not found in the previous '
          'messages',
        ),
        isTrue,
      );
      expect(
        isToolPairingProviderError(
          '400 Bad Request: Please ensure that the number of function '
          'response parts is equal to the number of function call parts of '
          'the function call turn.',
        ),
        isTrue,
      );
      expect(
        isToolPairingProviderError(
          "An assistant message with 'tool_calls' must be followed by tool "
          'messages responding to each '
          "'tool_call_id'. The following tool_call_ids did not have response "
          'messages: bash_198',
        ),
        isTrue,
      );
    });

    test('matching is case-insensitive', () {
      expect(
        isToolPairingProviderError('UNEXPECTED TOOL_USE_ID FOUND'),
        isTrue,
      );
    });

    test('other provider errors do not match', () {
      expect(isToolPairingProviderError('rate limit exceeded'), isFalse);
      expect(isToolPairingProviderError(null), isFalse);
      expect(isToolPairingProviderError(''), isFalse);
    });
  });

  group('canonical wire-form ids (PR #93 wire-view)', () {
    test('canonicalToolCallId mirrors the adapters', () {
      // Anthropic/Google/OpenAI _normalizeToolCallId: strip-outs become '_'.
      expect(canonicalToolCallId('call.1'), 'call_1');
      expect(canonicalToolCallId('call 1'), 'call_1');
      expect(canonicalToolCallId('call-OK_9'), 'call-OK_9');
      // 40-char cap (the strictest, OpenAI).
      expect(canonicalToolCallId('c' * 50), 'c' * 40);
    });

    test('raw ids that collapse to one wire id validate as duplicates', () {
      // `call.1` and `call_1` both hit the wire as `call_1`; raw comparison
      // passed this shape before, yet strict providers orphan the second.
      final violations = validateToolPairing([
        _a([_c('call.1', 'bash')]),
        _r('call.1', 'bash'),
        _u('next turn'),
        _a([_c('call_1', 'bash')]),
        _r('call_1', 'bash'),
      ]);
      expect(
        violations.map((v) => v.kind),
        containsAll([
          ToolPairingViolationKind.duplicateCallId,
          ToolPairingViolationKind.duplicateResult,
        ]),
      );
    });

    test('canonical collisions repair symmetrically to distinct wire ids', () {
      final messages = [
        _a([_c('call.1', 'bash')]),
        _r('call.1', 'bash'),
        _a([_c('call_1', 'bash')]),
        _r('call_1', 'bash'),
      ];
      final repaired = repairToolPairing(messages);
      expect(repaired.report.renamedIds, [(from: 'call_1', to: 'call_1_2')]);
      expect(validateToolPairing(repaired.messages), isEmpty);
      // On the wire the two results no longer collapse into one id.
      expect(
        repaired.messages
            .whereType<ToolResultMessage>()
            .map((m) => canonicalToolCallId(m.toolCallId))
            .toList(),
        ['call_1', 'call_1_2'],
      );
      // The transcript itself keeps its raw ids.
      expect((messages[1] as ToolResultMessage).toolCallId, 'call.1');
    });

    test('ids colliding past the 40-char wire cap still rename uniquely', () {
      final long1 = '${'a' * 45}1'; // wire form: 'a' * 40
      final long2 = '${'a' * 45}2'; // wire form: 'a' * 40 — same
      final messages = [
        _a([_c(long1, 'bash')]),
        _r(long1, 'bash'),
        _a([_c(long2, 'bash')]),
        _r(long2, 'bash'),
      ];
      final repaired = repairToolPairing(messages);
      expect(validateToolPairing(repaired.messages), isEmpty);
      final wireIds = repaired.messages
          .whereType<ToolResultMessage>()
          .map((m) => canonicalToolCallId(m.toolCallId))
          .toList();
      expect(wireIds.toSet(), hasLength(2));
    });
  });

  group('property: every cut of a random transcript repairs to a valid '
      'context (UT-property)', () {
    // Deterministic generator mimicking real sessions: per-run position
    // counter ids (the production duplicate source), sometimes missing
    // results, steering messages and stray orphans interleaved.
    List<Message> randomTranscript(Random rnd) {
      final messages = <Message>[];
      const batches = 4;
      for (var b = 0; b < batches; b++) {
        final callCount = 1 + rnd.nextInt(3);
        messages.add(
          _a([
            if (rnd.nextBool()) TextContent(text: 'batch $b'),
            for (var k = 0; k < callCount; k++) _c('c$k', 'bash'),
          ]),
        );
        for (var k = 0; k < callCount; k++) {
          if (rnd.nextDouble() < 0.85) messages.add(_r('c$k', 'bash'));
          if (rnd.nextDouble() < 0.15) messages.add(_u('steer $b/$k'));
        }
        if (rnd.nextDouble() < 0.2) messages.add(_r('ghost$b', 'read'));
        if (rnd.nextDouble() < 0.3) messages.add(_u('user $b'));
      }
      return messages;
    }

    test('every legal cut position yields a context passing the invariant', () {
      final rnd = Random(85);
      for (var iteration = 0; iteration < 150; iteration++) {
        final transcript = randomTranscript(rnd);
        for (var cut = 0; cut <= transcript.length; cut++) {
          final kept = transcript.sublist(cut);
          final repaired = repairToolPairing(kept);
          final violations = validateToolPairing(repaired.messages);
          expect(
            violations,
            isEmpty,
            reason: 'iteration $iteration cut $cut: $violations',
          );
        }
        // Whole-transcript repair is idempotent.
        final once = repairToolPairing(transcript);
        final twice = repairToolPairing(once.messages);
        expect(twice.report.isNotEmpty, isFalse);
        expect(identical(twice.messages, once.messages), isTrue);
      }
    });
  });
}
