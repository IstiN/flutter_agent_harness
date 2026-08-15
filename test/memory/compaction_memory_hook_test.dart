@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/memory/compaction_memory_hook.dart';
import 'package:flutter_agent_harness/src/memory/memory_controller.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'openai',
  provider: 'openai-completions',
  baseUrl: 'http://localhost:1',
  contextWindow: 128000,
  maxTokens: 4096,
);

AssistantMessage _assistant(
  String text, {
  StopReason reason = StopReason.stop,
}) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai',
    provider: 'openai-completions',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: reason,
    timestamp: DateTime.utc(2026),
  );
}

/// A [StreamFunction] fake that emits one scripted assistant message (or
/// throws / errors per [behavior]).
StreamFunction _streamWith(
  String text, {
  bool throwOnCall = false,
  StopReason reason = StopReason.stop,
}) {
  return (model, context, {cancelToken}) {
    if (throwOnCall) {
      throw StateError('network down');
    }
    final message = _assistant(text, reason: reason);
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: message));
    stream.push(DoneEvent(reason: reason, message: message));
    stream.end();
    return stream;
  };
}

void main() {
  group('parseExtractedEntries', () {
    test('parses a plain JSON array', () {
      final entries = parseExtractedEntries(
        '[{"text":"prefer riverpod","type":"note","tags":["state"]}]',
      );
      expect(entries, hasLength(1));
      expect(entries.single.text, 'prefer riverpod');
      expect(entries.single.tags, ['state']);
    });

    test('parses a fenced JSON array', () {
      final entries = parseExtractedEntries(
        '```json\n[{"text":"deploys on Fridays are banned"}]\n```',
      );
      expect(entries, hasLength(1));
      expect(entries.single.text, 'deploys on Fridays are banned');
    });

    test('parses JSON embedded in prose (outermost span)', () {
      final entries = parseExtractedEntries(
        'Here you go:\n[{"text":"uses SQLite for cache"}]\nGood luck!',
      );
      expect(entries, hasLength(1));
      expect(entries.single.text, 'uses SQLite for cache');
    });

    test('empty array yields no entries', () {
      expect(parseExtractedEntries('[]'), isEmpty);
    });

    test('malformed JSON yields no entries (skip silently)', () {
      expect(parseExtractedEntries('no json here'), isEmpty);
      expect(parseExtractedEntries('[{"text": ]'), isEmpty);
    });

    test('entries with empty text are dropped', () {
      final entries = parseExtractedEntries('[{"text":"  "},{"text":"ok"}]');
      expect(entries, hasLength(1));
      expect(entries.single.text, 'ok');
    });

    test('topics and tags are capped at 3', () {
      final entries = parseExtractedEntries(
        '[{"text":"x","topics":["a","b","c","d"],"tags":["1","2","3","4"]}]',
      );
      expect(entries.single.topics, hasLength(3));
      expect(entries.single.tags, hasLength(3));
    });
  });

  group('extractDurableEntries', () {
    test('returns entries from a scripted model response', () async {
      final entries = await extractDurableEntries(
        _streamWith('[{"text":"the project uses Dart 3"}]'),
        _model,
        'some conversation span',
      );
      expect(entries, hasLength(1));
      expect(entries.single.text, 'the project uses Dart 3');
    });

    test('model error stop reason yields no entries', () async {
      final entries = await extractDurableEntries(
        _streamWith('ignored', reason: StopReason.error),
        _model,
        'span',
      );
      expect(entries, isEmpty);
    });

    test('the span is capped with head+tail', () async {
      String? seenPrompt;
      StreamFunction capture = (model, context, {cancelToken}) {
        seenPrompt = context.systemPrompt;
        final message = _assistant('[]');
        final stream = AssistantMessageEventStream();
        stream.push(StartEvent(partial: message));
        stream.push(DoneEvent(reason: StopReason.stop, message: message));
        stream.end();
        return stream;
      };
      final huge = 'x' * (maxExtractionSpanChars + 1000);
      await extractDurableEntries(capture, _model, huge);
      // The rendered prompt stays well under span + prompt overhead.
      expect(seenPrompt!.length, lessThan(maxExtractionSpanChars + 2000));
      expect(seenPrompt!, contains('middle of the span elided'));
    });
  });

  group('compactionMemoryHook', () {
    test('returns null when memory or model wiring is missing', () {
      final env = MemoryExecutionEnv();
      final memory = MemoryController(env: env);
      expect(
        compactionMemoryHook(memory: null, stream: null, model: null),
        isNull,
      );
      expect(
        compactionMemoryHook(
          memory: memory,
          stream: _streamWith('[]'),
          model: null,
        ),
        isNull,
      );
    });

    test('hook never throws even when the stream fails', () async {
      final env = MemoryExecutionEnv();
      final memory = MemoryController(env: env);
      final hook = compactionMemoryHook(
        memory: memory,
        stream: _streamWith('x', throwOnCall: true),
        model: _model,
      );
      // Must complete without throwing (non-blocking contract).
      await hook!('summarized span');
    });
  });
}
