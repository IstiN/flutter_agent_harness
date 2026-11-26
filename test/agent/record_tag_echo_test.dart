// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

/// gh-2412: record tags ride the wire copy only — a reply that echoes its
/// own alias (`m3212 Ответил владельцу…`, fa 1.0.777 CLI TUI) must join
/// the transcript without it, and with tags off the text is untouched.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant([List<ContentBlock> content = const []]) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant([TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// Replays one scripted turn per call.
class _FakeStream {
  _FakeStream(this.turns);
  final List<List<AssistantMessageEvent>> turns;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

String _textOf(AssistantMessage message) =>
    message.content.whereType<TextContent>().map((b) => b.text).join('|');

void main() {
  group('stripRecordTagEcho (pure)', () {
    test('"m3212 Ответил…" → the first text block opens with the words', () {
      final stripped = stripRecordTagEcho(
        _assistant([TextContent(text: 'm3212 Ответил владельцу с телефона')]),
      );
      expect(_textOf(stripped), 'Ответил владельцу с телефона');
      expect(messageHasRecordTag(stripped), isFalse);
    });

    test('a reply that is only its alias ("m3208") keeps NO text block', () {
      final stripped = stripRecordTagEcho(
        _assistant([TextContent(text: 'm3208')]),
      );
      expect(stripped.content.whereType<TextContent>(), isEmpty);
      expect(messageHasRecordTag(stripped), isFalse);
    });

    test('an alias at a line start deeper in the reply is stripped too', () {
      final stripped = stripRecordTagEcho(
        _assistant([TextContent(text: 'Сделано.\nm12 продолжение\nконец')]),
      );
      expect(_textOf(stripped), 'Сделано.\nпродолжение\nконец');
    });

    test('a legitimate `m3u8` opening is not an alias', () {
      final legit = _assistant([TextContent(text: 'm3u8 stream opens here')]);
      expect(stripRecordTagEcho(legit), same(legit));
    });

    test('tool calls and thinking are never touched', () {
      final thinking = ThinkingContent(thinking: 'm7 my private notes');
      final call = ToolCall(
        id: 'c1',
        name: 'read',
        arguments: {'path': 'm3 is a legit value'},
      );
      final stripped = stripRecordTagEcho(
        _assistant([thinking, TextContent(text: 'm5 читаю'), call]),
      );
      expect(stripped.content[0], same(thinking));
      expect(stripped.content[2], same(call));
      expect(_textOf(stripped), 'читаю');
    });

    test('a clean reply is returned as the same instance', () {
      final clean = _assistant([TextContent(text: 'просто ответ')]);
      expect(stripRecordTagEcho(clean), same(clean));
    });
  });

  group('the agent finalize seam', () {
    test('tags on: the echoed alias never joins the transcript (state, '
        'listeners, turn end) and the usage survives', () async {
      final fake = _FakeStream([_textTurn('m3212 Ответил владельцу')]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      )..recordTagsEnabled = true;
      final ended = <Message>[];
      final turnEnds = <Message>[];
      agent.subscribe((event, _) {
        if (event is MessageEndEvent) ended.add(event.message);
        if (event is TurnEndEvent) turnEnds.add(event.message);
      });

      await agent.prompt('hi');

      final reply = agent.state.messages.whereType<AssistantMessage>().single;
      expect(_textOf(reply), 'Ответил владельцу');
      expect(messageHasRecordTag(reply), isFalse);
      // The user turn's message end is announced too — the assistant
      // filter leaves the reply alone.
      expect(
        _textOf(ended.whereType<AssistantMessage>().single),
        'Ответил владельцу',
      );
      expect(
        _textOf(turnEnds.whereType<AssistantMessage>().single),
        'Ответил владельцу',
      );
    });

    test(
      "tags off: the text is the model's own and survives untouched",
      () async {
        final fake = _FakeStream([
          _textTurn('m42 opens this answer legitimately'),
        ]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        )..recordTagsEnabled = false;

        await agent.prompt('hi');

        final reply = agent.state.messages.whereType<AssistantMessage>().single;
        expect(_textOf(reply), 'm42 opens this answer legitimately');
      },
    );
  });
}
