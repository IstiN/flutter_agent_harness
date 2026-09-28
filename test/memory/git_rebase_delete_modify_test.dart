@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/memory/execution_env_kb_storage.dart';
import 'package:flutter_agent_harness/src/memory/memory_repo_git_support.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

/// E2E-1 / AC3 (gh-1032): the library's delete/modify conflict test replayed
/// through the HARNESS seam — ExecutionEnvKbStorage over a real local env.
/// Two agents on different branches delete and edit the same memory record;
/// the rebase must complete with zero manual conflict resolution.
bool _gitAvailable() {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  final gitAvailable = _gitAvailable();

  late Directory repo;

  setUp(() async {
    repo = await Directory.systemTemp.createTemp('fah_gitmem_');
  });

  tearDown(() async {
    if (repo.existsSync()) await repo.delete(recursive: true);
  });

  /// The harness seam: KBMemoryStore over ExecutionEnvKbStorage rooted at
  /// the repo itself (the repo IS the memory store, like the committed
  /// `memory/` dir this package dogfoods).
  KBMemoryStore store() => KBMemoryStore(
    ExecutionEnvKbStorage(LocalExecutionEnv(cwd: repo.path), repo.path),
    source: 'fa-project',
  );

  Future<ProcessResult> git(List<String> args) => Process.run(
    'git',
    ['-C', repo.path, ...args],
    environment: const {
      'GIT_AUTHOR_NAME': 'Test',
      'GIT_AUTHOR_EMAIL': 'test@example.com',
      'GIT_COMMITTER_NAME': 'Test',
      'GIT_COMMITTER_EMAIL': 'test@example.com',
    },
  );

  test('harness tombstone on one branch + edit on the other rebases cleanly '
      '(AC3)', () async {
    // Base: a committed memory store with one note, initialized exactly
    // like MemoryController.projectStore does it.
    final s = store();
    final note = await s.addNote(text: 'Shared fact across branches.');
    await MemoryRepoInit(s.storage).ensureGitSupport();
    await ensureHarnessMergeDrivers(s.storage);
    await git(['init', '-q']);
    // Pin the branch name regardless of init.defaultBranch config.
    await git(['symbolic-ref', 'HEAD', 'refs/heads/main']);
    await git(['add', '-A']);
    final base = await git(['commit', '-q', '-m', 'base']);
    expect(base.exitCode, 0, reason: base.stderr.toString());

    // Branch A: an agent deletes the note through the harness storage —
    // tombstone-in-place, the file is rewritten, never unlinked.
    await git(['checkout', '-q', '-b', 'agent-a']);
    expect(await store().deleteRecord(note.id), isTrue);
    final tombstone = File('${repo.path}/note/${note.id}.md');
    expect(tombstone.existsSync(), isTrue);
    expect(
      FileKbStorage.isTombstoneContent(tombstone.readAsStringSync()),
      isTrue,
    );
    await git(['add', '-A']);
    final commitA = await git(['commit', '-q', '-m', 'A deletes the note']);
    expect(commitA.exitCode, 0, reason: commitA.stderr.toString());

    // Branch B (main): another agent edits the same note file.
    await git(['checkout', '-q', 'main']);
    await store().updateRecord(
      note.id,
      text: 'Shared fact across branches, refined.',
    );
    await git(['add', '-A']);
    final commitB = await git(['commit', '-q', '-m', 'B edits the note']);
    expect(commitB.exitCode, 0, reason: commitB.stderr.toString());

    // Rebase B onto A — zero manual conflict resolution.
    final rebase = await git(['rebase', 'agent-a']);
    expect(
      rebase.exitCode,
      0,
      reason: 'stdout: ${rebase.stdout}\nstderr: ${rebase.stderr}',
    );
    final status = await git(['status', '--porcelain']);
    expect((status.stdout as String).trim(), isEmpty);

    // The delete won deterministically and reads through the harness seam.
    expect(
      FileKbStorage.isTombstoneContent(tombstone.readAsStringSync()),
      isTrue,
    );
    final merged = store();
    expect(await merged.isDeleted(note.id), isTrue);
    final records = await merged.list();
    expect(records.map((r) => r.id), isNot(contains(note.id)));
  }, skip: gitAvailable ? false : 'git binary not available');
}
