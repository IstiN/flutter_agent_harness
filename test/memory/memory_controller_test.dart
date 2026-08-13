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

    test('search returns empty list without LLM provider', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      await controller.add(text: 'test note');
      // searchByText throws StateError without an LLM provider, which is
      // caught silently — so search returns an empty list.
      final results = await controller.search('test');
      expect(results, isEmpty);
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
  });
}
