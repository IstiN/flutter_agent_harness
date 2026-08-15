@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Minimal fake KBStorage so we don't need the full memory backend in tests.

void main() {
  group('MemoryController', () {
    test('add stores and returns a MemoryEntry', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      final entry = await controller.add(text: 'hello world');
      expect(entry.text, 'hello world');
      expect(entry.type, 'note');
      expect(entry.scope, 'project');
    });

    test('sequential adds allocate incrementing note ids', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      final first = await controller.add(text: 'first note');
      final second = await controller.add(text: 'second note');
      expect(first.id, 'n_0001');
      expect(second.id, 'n_0002');
      final entries = await controller.list(limit: 10);
      expect(entries.length, 2);
    });

    test(
      'add with user scope and no userRoot returns no-store entry',
      () async {
        final env = MemoryExecutionEnv();
        final controller = MemoryController(env: env);
        final entry = await controller.add(text: 'user note', scope: 'user');
        expect(entry.id, 'no-store');
        expect(entry.scope, 'user');
      },
    );

    test('list returns entries from project storage', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      await controller.add(text: 'first note');
      final entries = await controller.list(limit: 10);
      expect(entries.length, 1);
      expect(entries.every((e) => e.scope == 'project'), isTrue);
    });

    test('list returns empty when storage has no notes', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      final entries = await controller.list();
      expect(entries, isEmpty);
    });

    test('formatPromptSection returns empty string with no entries', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      final section = await controller.formatPromptSection();
      expect(section, isEmpty);
    });

    test('formatPromptSection returns memory block with entries', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      await controller.add(text: 'test fact');
      final section = await controller.formatPromptSection();
      expect(section, contains('<memory>'));
      expect(section, contains('(note)'));
      expect(section, contains('</memory>'));
    });

    test('search falls back to keywords without LLM provider', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      await controller.add(text: 'test note');
      // searchByText throws StateError without an LLM provider; the
      // controller falls back to keyword-only search, which finds the note.
      final results = await controller.search('test');
      expect(results, hasLength(1));
      expect(results.single.text, 'test note');
    });

    test('MemoryEntry.displayLine formats tags and text', () {
      const entry = MemoryEntry(
        id: 'x',
        type: 'note',
        text: 'hello',
        tags: ['a', 'b'],
      );
      expect(entry.displayLine, '(note) hello [a,b]');
    });

    test('MemoryEntry.displayLine without tags', () {
      const entry = MemoryEntry(id: 'x', type: 'note', text: 'hello');
      expect(entry.displayLine, '(note) hello');
    });

    test('list and the prompt section include the USER scope', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env, userRoot: '/user');
      await controller.add(text: 'project fact');
      await controller.add(text: 'global user fact', scope: 'user');

      final entries = await controller.list(limit: 10);
      expect(entries, hasLength(2));
      expect(entries.map((e) => e.scope), containsAll(['project', 'user']));
      expect(
        entries.map((e) => e.text),
        containsAll(['project fact', 'global user fact']),
      );

      // The prompt section carries both scopes plus the search hint.
      final section = await controller.formatPromptSection();
      expect(section, contains('global user fact'));
      expect(section, contains('project fact'));
      expect(section, contains('memory_search'));
    });
  });
}
