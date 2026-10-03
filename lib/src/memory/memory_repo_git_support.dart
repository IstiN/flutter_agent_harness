/// Harness-side git-merge support for the project memory store.
///
/// flutter_agent_memory's `MemoryRepoInit.ensureGitSupport()` appends union
/// merge drivers for ITS file-backend layout (`questions|answers|notes/
/// *.md`). The harness adapter (`ExecutionEnvKbStorage`) stores entities
/// under the SINGULAR dirs (`question/`, `answer/`, `note/`), so entity
/// union drivers must be appended for this layout too: without them a
/// tombstone (delete) and an edit of the same record on two branches is a
/// plain delete/modify conflict and the rebase/merge stops for manual
/// resolution — exactly what the 0.2.3 migration removes. The per-record
/// `deleted/` files are already covered by the library's own
/// `deleted/*.md merge=union` line.
library;

import 'package:flutter_agent_memory/flutter_agent_memory.dart';

/// The `.gitattributes` lines the harness adds on top of the library's
/// `ensureGitSupport()` lines, covering the adapter's singular entity dirs.
const harnessMergeDriverLines = <String>[
  'question/*.md merge=union',
  'answer/*.md merge=union',
  'note/*.md merge=union',
];

/// Appends [harnessMergeDriverLines] to the store's `.gitattributes` —
/// only missing lines, user content is never rewritten or removed (same
/// idempotent contract as `MemoryRepoInit.ensureGitSupport()`). Safe to
/// run on every store init. Project scope only: the user store is
/// machine-local by design and never merged.
Future<void> ensureHarnessMergeDrivers(KbStorage storage) async {
  final existing =
      await storage.readFile(MemoryRepoInit.gitattributesFile) ?? '';
  final present = existing.split('\n').map((l) => l.trim()).toSet();
  final missing = harnessMergeDriverLines.where((l) => !present.contains(l));
  if (missing.isEmpty) return;
  final buffer = StringBuffer(existing);
  if (existing.isNotEmpty && !existing.endsWith('\n')) buffer.writeln();
  for (final line in missing) {
    buffer.writeln(line);
  }
  await storage.writeFile(MemoryRepoInit.gitattributesFile, buffer.toString());
}
