@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/memory/execution_env_kb_storage.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

const _store = '/work/.fah/memory';
const _newGitattributesLines = [
  'questions/*.md merge=union',
  'answers/*.md merge=union',
  'notes/*.md merge=union',
  'deleted/*.md merge=union',
];

const _harnessGitattributesLines = [
  'question/*.md merge=union',
  'answer/*.md merge=union',
  'note/*.md merge=union',
];

void main() {
  group('tombstone deletions through MemoryController (gh-1032 IT-1)', () {
    test('delete keeps the entity file as a tombstone and hides it from list '
        '(AC1)', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final controller = MemoryController(env: env);
      final added = await controller.add(text: 'doomed durable fact');
      final entityPath = '$_store/note/${added.id}.md';
      expect((await env.exists(entityPath)).valueOrNull, isTrue);
      Future<int> revision() async => int.parse(
        ((await env.readTextFile('$_store/MEMORY.revision')).valueOrNull ?? '0')
            .trim(),
      );
      final revisionBeforeDelete = await revision();

      expect(await controller.delete(added.id), 'project');

      // The file STAYS on disk carrying the tombstone marker…
      final content = (await env.readTextFile(entityPath)).valueOrNull!;
      expect(content, contains('tombstone: true'));
      // …the record is gone for readers…
      final ids = (await controller.list(limit: 50)).map((e) => e.id);
      expect(ids, isNot(contains(added.id)));
      // …the append-only ledger records it…
      final ledger =
          (await env.readTextFile('$_store/DELETIONS.md')).valueOrNull ?? '';
      expect(ledger, contains(added.id));
      // …the per-record deleted/ file exists…
      final deletedFiles = (await env.listDir('$_store/deleted'))
          .getOrThrow()
          .where((e) => e.kind != FileKind.directory)
          .map((e) => e.name)
          .toList();
      expect(deletedFiles, hasLength(1));
      expect(deletedFiles.single, startsWith('${added.id}_'));
      // …and the revision generation was bumped (consolidation guard).
      expect(await revision(), greaterThan(revisionBeforeDelete));
    });

    test('the deleted/ record is byte-identical across independent stores '
        '(UT-2 merge-triviality invariant)', () async {
      Future<String> deletedFileOf(MemoryExecutionEnv env) async {
        final store = '${env.cwd}/.fah/memory';
        final controller = MemoryController(env: env);
        final added = await controller.add(
          text: 'shared fact deleted on both branches',
        );
        expect(await controller.delete(added.id), 'project');
        final files = (await env.listDir('$store/deleted')).getOrThrow();
        expect(files, hasLength(1));
        return (await env.readTextFile(
          '$store/deleted/${files.first.name}',
        )).valueOrNull!;
      }

      final a = await deletedFileOf(MemoryExecutionEnv(cwd: '/a'));
      final b = await deletedFileOf(MemoryExecutionEnv(cwd: '/b'));
      expect(a, isNotEmpty);
      expect(a, b, reason: 'same deletion must produce identical bytes');
    });

    test(
      'double delete is idempotent and keeps a single deleted/ file (E2)',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final controller = MemoryController(env: env);
        final added = await controller.add(text: 'deleted exactly once');
        expect(await controller.delete(added.id), 'project');
        // The tombstoned file reads as absent — the second delete finds
        // nothing to do and must not duplicate ledger or deleted/ records.
        expect(await controller.delete(added.id), isNull);
        final ledger =
            (await env.readTextFile('$_store/DELETIONS.md')).valueOrNull ?? '';
        expect('id: ${added.id}'.allMatches(ledger), hasLength(1));
        final deletedFiles = (await env.listDir(
          '$_store/deleted',
        )).getOrThrow().where((e) => e.kind != FileKind.directory);
        expect(deletedFiles, hasLength(1));
      },
    );

    test('set-difference consolidation progress works over the adapter '
        '(library 0.2.3 unprocessedDeletions, no harness change)', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final controller = MemoryController(env: env);
      final added = await controller.add(text: 'consolidation probe');
      await controller.delete(added.id);

      // The consolidation flow reads deleted/ through the storage
      // adapter: listFilePaths('deleted') + readFile.
      final service = MemoryDeletionService(ExecutionEnvKbStorage(env, _store));
      final pending = await service.unprocessedDeletions();
      expect(pending.map((d) => d.id), [added.id]);
      await service.markDeletionsProcessed(pending);
      expect(await service.unprocessedDeletions(), isEmpty);
      // The marker is a local derivative — the library keeps it out of
      // git alongside MEMORY.revision & co.
      final gitignore =
          (await env.readTextFile('$_store/.gitignore')).valueOrNull ?? '';
      expect(gitignore, contains('.last_deletions'));
    });

    test(
      'legacy ledger-only store still answers isDeleted/hasDeletedText (E1)',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final storage = ExecutionEnvKbStorage(env, _store);
        await storage.initialize();
        // A pre-0.2.2 store: the entity file was physically unlinked and the
        // only trace is the DELETIONS.md ledger. No deleted/ dir exists.
        final fingerprint = memoryTextFingerprint('legacy deleted fact');
        await env.writeFile('$_store/DELETIONS.md', '''
---
consolidatedUpTo: 0
---
- seq: 1 | id: n_0001_dead | type: note | fingerprint: $fingerprint | deletedAt: 2026-08-30T15:54:00.000Z | text: legacy deleted fact
''');
        final store = KBMemoryStore(storage, source: 'fa-project');
        expect(await store.isDeleted('n_0001_dead'), isTrue);
        expect(await store.hasDeletedText('legacy deleted fact'), isTrue);
        expect(await store.hasDeletedText('something else'), isFalse);
      },
    );
  });

  group('git-support migration 0.2.1 → 0.2.3 (AC4)', () {
    test(
      'ensureGitSupport appends exactly the new lines, idempotently',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        // Simulate a store initialized by 0.2.1: old .gitignore/.gitattributes
        // with user content.
        await env.writeFile(
          '$_store/.gitattributes',
          '# flutter_agent_memory merge drivers\nDELETIONS.md merge=union\n',
        );
        await env.writeFile(
          '$_store/.gitignore',
          '# flutter_agent_memory derivatives - rebuilt from records, '
              'do not commit\nGRAPH.md\nMEMORY.revision\nINDEX.md\n'
              '.last_maintenance\n',
        );

        final controller = MemoryController(env: env);
        await controller.add(text: 'migration probe');

        final gitattributes = (await env.readTextFile(
          '$_store/.gitattributes',
        )).valueOrNull!;
        // Old content preserved…
        expect(gitattributes, contains('DELETIONS.md merge=union'));
        // …the library's new union drivers for its plural layout…
        for (final line in _newGitattributesLines) {
          expect(gitattributes, contains(line));
        }
        // …and the harness's own union drivers for the adapter's singular
        // entity dirs (the library lines do not match note/ question/ answer/).
        for (final line in _harnessGitattributesLines) {
          expect(gitattributes, contains(line));
        }
        // No duplicates: 5 library lines + 3 harness lines.
        expect('merge=union'.allMatches(gitattributes), hasLength(8));

        final gitignore = (await env.readTextFile(
          '$_store/.gitignore',
        )).valueOrNull!;
        expect(gitignore, contains('.last_maintenance'));
        expect(gitignore, contains('.last_deletions'));
        expect(gitignore, contains('GRAPH.md'));

        // Second init run (fresh controller, same store) adds nothing.
        await MemoryController(env: env).add(text: 'second probe');
        final gitattributesAgain = (await env.readTextFile(
          '$_store/.gitattributes',
        )).valueOrNull!;
        expect(gitattributesAgain, gitattributes);
        final gitignoreAgain = (await env.readTextFile(
          '$_store/.gitignore',
        )).valueOrNull!;
        expect(gitignoreAgain, gitignore);
      },
    );
  });
}
