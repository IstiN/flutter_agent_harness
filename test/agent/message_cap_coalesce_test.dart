// gh-1680 UT-4 / AC6 / AC7 — the coalesce step: adjacent tool-call/result
// pairs and old turns older than the newest user message merge into
// compact carrier messages; the pairing invariants hold on the wire; the
// newest user message and the kept tail are never touched; the input
// list is never mutated (the session JSONL stays byte-identical).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistantText(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

AssistantMessage _assistantCall(String id, String name) => AssistantMessage(
  content: [ToolCall(id: id, name: name, arguments: const {})],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.toolUse,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(String id, String name) => ToolResultMessage(
  toolCallId: id,
  toolName: name,
  content: [TextContent(text: 'result of $name')],
  isError: false,
  timestamp: DateTime.utc(2026),
);

/// A transcript with several tool-call/result pairs around user turns.
List<Message> transcript() => [
  UserMessage.text('first question'),
  _assistantCall('c1', 'read'),
  _result('c1', 'read'),
  _assistantText('thinking about it'),
  _assistantCall('c2', 'bash'),
  _result('c2', 'bash'),
  _assistantCall('c3', 'write'),
  _result('c3', 'write'),
  UserMessage.text('second question'),
  _assistantCall('c4', 'read'),
  _result('c4', 'read'),
  UserMessage.text('newest question — must survive verbatim'),
];

void main() {
  group('coalesceMessagesForCap (UT-4, AC6)', () {
    test('merges old tool pairs + turns into compact carriers under the '
        'target, keeping the newest user message verbatim', () {
      final input = transcript();
      final before = [...input];
      final out = coalesceMessagesForCap(input, targetMessageCount: 4);

      expect(out.length, lessThanOrEqualTo(4));
      // The newest user message is the LAST message, untouched.
      expect(out.last, same(input.last));
      expect(
        (out.last as UserMessage).content,
        'newest question — must survive verbatim',
      );
      // The input list itself is never mutated (AC7: the session JSONL
      // stays byte-identical — repair is outbound-only).
      expect(input, orderedEquals(before));
      // Carriers describe what they merged.
      final carriers = out.whereType<UserMessage>().toList();
      expect(carriers.length, greaterThanOrEqualTo(1));
      expect(
        carriers.any((c) => (c.content as String).contains('[coalesced')),
        isTrue,
      );
    });

    test('2+ tool pairs in the droppable region merge (not just one)', () {
      final input = transcript();
      final out = coalesceMessagesForCap(input, targetMessageCount: 3);
      // Three tool pairs (c1..c3) plus a text turn lived before the cut;
      // all of them are gone from the wire shape as separate messages.
      final ids = [
        for (final m in out)
          if (m is AssistantMessage)
            for (final call in m.content.whereType<ToolCall>()) call.id,
      ];
      expect(ids, isNot(contains('c1')));
      expect(ids, isNot(contains('c2')));
      expect(ids, isNot(contains('c3')));
    });

    test('pairing invariants hold on the wire after coalescing (AC6)', () {
      final input = transcript();
      for (final target in [2, 3, 4, 6]) {
        final out = coalesceMessagesForCap(input, targetMessageCount: target);
        final wire = validateToolPairing(out);
        expect(wire, isEmpty, reason: 'target=$target: $wire');
      }
    });

    test('a transcript already under target is returned unchanged', () {
      final input = transcript();
      final out = coalesceMessagesForCap(input, targetMessageCount: 100);
      expect(identical(out, input), isTrue);
    });

    test('nothing droppable (only one message): returned unchanged (E3)', () {
      final single = [UserMessage.text('only turn')];
      expect(
        identical(
          coalesceMessagesForCap(single, targetMessageCount: 1),
          single,
        ),
        isTrue,
      );
    });

    test('the cut never lands mid tool-pair: an over-target tail keeps a '
        'whole trailing pair', () {
      // transcript ends user/c4/result; with target 2 the newest user
      // message anchors the cut, so c4+result (after the newest user)…
      // actually they are BEFORE the newest user. Either way the wire must
      // stay pairing-valid and keep the newest user message.
      final input = transcript();
      final out = coalesceMessagesForCap(input, targetMessageCount: 2);
      expect(out.length, lessThanOrEqualTo(2));
      expect(out.last, same(input.last));
      expect(validateToolPairing(out), isEmpty);
    });

    test('pre-broken pairing in the input is repaired, never propagated', () {
      final broken = [
        UserMessage.text('older'),
        _assistantCall('x1', 'read'),
        _result('x1', 'read'),
        UserMessage.text('newest'),
        _result('orphan', 'read'), // orphan after the newest user message
      ];
      final out = coalesceMessagesForCap(broken, targetMessageCount: 3);
      expect(validateToolPairing(out), isEmpty);
      // The orphan result is dropped by the pairing repair — never sent.
      expect(
        out.any((m) => m is ToolResultMessage && m.toolCallId == 'orphan'),
        isFalse,
      );
      // The newest user message survives (it anchors the kept tail) — the
      // pairing repair may merge it into a multi-block carrier, so match
      // on the serialized form.
      expect(
        out.any(
          (m) => m is UserMessage && m.toJson().toString().contains('newest'),
        ),
        isTrue,
      );
    });

    test('text-only old turns merge too (not only tool pairs)', () {
      final input = [
        _assistantText('old answer one'),
        UserMessage.text('newest'),
      ];
      final out = coalesceMessagesForCap(input, targetMessageCount: 1);
      expect(out.length, lessThanOrEqualTo(1 + 1));
      expect(out.last, same(input.last));
    });
  });

  group('steering interleave across the newest-user cut (PR #1695)', () {
    test('a tool call whose result rides the kept tail stays verbatim — '
        'the pairing repair hoists the result back, content survives', () {
      // The review probe: a steering user message sits BETWEEN the call
      // and its result, and that steering message is the newest user
      // message — so the call is in the droppable region while its
      // result rides the kept tail.
      final input = [
        UserMessage.text('older turn'),
        _assistantCall('c1', 'read'),
        UserMessage.text('newest steering'),
        _result('c1', 'read'),
      ];
      final out = coalesceMessagesForCap(input, targetMessageCount: 2);

      expect(validateToolPairing(out), isEmpty);
      // The pair is WHOLE on the wire: both the call and its result
      // survived (the result content was previously dropped as an
      // orphan — the call merged into a carrier while the result
      // stayed in the tail).
      expect(
        out.any(
          (m) =>
              m is AssistantMessage &&
              m.content.whereType<ToolCall>().any((c) => c.id == 'c1'),
        ),
        isTrue,
      );
      expect(
        out.any(
          (m) => m is ToolResultMessage && m.toolCallId == 'c1',
        ),
        isTrue,
      );
      // The result CONTENT made it onto the wire (not a synthesized
      // placeholder, not a note).
      expect(
        out.any(
          (m) =>
              m is ToolResultMessage &&
              m.toolCallId == 'c1' &&
              m.toJson().toString().contains('result of read'),
        ),
        isTrue,
      );
      // The steering user message still anchors the tail verbatim.
      expect(out.last, same(input[2]));
      // The input list is never mutated (AC7).
      expect(input, hasLength(4));
    });

    test('a mid-region steering interleave keeps the pair verbatim too', () {
      // The steering user message is NOT the newest — the result
      // answering the call sits inside the droppable region, displaced
      // from it. Both must survive verbatim (nothing of the pair may
      // merge into a carrier).
      final input = [
        UserMessage.text('older turn'),
        _assistantCall('c1', 'read'),
        UserMessage.text('mid steering'),
        _result('c1', 'read'),
        UserMessage.text('newest question — must survive verbatim'),
      ];
      final out = coalesceMessagesForCap(input, targetMessageCount: 3);

      expect(validateToolPairing(out), isEmpty);
      expect(
        out.any(
          (m) =>
              m is AssistantMessage &&
              m.content.whereType<ToolCall>().any((c) => c.id == 'c1'),
        ),
        isTrue,
      );
      expect(
        out.any(
          (m) =>
              m is ToolResultMessage &&
              m.toolCallId == 'c1' &&
              m.toJson().toString().contains('result of read'),
        ),
        isTrue,
      );
      expect(out.last, same(input.last));
    });
  });
}
