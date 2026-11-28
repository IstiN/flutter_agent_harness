// gh-2462 — a CANCELLED ci.yml run is a non-verdict, never a failure verdict.
//
// 2026-11-27 incident (PR #2438, alarm #2457): ci.yml run 46050811851 on
// d85f766e was cancelled; both required-check aggregate jobs arm on
// `if: always()` and ran against legs concluded `cancelled`. Their gate
// steps classify every non-success/non-skipped leg as a blocker, so the
// check-runs concluded FAILURE — a non-verdict was delivered as a failure
// verdict. SM tick 46054697279 parked #2438 with `validation_failed`, then
// the same tick's silent-update push (2a8eb3c9) could not clear the park
// (factory-side rule: only a HUMAN push clears it) — the SM deadlocked
// itself and a human merge of fb6543e0796e landed an unvalidated tree.
//
// The repo-side half of the SM decision table pinned here (YAML-level,
// ci_1267 static pattern — no local test runs GitHub runners; the park /
// park-clear rule itself lives in dmtools-agentic-workflows/factory-sm.yml
// and is NOT in this repo):
//
//   cancelled run        ⇒ quality-gate / binaries-smoke-gate DO NOT ARM
//                          (aggregate skipped ⇒ required contexts report no
//                          verdict ⇒ the SM's table sees no failure ⇒ no
//                          park; the sm-kicker re-arms on `workflow_run: CI
//                          completed` — any conclusion — and re-dispatches);
//   genuine leg failure  ⇒ aggregates DO arm (fail() reddens the required
//                          check ⇒ the SM's failure verdict ⇒ park works);
//   healthy run          ⇒ aggregates arm and conclude (validation latch).
//
// The expressions are EVALUATED, not grepped: a rewording that flips a
// boolean (`!cancelled()` dropped, `||` vs `&&`) fails these tests.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The GitHub-expressions subset these guards use: parens, `||`, `&&`, `!`,
/// `==`, `!=`, string literals, `true`/`false`, `always()`, `cancelled()`
/// and dotted context paths. Missing paths resolve to null (GitHub-ish:
/// `null == 'x'` is false) instead of throwing mid-expression.
class GhExpr {
  final String src;
  final Map<String, Object?> ctx;
  int pos = 0;
  GhExpr(this.src, this.ctx);

  static bool eval(String expression, Map<String, Object?> ctx) {
    final e = GhExpr(expression, ctx);
    final result = e.parseOr();
    e.expectEnd();
    return result;
  }

  void expectEnd() {
    final rest = src.substring(pos).trim();
    if (rest.isNotEmpty) {
      throw FormatException('trailing input at $pos: "$rest"');
    }
  }

  bool parseOr() {
    var left = parseAnd();
    while (_match('||')) {
      final right = parseAnd();
      left = left || right;
    }
    return left;
  }

  bool parseAnd() {
    var left = parseUnary();
    while (_match('&&')) {
      final right = parseUnary();
      left = left && right;
    }
    return left;
  }

  bool parseUnary() {
    _skipWs();
    if (_match('!') && !src.startsWith('!=', pos)) {
      return !parseUnary();
    }
    if (_match('(')) {
      final inner = parseOr();
      _skipWs();
      if (!_match(')')) {
        throw FormatException('expected ) at $pos in "$src"');
      }
      return inner;
    }
    return parseComparison();
  }

  bool parseComparison() {
    final left = parseOperand();
    _skipWs();
    if (_match('==')) {
      return left == parseOperand();
    }
    if (_match('!=')) {
      return left != parseOperand();
    }
    return left is bool && left; // bare boolean operand
  }

  Object? parseOperand() {
    _skipWs();
    if (_match("'")) {
      final end = src.indexOf("'", pos);
      if (end < 0) throw FormatException('unterminated string at $pos');
      final lit = src.substring(pos, end);
      pos = end + 1;
      return lit;
    }
    if (_matchWord('true')) return true;
    if (_matchWord('false')) return false;
    // Status functions: modelled as context flags — the evaluator's caller
    // decides what "the run was cancelled" means for this scenario.
    if (_matchWord('always')) {
      _matchParens();
      return true;
    }
    if (_matchWord('cancelled')) {
      _matchParens();
      return ctx['_runCancelled'] == true;
    }
    // Dotted context path (job keys like `release-pending` carry hyphens).
    final match = RegExp(
      r'[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*',
    ).firstMatch(src.substring(pos));
    if (match == null || match.start != 0) {
      throw FormatException('cannot parse operand at $pos in "$src"');
    }
    pos += match.end;
    return ctxLookup(match.group(0)!);
  }

  void _matchParens() {
    _skipWs();
    if (!_match('(')) throw FormatException('expected ( after function');
    _skipWs();
    if (!_match(')')) throw FormatException('expected ) closing function');
  }

  Object? ctxLookup(String path) {
    Object? node = ctx; // paths are rooted at the context: github.*/needs.*
    for (final part in path.split('.')) {
      if (node is Map && node.containsKey(part)) {
        node = node[part];
      } else {
        return null;
      }
    }
    return node;
  }

  bool _match(String s) {
    _skipWs();
    if (src.startsWith(s, pos)) {
      pos += s.length;
      return true;
    }
    return false;
  }

  bool _matchWord(String w) {
    _skipWs();
    if (src.startsWith(w, pos)) {
      pos += w.length;
      return true;
    }
    return false;
  }

  void _skipWs() {
    while (pos < src.length && (src[pos] == ' ' || src[pos] == '\n')) {
      pos++;
    }
  }
}

YamlMap ciYaml() =>
    loadYaml(File('.github/workflows/ci.yml').readAsStringSync()) as YamlMap;

String jobIf(String jobKey) {
  final jobs = ciYaml()['jobs'] as YamlMap;
  final job = jobs[jobKey] as YamlMap;
  final cond = job['if'];
  expect(cond, isNotNull, reason: '$jobKey must carry a guard `if:`');
  // loadYaml folds folded scalars; normalize anyway (multi-line `if: >-`).
  return (cond as String).replaceAll('\n', ' ').trim();
}

/// Context for an SM validation-dispatch (workflow_dispatch on a PR head):
/// `pending`/`dedupe` read as on the live dispatches, every needs leg at
/// [legResult] unless overridden per-job, `cancelled` = was the RUN cancelled.
Map<String, Object?> dispatchCtx({
  required bool runCancelled,
  String? Function(String job)? legResult,
  String eventName = 'workflow_dispatch',
}) {
  String res(String job) {
    final r = legResult?.call(job);
    if (r != null) return r;
    return runCancelled ? 'cancelled' : 'success';
  }

  String r(String job) => res(job);
  final needs = <String, Object?>{};
  for (final job in [
    'release-pending',
    'release-dedupe',
    'changes',
    'static',
    'flutter-analyze',
    'test-core',
    'coverage-gate',
    'guards',
    'flutter-tests',
    'app-crap-gate',
    'test-faui',
    'binaries-pr',
    'quality-gate',
  ]) {
    needs[job] = {'result': r(job), 'outputs': {}};
  }
  needs['release-pending'] = {
    'result': r('release-pending'),
    'outputs': {'pending': 'true'},
  };
  needs['release-dedupe'] = {
    'result': r('release-dedupe'),
    'outputs': {'dedupe': 'false'},
  };
  return {
    '_runCancelled': runCancelled,
    'github': {'event_name': eventName},
    'needs': needs,
  };
}

void main() {
  group('gh-2462 Defect A — cancelled run ⇒ no failure verdict (no park)', () {
    test('quality-gate does NOT arm on a cancelled validation run', () {
      // The 46050811851 shape: run cancelled mid-flight — settled legs keep
      // `success`, the rest conclude `cancelled`. The aggregate must SKIP
      // (no check-run conclusion) so the SM sees a non-verdict and
      // re-dispatches, instead of failing and parking the PR.
      final ctx = dispatchCtx(
        runCancelled: true,
        legResult: (job) =>
            {'static', 'flutter-analyze', 'test-core'}.contains(job)
            ? 'success'
            : '',
      );
      expect(
        GhExpr.eval(jobIf('quality-gate'), ctx),
        isFalse,
        reason:
            'quality-gate arms on a cancelled run — its fail() then '
            'classifies the cancelled legs as blockers and the required '
            'check concludes FAILURE off a non-verdict: this is exactly '
            'the false validation_failed park that stranded #2438 '
            '(#2457). The job `if` must refuse to arm when the run is '
            'cancelled (!cancelled()).',
      );
    });

    test('binaries-smoke-gate does NOT arm on a cancelled validation run', () {
      // Same always() trap: `Fail the gate` exits 1 on a non-success/
      // non-skipped binaries-pr — a cancelled run would conclude this
      // required context FAILURE as well.
      final ctx = dispatchCtx(
        runCancelled: true,
        legResult: (job) => job == 'binaries-pr' ? 'cancelled' : 'success',
      );
      expect(
        GhExpr.eval(jobIf('binaries-smoke-gate'), ctx),
        isFalse,
        reason:
            'binaries-smoke-gate arms on a cancelled run and fails the '
            'required context off cancelled legs — the second false '
            'validation_failed source (gh-2462). Must refuse to arm '
            '(!cancelled()).',
      );
    });

    test(
      'js-ext-integration cannot arm on a cancelled run (no always() trap)',
      () {
        // Its `if` carries NO always(): the implicit success() gate keeps it
        // skipped whenever a need is cancelled/skipped/failed. Pin the shape —
        // adding always() here would recreate the failure-off-cancel trap.
        final cond = jobIf('js-ext-integration');
        expect(cond.contains('always()'), isFalse);
      },
    );
  });

  group('gh-2462 Defect A — genuine verdicts unchanged', () {
    test('a genuine leg failure still arms quality-gate (SM park works)', () {
      final ctx = dispatchCtx(
        runCancelled: false,
        legResult: (job) => job == 'flutter-tests' ? 'failure' : 'success',
      );
      expect(
        GhExpr.eval(jobIf('quality-gate'), ctx),
        isTrue,
        reason:
            'the aggregate must still arm on a REAL failure so fail() '
            'reddens the required check — that failure verdict is the '
            'SM decision table\'s genuine park input.',
      );
    });

    test('a healthy run still arms quality-gate (validation latch)', () {
      expect(
        GhExpr.eval(jobIf('quality-gate'), dispatchCtx(runCancelled: false)),
        isTrue,
      );
    });

    test('the skipped-security dodge still arms quality-gate (#796/#801)', () {
      // Skipped security legs are a DODGE, not a pass: the aggregate must
      // still arm so `Fail on any real failure` can fail it. !cancelled()
      // must only ever suppress the CANCELLED case.
      final ctx = dispatchCtx(
        runCancelled: false,
        legResult: (job) => job == 'supply-chain' ? 'skipped' : 'success',
      );
      expect(GhExpr.eval(jobIf('quality-gate'), ctx), isTrue);
    });

    test('a healthy validation run still arms binaries-smoke-gate', () {
      expect(
        GhExpr.eval(
          jobIf('binaries-smoke-gate'),
          dispatchCtx(runCancelled: false),
        ),
        isTrue,
      );
      // PR pushes carry the gate too (branch protection context).
      final prCtx = dispatchCtx(runCancelled: false, eventName: 'pull_request');
      expect(GhExpr.eval(jobIf('binaries-smoke-gate'), prCtx), isTrue);
    });
  });

  group('gh-2462 Defect A — the re-arm surface (kicker)', () {
    YamlMap kickerTriggers() {
      final doc =
          loadYaml(File('.github/workflows/sm-kicker.yml').readAsStringSync())
              as YamlMap;
      return (doc['on'] ?? doc[true]) as YamlMap;
    }

    test(
      'kicker re-arms on ANY completed CI run — a cancelled run included',
      () {
        // A cancelled run leaves no verdict behind; the re-dispatch path is
        // the kicker's workflow_run arm (factory-sm-kicker re-arms the SM,
        // which dispatches fresh ci.yml on the head). `types: [completed]`
        // fires for cancelled completions too — pin it: a narrowed type
        // list (e.g. success-only) would strand a cancelled run with no
        // re-dispatch trigger.
        final wr = kickerTriggers()['workflow_run'] as YamlMap;
        expect((wr['workflows'] as YamlList).contains('CI'), isTrue);
        expect((wr['types'] as YamlList), contains('completed'));
      },
    );

    test('kicker re-arms on any non-main push (the silent-update head)', () {
      // The SM silent-update pushes a new head onto the PR branch; the
      // kicker's push arm (branches-ignore: [main]) is the repo-side
      // surface that reaches the factory tick with the NEW head SHA. The
      // factory-side half — clearing its own park off that push — is
      // documented in gh-2462/rca.md (external repo, not changeable here).
      final push = kickerTriggers()['push'] as YamlMap;
      expect((push['branches-ignore'] as YamlList), contains('main'));
      expect(
        push.containsKey('branches'),
        isFalse,
        reason: 'branches-ignore (any non-main ref), not a whitelist',
      );
    });
  });
}
