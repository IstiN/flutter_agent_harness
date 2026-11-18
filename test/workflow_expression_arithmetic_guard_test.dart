// gh-2288 — the daily-publish `cli` leg died at DISPATCH: HTTP 422
// "failed to parse workflow: (Line: 657, Col: 25): Unexpected symbol:
// '+'" because build-macos.yml (gh-2246) wrote an additive sum INSIDE
// a ${{ }} expression. GitHub Actions expression syntax has no
// additive '+'/'-' — the file itself is unparseable, so EVERY dispatch
// of the workflow is rejected before any job starts (daily run
// 44243345944, leg `cli`; LEG_CLI_URL stayed empty — there was no
// child run to excerpt). build-macos.yml is workflow_dispatch-only and
// no gate parses expressions, so this guard is the only preemptive
// detector.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of build_macos_asc_collision_guard_test.dart):
//
//   AC1  No workflow declares additive arithmetic inside a ${{ }}
//        expression — the dispatch API 422s the whole file.
//   AC2  build-macos.yml computes the gh-2246 BUILD_NUMBER sum in the
//        step's bash run block (which has additive arithmetic), with
//        the raw operands arriving as plain env scalars.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowsDir = '.github/workflows';

/// ANY `+` — there is no legal use outside a quoted string literal:
/// GitHub expressions have no additive `+` operator and no unary `+`
/// (gh-2288; PR #2293 review). Quoted literals are stripped by
/// [stripQuotes] before matching, so spacing never matters.
final additivePlus = RegExp(r'\+');

/// Space-delimited binary `-` between operand-ish tokens (version
/// strings inside quotes are stripped first; this is the subtraction
/// form the same parser defect class would produce).
///
/// Deliberately SPACED-only: unlike `+`, `-` has legal unspaced uses —
/// negative number literals (`== -1`) and hyphenated identifiers
/// (`inputs.max-attempts`, ~100 dispatch inputs across this repo's
/// workflows). A spacing-agnostic minus regex would false-positive on
/// those and report legal workflows as violations. The unspaced binary
/// form (`github.run_number-1`) would 422 at dispatch but cannot be
/// flagged without colliding with those legal forms — the daily leg
/// stays the detector of last resort for that shape (PR #2293 review).
final additiveMinus = RegExp(r'(?<=[0-9A-Za-z_)\]])\s-\s(?=[0-9A-Za-z_(])');

/// Strips single- and double-quoted substrings — the only legal home
/// for '+'/'-' characters inside a GitHub expression.
String stripQuotes(String expression) {
  var bare = expression.replaceAll(RegExp("'[^']*'"), '');
  bare = bare.replaceAll(RegExp('"[^"]*"'), '');
  return bare;
}

void main() {
  final workflowFiles =
      Directory(workflowsDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('AC1: no ${{}} expression uses additive arithmetic (dispatch 422s)', () {
    expect(workflowFiles, isNotEmpty, reason: 'workflows must be scannable');
    final violations = <String>[];
    for (final file in workflowFiles) {
      final source = file.readAsStringSync();
      for (final match in RegExp(r'\$\{\{[\s\S]*?\}\}').allMatches(source)) {
        final expression = match.group(0)!;
        final bare = stripQuotes(expression);
        if (additivePlus.hasMatch(bare) || additiveMinus.hasMatch(bare)) {
          violations.add('${file.path}: $expression');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'GitHub Actions expressions have NO additive + or - operator — '
          'the server-side parser rejects the whole workflow at dispatch '
          '(HTTP 422 "Unexpected symbol", gh-2288). Compute sums in a '
          'bash run block and pass the raw operands as env scalars.',
    );
  });

  test('AC1b: guard catches unspaced/partially-spaced + variants (422 too)', () {
    // gh-2288's defect family is spacing-agnostic: the server-side
    // parser rejects every one of these exactly like the historical
    // spaced form (PR #2293 review probe). The guard must not depend
    // on operator spacing.
    const defectVariants = <String>[
      r'${{ github.run_number*10+1 }}', // fully unspaced
      r'${{ github.run_number *10 +1 }}', // right-spaced only
      r'${{ github.run_number*10+ 1 }}', // left-spaced only
      r'${{ (matrix.arch == 1 || 0)+2 }}', // unspaced after a paren
    ];
    for (final variant in defectVariants) {
      expect(
        additivePlus.hasMatch(stripQuotes(variant)),
        isTrue,
        reason:
            'guard must flag the dispatch-422 defect "$variant" — '
            'any unquoted + is invalid, spacing must not matter',
      );
    }
  });

  test('AC1c: legal +/− uses stay unflagged (no false positives)', () {
    // Negative pins for the tightened additivePlus and the deliberately
    // spaced additiveMinus: `+` has no legal unquoted use, but `-`
    // appears legally in negative literals, hyphenated identifiers
    // (inputs.max-attempts et al.) and suffix concatenation.
    const legalForms = <String>[
      r'${{ inputs.max-attempts }}',
      r'${{ github.event.number == -1 }}',
      r'${{ !inputs.x && env.Y || env.Z }}',
      r"${{ format('0.0.0+1') }}", // + lives inside quotes — stripped
      r'${{ env.X }}-v1', // suffix concatenation: - follows a brace
    ];
    for (final form in legalForms) {
      final bare = stripQuotes(form);
      expect(
        additivePlus.hasMatch(bare),
        isFalse,
        reason: '"$form" is legal — additivePlus must not flag it',
      );
      expect(
        additiveMinus.hasMatch(bare),
        isFalse,
        reason: '"$form" is legal — additiveMinus must not flag it',
      );
    }
  });

  test('AC2: build-macos BUILD_NUMBER sum lives in bash, operands as env', () {
    final doc =
        loadYaml(File('$workflowsDir/build-macos.yml').readAsStringSync())
            as Map;
    final job = (doc['jobs'] as Map)['build-macos'] as Map;
    final steps = job['steps'] as List;
    final buildStep = steps.whereType<Map>().firstWhere(
      (s) => (s['name'] ?? '').toString().startsWith('Build macOS release'),
    );
    final env = Map.castFrom<dynamic, dynamic, dynamic, dynamic>(
      buildStep['env'] as Map,
    );
    expect(
      env['RUN_NUMBER'],
      contains('github.run_number'),
      reason: 'monotonic growth across dispatches (gh-2246)',
    );
    expect(
      env['RUN_ATTEMPT'],
      contains('github.run_attempt'),
      reason:
          'gh-2246: reruns reuse run_number — the attempt term is what '
          'makes re-uploads legal (altool -19232 fix)',
    );
    expect(
      env.keys,
      isNot(contains('BUILD_NUMBER')),
      reason: 'the sum cannot live in an expression (AC1) — no env shortcut',
    );
    final run = buildStep['run'] as String;
    expect(
      run,
      contains(
        r'BUILD_NUMBER=$(( RUN_NUMBER * 10 + RUN_ATTEMPT * 2 + ARCH_INDEX ))',
      ),
      reason:
          'gh-2246 formula preserved exactly — only the computation site '
          'moved to bash (gh-2288)',
    );
    expect(
      run,
      contains(r'[ "$ARCH" = "arm64" ]'),
      reason:
          'gh-2246: sibling arch legs must not race one ASC build — the '
          'arch term must survive the move',
    );
  });
}
