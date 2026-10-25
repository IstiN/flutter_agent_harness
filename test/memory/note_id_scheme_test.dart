@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

/// gh-1845 rework (PR #1846, review thread PRRT_kwDOTXdlLc6v6eZe):
/// the recovery-playbook note `n_1012_*` documents a once-daily
/// build-extension producer gap (gh-1832 class) and, per the review
/// thread, must reference the filed systemic-fix follow-up issue.
///
/// The note's merge-friendly id carries a 4-hex content-hash suffix
/// (md5 of `normalizeMemoryText(primaryText)`, per
/// `flutter_agent_memory` `MemoryIdScheme`) — the body paragraph IS the
/// hashed text, so appending the follow-up reference invalidates the
/// suffix unless the id (and filename) is recomputed. These tests pin
/// both invariants so future enrichments of the note keep the scheme
/// honest.

void main() {
  group('gh-1845 recovery-playbook note (n_1012)', () {
    /// The note file is renamed whenever its hash suffix is recomputed,
    /// so resolve it by sequential index rather than full name.
    File findNote() {
      final files = Directory('memory/note')
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'n_1012_[0-9a-f]{4}\.md$').hasMatch(f.path))
          .toList();
      expect(files, hasLength(1), reason: 'exactly one n_1012 note');
      return files.single;
    }

    /// The hashed primary text: the first body paragraph after the
    /// `# Note: <id>` heading (frontmatter and the `**By:**` trailer
    /// are never hashed).
    String primaryText(File file) {
      final body = file.readAsStringSync().replaceFirst(
        RegExp(r'^---\n.*?\n---\n', dotAll: true),
        '',
      );
      final blocks = body
          .split(RegExp(r'\n\s*\n'))
          .map((b) => b.trim())
          .where((b) => b.isNotEmpty && !b.startsWith('# Note:'))
          .toList();
      return blocks.first;
    }

    test('body references the filed systemic-fix follow-up issue', () {
      final note = findNote();
      final text = primaryText(note);
      // The review thread asked for a `gh-NNNN` reference to a follow-up
      // issue tracking the systemic fix (tag train producing/attaching
      // fa-extension.zip or an event-driven producer), so the manual
      // dispatch playbook stays an emergency procedure.
      expect(
        text,
        contains(RegExp(r'follow-up gh-\d+', caseSensitive: false)),
        reason:
            'review thread PRRT_kwDOTXdlLc6v6eZe: file + reference the '
            'systemic-fix issue',
      );
    });

    test('id hash suffix matches the note body (MemoryIdScheme)', () {
      final note = findNote();
      final id = RegExp(
        r'n_1012_([0-9a-f]{4})\.md$',
      ).firstMatch(note.path)!.group(1)!;
      final text = primaryText(note);
      expect(
        MemoryIdScheme.hashSuffix(text),
        id,
        reason:
            'the 4-hex suffix is md5(normalizeMemoryText(body))[:4]; '
            'after editing the body, recompute the suffix and rename the '
            'file + frontmatter id',
      );
    });

    // gh-1847 rework (PR #1853, review thread PRRT_kwDOTXdlLc6v8Epw):
    // the note was renamed n_1012_96d1 -> n_1012_9c1a (frontmatter id
    // and filename recomputed), but the in-body `# Note:` heading kept
    // the old id. `primaryText` strips `# Note:` blocks before hashing,
    // so the stale heading did not break the hash invariant — but a
    // reader resolving the note by its heading id looks for a file that
    // no longer exists. Pin the three id surfaces together.
    test('body heading id matches frontmatter id and filename', () {
      final note = findNote();
      final contents = note.readAsStringSync();
      final frontmatterId = RegExp(
        r'^id:\s*"(n_1012_[0-9a-f]{4})"',
        multiLine: true,
      ).firstMatch(contents)!.group(1)!;
      final headingId = RegExp(
        r'^# Note:\s*(n_1012_[0-9a-f]{4})\s*$',
        multiLine: true,
      ).firstMatch(contents)!.group(1)!;
      expect(headingId, frontmatterId,
          reason:
              'review thread PRRT_kwDOTXdlLc6v8Epw: after renaming the '
              'note, update the in-body `# Note:` heading too — the '
              'hashing strips it, but readers resolve notes by heading');
      expect(frontmatterId, note.uri.pathSegments.last.replaceAll('.md', ''),
          reason: 'frontmatter id must match the filename');
    });
  });
}
