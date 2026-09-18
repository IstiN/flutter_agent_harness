// Guard: the machine-loop stubs pin the dmtools-agents factory at an
// immutable SHA, and both stubs pin the SAME ref (teammate + SM must
// never skew apart — the SM dispatches the teammate workflow).
//
// Ported from epam/dmtools-dart (test/machine_kit/factory_stub_ref_test.dart)
// minus the submodule cross-check: fa pins the factory ref directly, there
// is no `agents` submodule here.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final teammate = File('.github/workflows/ai-teammate.yml').readAsStringSync();
  final sm = File('.github/workflows/machine-sm.yml').readAsStringSync();

  String? pinnedRef(String yaml, String workflowFile) {
    final usesLine = yaml
        .split('\n')
        .firstWhere(
          (l) => l.contains('dmtools-agents/.github/workflows/$workflowFile@'),
          orElse: () => '',
        );
    if (!usesLine.contains('@')) return null;
    final ref = usesLine.trim().split('@').last;
    // Immutable SHA-1, not a moving branch/tag ref.
    return RegExp(r'^[0-9a-f]{40}$').hasMatch(ref) ? ref : ref;
  }

  test('ai-teammate.yml pins factory-teammate.yml at an immutable SHA', () {
    final ref = pinnedRef(teammate, 'factory-teammate.yml');
    expect(ref, isNotNull, reason: 'uses: line with @<sha> not found');
    expect(
      RegExp(r'^[0-9a-f]{40}$').hasMatch(ref!),
      isTrue,
      reason:
          'ref "$ref" is not a 40-hex SHA — branch heads move and '
          'would execute unreviewed factory code',
    );
  });

  test('machine-sm.yml pins factory-sm.yml at an immutable SHA', () {
    final ref = pinnedRef(sm, 'factory-sm.yml');
    expect(ref, isNotNull, reason: 'uses: line with @<sha> not found');
    expect(
      RegExp(r'^[0-9a-f]{40}$').hasMatch(ref!),
      isTrue,
      reason: 'ref "$ref" is not a 40-hex SHA',
    );
  });

  test('both stubs pin the SAME factory ref (teammate and SM in lockstep)', () {
    final a = pinnedRef(teammate, 'factory-teammate.yml');
    final b = pinnedRef(sm, 'factory-sm.yml');
    expect(
      a,
      b,
      reason:
          'teammate and SM factories must not skew apart: '
          'the SM dispatches ai-teammate.yml expecting the reviewed contract',
    );
  });

  test('factory_ref input echoes the literal uses-ref (the factory cannot '
      'derive its own ref)', () {
    for (final yaml in [teammate, sm]) {
      final ref = pinnedRef(
        yaml,
        yaml == teammate ? 'factory-teammate.yml' : 'factory-sm.yml',
      )!;
      expect(
        yaml.contains('factory_ref: $ref'),
        isTrue,
        reason: 'factory_ref must repeat the uses-ref literally',
      );
    }
  });

  test('secrets are mapped explicitly, not inherited '
      '(required-secret validation rejects inherit)', () {
    expect(
      teammate.contains(
        'SOURCE_GITHUB_TOKEN: \${{ secrets.SOURCE_GITHUB_TOKEN }}',
      ),
      isTrue,
    );
    expect(
      sm.contains('SOURCE_GITHUB_TOKEN: \${{ secrets.SOURCE_GITHUB_TOKEN }}'),
      isTrue,
    );
    // No NON-comment line carries `secrets: inherit` (the factory docs
    // mention it in comments; only real YAML would break validation).
    for (final yaml in {
      'ai-teammate.yml': teammate,
      'machine-sm.yml': sm,
    }.entries) {
      final inheritLine = yaml.value
          .split('\n')
          .any((l) => l.trimLeft().startsWith('secrets: inherit'));
      expect(
        inheritLine,
        isFalse,
        reason: '${yaml.key} must not use secrets: inherit',
      );
    }
  });

  test('author gate: the loop reacts only to ai-teammate artifacts '
      '(issues AND pull_request triggers carry the author filter)', () {
    expect(
      teammate.contains("github.event.issue.user.login == 'ai-teammate'"),
      isTrue,
    );
    expect(
      teammate.contains(
        "github.event.pull_request.user.login == 'ai-teammate'",
      ),
      isTrue,
    );
  });
}
