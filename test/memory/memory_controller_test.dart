@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/memory/execution_env_kb_storage.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
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
      'the storage adapter is append-capable (ledger race fix 0.2.1)',
      () async {
        // flutter_agent_memory 0.2.1: parallel deletes append tombstones via
        // KbAppendCapable — the read-modify-write race that clobbered our
        // 144-entry ledger is closed for storages implementing it.
        final env = MemoryExecutionEnv();
        final storage = ExecutionEnvKbStorage(env, '/mem');
        await storage.initialize();
        expect(storage, isA<KbAppendCapable>());
        await (storage as KbAppendCapable).appendFile('DELETIONS.md', '- a\n');
        await (storage as KbAppendCapable).appendFile('DELETIONS.md', '- b\n');
        final content =
            (await env.readTextFile('/mem/DELETIONS.md')).valueOrNull ?? '';
        expect(content, '- a\n- b\n');
      },
    );

    test('the project store gets git support files (idempotent)', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      await controller.add(text: 'git support probe');
      final gitignore =
          (await env.readTextFile('/.fah/memory/.gitignore')).valueOrNull ?? '';
      expect(gitignore, contains('GRAPH.md'));
      expect(gitignore, contains('MEMORY.revision'));
      final gitattributes =
          (await env.readTextFile('/.fah/memory/.gitattributes')).valueOrNull ??
          '';
      expect(gitattributes, contains('DELETIONS.md merge=union'));
      // A second store init keeps user content (append-only ensure).
      await controller.add(text: 'second probe');
      final after =
          (await env.readTextFile('/.fah/memory/.gitignore')).valueOrNull ?? '';
      expect(after, contains('GRAPH.md'));
    });

    test('sequential adds allocate incrementing note ids', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      final first = await controller.add(text: 'first note');
      final second = await controller.add(text: 'second note');
      // flutter_agent_memory 0.2.0: merge-friendly ids carry a 4-hex
      // content-hash suffix (git-backed memory) — the sequential index
      // stays, the suffix varies with the text.
      expect(first.id, matches(r'^n_0001_[0-9a-f]{4}$'));
      expect(second.id, matches(r'^n_0002_[0-9a-f]{4}$'));
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
