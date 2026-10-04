// Guard: the machine-loop stubs track the FACTORY HOME
// (dmtools-agentic-workflows) at main — always-latest policy (owner
// directive 2026-10-04: awf fixes go live on merge; pushes are
// review-gated) — and all THREE stubs carry the SAME ref (teammate, SM and merge must never skew apart — the
// SM dispatches the teammate workflow, the event-driven merge fast path
// runs mergeBot.js from the pinned pack; a stale merge stub silently
// misses pack fixes). The ENGINE (dmtools-agents: packs + factory code)
// is pinned separately: ai-teammate passes factory_ref; sm/merge
// resolve the engine from releases via vars (latest default).
//
// Ported from epam/dmtools-dart (test/machine_kit/factory_stub_ref_test.dart)
// minus the submodule cross-check: fa pins the factory ref directly, there
// is no `agents` submodule here.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final teammate = File('.github/workflows/ai-teammate.yml').readAsStringSync();
  final sm = File('.github/workflows/machine-sm.yml').readAsStringSync();
  // Third stub (pr-1076 review: machine-merge.yml skewed to an older pin
  // while teammate+SM were flipped — the #568 fix never reached the
  // event-driven merge leg). Guarded in the same lockstep from now on.
  final merge = File('.github/workflows/machine-merge.yml').readAsStringSync();

  /// Every machine-loop stub -> the factory workflow it calls. New stubs
  /// MUST be added here: the lockstep, factory_ref-echo and secrets checks
  /// below iterate this map, so an unlisted stub escapes all three.
  final stubs = <String, (String, String)>{
    'ai-teammate.yml': (teammate, 'factory-teammate.yml'),
    'machine-sm.yml': (sm, 'factory-sm.yml'),
    'machine-merge.yml': (merge, 'factory-merge.yml'),
  };

  String? pinnedRef(String yaml, String workflowFile) {
    final usesLine = yaml
        .split('\n')
        .firstWhere(
          (l) => l.contains(
            'dmtools-agentic-workflows/.github/workflows/$workflowFile@',
          ),
          orElse: () => '',
        );
    if (!usesLine.contains('@')) return null;
    final ref = usesLine.trim().split('@').last;
    // Exactly 'main' (always-latest) — never a stale SHA, never a
    // random branch/tag ref.
    return ref;
  }

  test('ai-teammate.yml tracks factory-teammate.yml at main '
      '(always-latest policy)', () {
    final ref = pinnedRef(teammate, 'factory-teammate.yml');
    expect(ref, isNotNull, reason: 'uses: line with @main not found');
    expect(
      ref == 'main',
      isTrue,
      reason:
          'ref "$ref" is not main — a re-pinned SHA would freeze the '
          'loop off awf fixes (policy: review-gated always-latest)',
    );
  });

  test('machine-sm.yml tracks factory-sm.yml at main '
      '(always-latest policy)', () {
    final ref = pinnedRef(sm, 'factory-sm.yml');
    expect(ref, isNotNull, reason: 'uses: line with @main not found');
    expect(
      ref == 'main',
      isTrue,
      reason: 'ref "$ref" is not main — always-latest policy',
    );
  });

  test('machine-merge.yml tracks factory-merge.yml at main '
      '(always-latest policy)', () {
    final ref = pinnedRef(merge, 'factory-merge.yml');
    expect(ref, isNotNull, reason: 'uses: line with @main not found');
    expect(
      ref == 'main',
      isTrue,
      reason: 'ref "$ref" is not main — always-latest policy',
    );
  });

  test('all three stubs pin the SAME factory ref (teammate, SM, merge '
      'in lockstep)', () {
    final a = pinnedRef(teammate, 'factory-teammate.yml');
    final b = pinnedRef(sm, 'factory-sm.yml');
    final c = pinnedRef(merge, 'factory-merge.yml');
    expect(
      a,
      b,
      reason:
          'teammate and SM factories must not skew apart: '
          'the SM dispatches ai-teammate.yml expecting the reviewed contract',
    );
    expect(
      b,
      c,
      reason:
          'SM and merge factories must not skew apart: '
          'the merge fast path executes mergeBot.js from the pinned pack — '
          'a stale merge stub silently misses pack fixes (live: pr-1076, '
          'the #568 workspace fix shipped to teammate+SM only)',
    );
  });

  test('engine pin: ai-teammate passes a 40-hex factory_ref; sm/merge '
      'carry none (AW resolves the engine from releases)', () {
    final engineRef = RegExp(
      r'factory_ref:\s*([0-9a-f]{40})',
    ).firstMatch(teammate);
    expect(
      engineRef,
      isNotNull,
      reason:
          'ai-teammate must pass factory_ref — the factory declares it '
          'required and cannot derive its own engine commit',
    );
    for (final entry in {
      'machine-sm.yml': sm,
      'machine-merge.yml': merge,
    }.entries) {
      expect(
        entry.value.contains('factory_ref:'),
        isFalse,
        reason:
            '${entry.key}: AW factory-sm/merge have no factory_ref '
            'input — the engine resolves from dmtools-agents releases '
            'via vars (latest default)',
      );
    }
  });

  test('secrets are mapped explicitly, not inherited '
      '(required-secret validation rejects inherit)', () {
    for (final entry in stubs.entries) {
      final (yaml, _) = entry.value;
      expect(
        yaml.contains(
          'SOURCE_GITHUB_TOKEN: \${{ secrets.SOURCE_GITHUB_TOKEN }}',
        ),
        isTrue,
        reason: '${entry.key}: SOURCE_GITHUB_TOKEN must be mapped explicitly',
      );
      // No NON-comment line carries `secrets: inherit` (the factory docs
      // mention it in comments; only real YAML would break validation).
      final inheritLine = yaml
          .split('\n')
          .any((l) => l.trimLeft().startsWith('secrets: inherit'));
      expect(
        inheritLine,
        isFalse,
        reason: '${entry.key} must not use secrets: inherit',
      );
    }
  });

  test('assignment gate: the loop starts when a human ASSIGNS an issue to '
      'ai-teammate (assignee filter on issues, author filter on PRs)', () {
    expect(
      teammate.contains(
        "contains(github.event.issue.assignees.*.login, 'ai-teammate')",
      ),
      isTrue,
      reason: 'issues trigger must key on the ASSIGNEE, not the author',
    );
    expect(
      teammate.contains('types: [assigned]'),
      isTrue,
      reason:
          '`labeled` removed 2026-10-01 (echo twins, dmd gh-317/318): '
          'label echoes queued duplicate runs behind the per-issue '
          'concurrency group; legs are dispatch-only now',
    );
    expect(
      teammate.contains('types: [assigned, labeled]'),
      isFalse,
      reason: 'the labeled trigger must not come back (echo-twin class)',
    );
    expect(
      teammate.contains('pull_request:'),
      isFalse,
      reason:
          'no PR trigger: pull_request runs startup-failed (PRs #624/'
          '#625) and the loop drives review via SM ticks + issue labels',
    );
    expect(
      teammate.contains("github.event_name == 'workflow_dispatch')") ||
          teammate.contains("|| github.event_name == 'workflow_dispatch'"),
      isTrue,
      reason:
          'dispatch runs must reach the factory even with empty gate '
          'outputs (inputs carry the target) — the gh-623 skip bug',
    );
    expect(
      teammate.contains("github.event.issue.user.login == 'ai-teammate'"),
      isFalse,
      reason: 'the old author filter must not linger',
    );
  });
}
