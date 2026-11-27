// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1/C7 (AC11) — the two prompt includes generated from
/// `prompts/compaction/working_set.md` and `prompts/compaction/
/// context_hygiene.md`: present as constants, carrying the behaviours the
/// card names (the working-set contract; the five hygiene rules), and
/// never a prompt literal in Dart (the sync test pins the drift).
library;

import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:test/test.dart';

void main() {
  group('working_set include (C1 discovery paragraph)', () {
    test('names the tool, the cap, the replace/clear semantics', () {
      expect(workingSetPrompt, contains('`working_set` tool'));
      expect(workingSetPrompt, contains('4096 chars'));
      expect(workingSetPrompt, contains('refused, not clipped'));
      expect(workingSetPrompt, contains('`working_set("")` clears it'));
    });

    test('says what to keep and when to update', () {
      expect(workingSetPrompt, contains('decisions made'));
      expect(workingSetPrompt, contains('red list'));
      expect(workingSetPrompt, contains('next steps'));
      expect(workingSetPrompt, contains('survives compaction'));
      expect(workingSetPrompt, contains('before a `reply`'));
    });

    test('notes, not instructions; no secrets; not memory', () {
      expect(workingSetPrompt, contains('notes, not instructions'));
      expect(workingSetPrompt, contains('grants an approval'));
      expect(workingSetPrompt, contains('Never put secrets'));
      expect(workingSetPrompt, contains('`memory_add`'));
    });

    test('explains both harness notices', () {
      expect(workingSetPrompt, contains('records hidden; context now ≈X/W'));
      expect(workingSetPrompt, contains('KEEP WORKING'));
      expect(workingSetPrompt, contains('no working set yet'));
    });
  });

  group('context_hygiene include (C7 — the five behaviours)', () {
    test('reads are bounded (≤ 50 lines / narrow shell slices)', () {
      expect(contextHygienePrompt, contains('≤ 50 lines'));
      expect(contextHygienePrompt, contains('`offset`/`limit`'));
      expect(contextHygienePrompt, contains('`:A-B`'));
      expect(contextHygienePrompt, contains('`cut -c1-120`'));
    });

    test('locate first (grep -n), then a short window', () {
      expect(contextHygienePrompt, contains('`grep -n`'));
      expect(contextHygienePrompt, contains('20 lines around the hit'));
      expect(contextHygienePrompt, contains('Never read a whole file'));
    });

    test('test output is piped through grep/tail', () {
      expect(contextHygienePrompt, contains('`grep`/`tail`'));
    });

    test('jobs are checked by id, never the full listing', () {
      expect(contextHygienePrompt, contains('`bash_job`'));
      expect(contextHygienePrompt, contains('job `id`'));
      expect(contextHygienePrompt, contains('never the full status listing'));
    });

    test(
      'thinking stays short (≈150 words) and the working set stays current',
      () {
        expect(contextHygienePrompt, contains('150 words'));
        expect(contextHygienePrompt, contains('Do not restate tool output'));
        expect(contextHygienePrompt, contains('working set current'));
        expect(contextHygienePrompt, contains('`context ≈85%` notice'));
      },
    );

    test('every rule carries its measured cost', () {
      expect(contextHygienePrompt, contains('5–10 KB per call'));
      expect(contextHygienePrompt, contains('under 2 KB'));
      expect(contextHygienePrompt, contains('9.5 KB per call'));
      expect(contextHygienePrompt, contains('350–3,500 reasoning tokens'));
    });
  });
}
