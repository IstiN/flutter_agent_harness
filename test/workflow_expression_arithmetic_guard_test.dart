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

/// Any space-delimited `+` — never valid in a GitHub expression outside
/// a quoted string literal.
final additivePlus = RegExp(r'\s\+\s');

/// Space-delimited binary `-` between operand-ish tokens (version
/// strings inside quotes are stripped first; this is the subtraction
/// form the same parser defect class would produce).
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
