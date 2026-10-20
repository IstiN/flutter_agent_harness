// gh-1689 — Machine Merge Bot must NOT run on fork pull_request events.
//
// The stub triggers on both base-context events (workflow_run / check_run —
// they run in the base repo WITH secrets) and a direct pull_request trigger
// (labeled / synchronize / edited — it runs in the FORK context, where
// GitHub withholds repo secrets). A fork pull_request run therefore invoked
// factory-merge.yml with an empty SOURCE_GITHUB_TOKEN, the minted GH_TOKEN
// was empty and the job died with `gh` exit 4 — a red check on EVERY guest
// PR (live: PR #1615 synchronize, run 39127517548, 2026-10-18; ticket runs
// 38903800958 / 39127305163 — 100% deterministic on forks, never on
// same-repo PRs). The merge itself was never blocked: workflow_run legs
// keep full bot behavior for guest PRs.
//
// Fix contract pinned here (YAML-level, ci_1267 static pattern — no local
// test runs GitHub runners): the `merge` job `if` must evaluate
//   false  for pull_request events whose head repo is a fork (the bug),
//   true   for pull_request events from the base repo (label latch kept:
//          labeled runs only for ai_* / pr_approved, synchronize/edited
//          always — cheap and idempotent),
//   true   for every non-pull_request event name (workflow_run /
//          check_run / workflow_dispatch — base-repo context, secrets
//          present, the actual merge path).
// The expression is EVALUATED, not grepped: a textual rewording that flips
// a boolean (e.g. `==` vs `!=` on the fork flag) fails these tests.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Subset of GitHub Actions expressions used by the machine-merge guard:
/// parentheses, `||`, `&&`, `==`, `!=`, `contains(path, 'lit')`,
/// string/boolean literals and dotted context paths.
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
    if (_matchWord('contains')) {
      _skipWs();
      if (!_match('(')) throw FormatException('expected ( after contains');
      final haystack = parseOperand();
      _skipWs();
      if (!_match(',')) throw FormatException('expected , in contains()');
      _skipWs();
      final needle = parseOperand() as String;
      _skipWs();
      if (!_match(')')) throw FormatException('expected ) closing contains');
      return haystack is String && haystack.contains(needle);
    }
    // Dotted context path.
    final match = RegExp(
      r'[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_*]+)*',
    ).firstMatch(src.substring(pos));
    if (match == null || match.start != 0) {
      throw FormatException('cannot parse operand at $pos in "$src"');
    }
    pos += match.end;
    return ctxLookup(match.group(0)!);
  }

  // Mirrors GitHub semantics closely enough for these scenarios: missing
  // context paths resolve to null (`null == false` is false, `contains()`
  // on null is false) instead of throwing mid-expression.
  Object? ctxLookup(String path) {
    Object? node = ctx; // paths are rooted at the context: github.event...
    for (final part in path.split('.')) {
      if (node is Map && node.containsKey(part)) {
        node = node[part];
      } else {
        return null;
      }
    }
    return node;
  }

  /// Skips leading whitespace, then consumes `s` if present — advances
  /// `pos` past the skipped whitespace AND the matched text on success.
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

YamlMap workflowYaml() =>
    loadYaml(File('.github/workflows/machine-merge.yml').readAsStringSync())
        as YamlMap;

String mergeJobIf() {
  final jobs = workflowYaml()['jobs'] as YamlMap;
  final merge = jobs['merge'] as YamlMap;
  final cond = merge['if'];
  expect(cond, isNotNull, reason: 'merge job must carry a guard `if:`');
  // loadYaml already folds the `>-` scalar; normalize whitespace anyway.
  return (cond as String).replaceAll('\n', ' ').trim();
}

Map<String, Object?> prEvent({
  required bool fork,
  String action = 'synchronize',
  String label = '',
}) => {
  'github': {
    'event_name': 'pull_request',
    'event': {
      'action': action,
      'pull_request': {
        'head': {
          'repo': {'fork': fork},
        },
      },
      'label': {'name': label},
    },
  },
};

Map<String, Object?> namedEvent(String name) => {
  'github': {'event_name': name, 'event': const {}},
};

void main() {
  group('machine-merge fork guard (gh-1689): merge job `if` evaluates', () {
    test(
      'FALSE for a fork pull_request synchronize — the red-run scenario',
      () {
        expect(
          GhExpr.eval(mergeJobIf(), prEvent(fork: true)),
          isFalse,
          reason:
              'fork pull_request events carry NO secrets — running the '
              'factory with an empty SOURCE_GITHUB_TOKEN mints an empty '
              'GH_TOKEN and dies (gh exit 4): a red check on every guest PR',
        );
      },
    );

    test('FALSE for fork pull_request events generally (labeled, edited)', () {
      expect(
        GhExpr.eval(
          mergeJobIf(),
          prEvent(fork: true, action: 'labeled', label: 'ai_task'),
        ),
        isFalse,
      );
      expect(
        GhExpr.eval(mergeJobIf(), prEvent(fork: true, action: 'edited')),
        isFalse,
      );
    });

    test(
      'TRUE for same-repo synchronize / edited (always run — idempotent)',
      () {
        expect(GhExpr.eval(mergeJobIf(), prEvent(fork: false)), isTrue);
        expect(
          GhExpr.eval(mergeJobIf(), prEvent(fork: false, action: 'edited')),
          isTrue,
        );
      },
    );

    test('TRUE for same-repo labeled ai_* / pr_approved, FALSE otherwise '
        '(machine-latch preserved)', () {
      expect(
        GhExpr.eval(
          mergeJobIf(),
          prEvent(fork: false, action: 'labeled', label: 'ai_task'),
        ),
        isTrue,
      );
      expect(
        GhExpr.eval(
          mergeJobIf(),
          prEvent(fork: false, action: 'labeled', label: 'pr_approved'),
        ),
        isTrue,
      );
      expect(
        GhExpr.eval(
          mergeJobIf(),
          prEvent(fork: false, action: 'labeled', label: 'bug'),
        ),
        isFalse,
      );
    });

    test('TRUE for every base-context event name — the real merge path '
        '(workflow_run / check_run keep full bot behavior for guest PRs)', () {
      expect(GhExpr.eval(mergeJobIf(), namedEvent('workflow_run')), isTrue);
      expect(GhExpr.eval(mergeJobIf(), namedEvent('check_run')), isTrue);
      expect(
        GhExpr.eval(mergeJobIf(), namedEvent('workflow_dispatch')),
        isTrue,
      );
    });
  });

  test('fork guard regression demo: the PRE-guard expression runs the job on '
      'a fork synchronize (the gh-1689 bug) — proves the fork arm is '
      'load-bearing', () {
    final preGuard =
        "github.event.action != 'labeled' || "
        "contains(github.event.label.name, 'ai_') || "
        "contains(github.event.label.name, 'pr_approved')";
    expect(
      GhExpr.eval(preGuard, prEvent(fork: true)),
      isTrue,
      reason:
          'without the fork arm a fork synchronize evaluated TRUE and '
          'started the doomed run',
    );
  });
}
