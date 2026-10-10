// Issue #584: the tag-release publish leg builds a staged copy of the repo
// (scripts/stage_publish_package.sh, called from the "Stage publishable
// package" step) and runs `dart pub get` inside it. If any `path:`
// dependency of the core pubspec is stripped by the staging rsync filters,
// resolution dies with exit 66 AFTER a tag is cut — v0.1.406 and v0.1.407
// both blocked releases this way.
//
// These tests parse the staging script's rsync include/exclude list (single
// source of truth — no copy of the filter list lives here) and simulate
// rsync's first-match-wins filtering to prove the staged tree stays
// self-consistent: every path dependency of pubspec.yaml lands in the stage,
// and pubspec_overrides.yaml (workspace-only dart_tui pin, never published)
// does not leak into it.
//
// ponytail: static filter simulation, not a real rsync run — CI has no
// guarantee of rsync here; upgrade to executing the stage if filters grow
// semantics this simulator can't express (patterns beyond *, **, ?, trailing /).
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _stagingScript = 'scripts/stage_publish_package.sh';
const _stageMarker = 'rsync -a';
const _overridesFile = 'pubspec_overrides.yaml';

class _Filter {
  _Filter(this.include, this.pattern)
    : dirOnly = pattern.endsWith('/'),
      anchored = pattern.contains('/') {
    final unanchored = pattern.endsWith('/')
        ? pattern.substring(0, pattern.length - 1)
        : pattern;
    // rsync anchors a leading `/` on the transfer root — the body itself
    // carries no slash (issue #613).
    body = unanchored.startsWith('/') ? unanchored.substring(1) : unanchored;
  }

  final bool include;
  final String pattern;
  final bool dirOnly;
  final bool anchored;
  late final String body;
}

/// Ordered include/exclude list of the staging rsync command in the script.
List<_Filter> _stagingFilters() {
  final lines = File(_stagingScript).readAsLinesSync();
  final start = lines.indexWhere((l) => l.contains(_stageMarker));
  if (start < 0) {
    fail(
      'staging rsync command not found in $_stagingScript — update this test',
    );
  }
  final filters = <_Filter>[];
  // The command continues across lines ending with a backslash.
  var block = [lines[start]];
  for (var i = start + 1; i < lines.length; i++) {
    block.add(lines[i]);
    // The last line of the command carries no trailing backslash —
    // stopping BEFORE adding it silently dropped its filters (issue #613).
    if (!lines[i].trimRight().endsWith(r'\')) break;
  }
  final argPattern = RegExp(r"--(include|exclude) '([^']+)'");
  for (final line in block) {
    for (final m in argPattern.allMatches(line)) {
      filters.add(_Filter(m.group(1) == 'include', m.group(2)!));
    }
  }
  return filters;
}

bool _globMatch(String glob, String s) {
  final sb = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        sb.write('.*');
        i++;
      } else {
        sb.write('[^/]*');
      }
    } else if (c == '?') {
      sb.write('[^/]');
    } else {
      sb.write(RegExp.escape(c));
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString()).hasMatch(s);
}

bool _matches(_Filter f, String path, bool isDir) {
  if (f.dirOnly && !isDir) return false;
  if (f.anchored) return _globMatch(f.body, path);
  // Unanchored patterns match against any single path component.
  return path.split('/').any((c) => _globMatch(f.body, c));
}

/// rsync first-match-wins for one path: true = transferred, false = excluded.
bool _firstMatchKeeps(List<_Filter> filters, String path, bool isDir) {
  for (final f in filters) {
    if (_matches(f, path, isDir)) return f.include;
  }
  return true; // no rule matched -> transferred
}

/// Would rsync transfer [file]? Every ancestor dir must stay descendable
/// (an excluded parent prunes the whole subtree regardless of child rules).
bool _landsInStage(List<_Filter> filters, String file) {
  final parts = file.split('/');
  for (var i = 1; i < parts.length; i++) {
    if (!_firstMatchKeeps(filters, parts.sublist(0, i).join('/'), true)) {
      return false;
    }
  }
  return _firstMatchKeeps(filters, file, false);
}

/// name -> path target for every path dependency of pubspec.yaml.
Map<String, String> _pubspecPathDeps() {
  final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  final deps = <String, String>{};
  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    final m = pubspec[section];
    if (m is! YamlMap) continue;
    m.forEach((name, spec) {
      if (spec is YamlMap && spec['path'] is String) {
        deps[name as String] = spec['path'] as String;
      }
    });
  }
  return deps;
}

/// gh-1220: the root .pubignore mirroring the staged package surface
/// (scripts/stage_publish_package.sh) for pub's own file selection.
const _pubIgnoreFile = '.pubignore';

/// One .pubignore line. The mirror contract only carries root-ANCHORED
/// gitignore patterns (leading `/`, dir-only trailing `/`, `*` that never
/// crosses `/`, `!` negation) — anything else fails loudly so the simulator
/// can never silently disagree with pub's engine.
class _PubIgnoreRule {
  _PubIgnoreRule(this.line)
    : negated = line.startsWith('!'),
      dirOnly = line.endsWith('/') {
    var body = line;
    if (negated) body = body.substring(1);
    if (dirOnly) body = body.substring(0, body.length - 1);
    var anchored = body.startsWith('/');
    if (anchored) body = body.substring(1);
    anchored = anchored || body.contains('/');
    if (!anchored) {
      fail(
        'unsupported .pubignore pattern "$line" — only root-anchored '
        'patterns belong in the mirror; extend this simulator deliberately',
      );
    }
    this.body = body;
  }

  final String line;
  final bool negated;
  final bool dirOnly;
  late final bool anchored;
  late final String body;

  bool matches(String path, bool isDir) {
    if (dirOnly && !isDir) return false;
    return _globMatch(body, path);
  }
}

List<_PubIgnoreRule> _pubIgnoreRules() {
  final f = File(_pubIgnoreFile);
  if (!f.existsSync()) return const [];
  final rules = <_PubIgnoreRule>[];
  for (var raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    rules.add(_PubIgnoreRule(line));
  }
  return rules;
}

/// gitignore semantics for the anchored patterns .pubignore uses: rules are
/// evaluated per path prefix, last match wins, and once a directory is
/// ignored its whole subtree is ignored (nothing re-includes from below —
/// the `dir/*` + `!dir/kept` allowlist idiom works because `*` matches the
/// child entry, never the parent).
bool _ignoredByPubIgnore(List<_PubIgnoreRule> rules, String path, bool isDir) {
  var ignored = false;
  final parts = path.split('/');
  for (var i = 1; i <= parts.length; i++) {
    if (ignored) return true; // inside an ignored dir — pruned regardless
    final prefix = parts.sublist(0, i).join('/');
    final prefixIsDir = i < parts.length;
    for (final r in rules) {
      if (r.matches(prefix, prefixIsDir)) ignored = !r.negated;
    }
  }
  return ignored;
}

/// Would pub's payload (git-tracked files ∩ .pubignore) carry [file]?
bool _publishedByPub(String file) =>
    !_ignoredByPubIgnore(_pubIgnoreRules(), file, false);

void main() {
  group('publish staging self-consistency (issue #584)', () {
    test('staging rsync block carries filter rules', () {
      expect(
        _stagingFilters(),
        isNotEmpty,
        reason: 'no --include/--exclude rules parsed from $_stagingScript',
      );
    });

    test('every pubspec path dependency lands in the staged tree', () {
      final filters = _stagingFilters();
      final deps = _pubspecPathDeps();
      expect(
        deps,
        isNotEmpty,
        reason: 'fixture sanity: pubspec.yaml has path deps',
      );
      for (final entry in deps.entries) {
        final probe = '${entry.value}/pubspec.yaml';
        expect(
          File(probe).existsSync(),
          isTrue,
          reason: '$probe missing from the working tree itself',
        );
        expect(
          _landsInStage(filters, probe),
          isTrue,
          reason:
              'staging strips ${entry.value} but pubspec.yaml keeps '
              '${entry.key} on it — `dart pub get` in the publish stage dies '
              'with exit 66 (v0.1.407, issue #584)',
        );
      }
    });

    test('pubspec_overrides.yaml never leaks into the staged tree', () {
      // Workspace-only dart_tui pin (path: vendor/dart_tui); shipped into the
      // stage it re-dangles dart_tui onto the excluded vendor dir — the exact
      // v0.1.407 failure. The published package resolves hosted dart_tui.
      expect(
        _landsInStage(_stagingFilters(), _overridesFile),
        isFalse,
        reason: '$_overridesFile must be excluded from the publish stage',
      );
    });

    test('root-scoped excludes prune only the repo root (issue #613)', () {
      // v0.1.411: unanchored `--exclude 'memory'` matched ANY directory
      // named `memory`, pruning lib/src/memory/ out of the stage — the
      // published package shipped broken memory imports. Root-scoped
      // excludes must be anchored; package subtrees must survive.
      final filters = _stagingFilters();
      expect(
        _landsInStage(filters, 'lib/src/memory/memory_controller.dart'),
        isTrue,
        reason:
            'lib/src/memory/ is package surface — pruning it ships '
            'uri_does_not_exist (v0.1.411, issue #613)',
      );
      expect(
        _landsInStage(filters, 'memory/note/n_0001_abcd.md'),
        isFalse,
        reason: 'the repo-root memory/ dir stays out of the stage',
      );
      expect(
        _landsInStage(filters, 'docs/architecture.md'),
        isFalse,
        reason: 'the repo-root docs/ dir stays out of the stage',
      );
    });
  });

  // ── gh-1220 — the root .pubignore mirrors the staged surface ─────────────
  // `dart publish` packs everything under the package root that git tracks
  // and .pubignore does not exclude. The nightly/PR dry-runs validate at the
  // REPO ROOT, where pub otherwise packs the sub-projects too: the
  // flutter_app fastlane fixtures (fake keys, #1046) trip the publish leak
  // detector (nightly 37177316619, exit 65) and the payload reads 101.5 MB.
  // scripts/stage_publish_package.sh (#597) already defines the canonical
  // package surface for the real publish — .pubignore mirrors it so the
  // root-level dry-run rehearses the payload pub actually ships. The
  // fixtures stay byte-identical on disk (fastlane tests consume them
  // as-is); the leak validator is not weakened — the files simply stop
  // being published content.
  group('publish .pubignore mirrors the staged surface (gh-1220)', () {
    test('.pubignore exists and parses', () {
      expect(
        _pubIgnoreRules(),
        isNotEmpty,
        reason:
            '$_pubIgnoreFile missing or empty — the root-level '
            '`dart publish --dry-run` packs the sub-projects again',
      );
    });

    test('fastlane fake-key fixtures never ride the publish payload', () {
      // The two files the leak detector flagged (nightly 37177316619).
      const fixtures = [
        'flutter_app/fastlane/test/fixtures/store_appearance/test_asc_key.p8',
        'flutter_app/fastlane/test/fixtures/store_appearance/test_play_service_account.json',
      ];
      for (final f in fixtures) {
        expect(
          File(f).existsSync(),
          isTrue,
          reason: '$f must stay on disk — fastlane tests consume it as-is',
        );
        expect(
          _publishedByPub(f),
          isFalse,
          reason:
              '$f is fake test data with no consumer in the pub package — '
              'shipping it re-trips the publish leak detector (gh-1220)',
        );
      }
      // The whole fixtures tree goes with them.
      expect(
        _publishedByPub(
          'flutter_app/fastlane/test/fixtures/store_appearance/asc_apps.json',
        ),
        isFalse,
      );
    });

    test('dev path-dependency subtrees still ship (issue #584)', () {
      // The allowlist half of the mirror: pubspec.yaml keeps these on
      // path: sources — .pubignore must not prune them or the published
      // package fails to resolve (the v0.1.407 class of failure).
      for (final probe in [
        'vendor/xterm/pubspec.yaml',
        'vendor/xterm/lib/core.dart',
        'packages/fa_llm_mock/pubspec.yaml',
        'packages/fa_llm_mock/lib/fa_llm_mock.dart',
      ]) {
        expect(
          _publishedByPub(probe),
          isTrue,
          reason:
              '$probe is dev path-dependency surface — .pubignore must '
              'keep it publishable',
        );
      }
    });

    test('package surface is not over-excluded', () {
      for (final probe in [
        'lib/flutter_agent_harness.dart',
        'bin/fah.dart',
        'test/publish_staging_test.dart',
        'prompts/skills/create-goal/SKILL.md',
      ]) {
        expect(
          _publishedByPub(probe),
          isTrue,
          reason: '$probe is package surface',
        );
      }
    });

    test('root-scoped staging excludes are mirrored in .pubignore', () {
      // Anti-drift: every root-scoped tree the stage script strips (the
      // single source of truth for "not part of the pub package") must
      // also be covered by .pubignore, or the root-level dry-run packs it
      // again. Non-root-scoped filters (build, .dart_tool, coverage) are
      // gitignored already and never reach pub's file list.
      //
      // gh-1511: .pubignore may carry NEGATIONS the stage deliberately
      // does not mirror (publishing FROM packages/fa_llm needs the tree
      // visible to pub's upward ignore walk, but fa_llm is not a core
      // path dep and must NOT ride the staged core payload). A negated
      // child of a `/*`-scoped exclude is tolerated here ONLY when it is
      // pinned by the explicit-allowlist test below.
      final rules = _pubIgnoreRules();
      expect(rules, isNotEmpty);
      final negated = rules
          .where((r) => r.negated)
          .map((r) => r.body)
          .toSet();
      var checked = 0;
      for (final f in _stagingFilters()) {
        if (f.include || !f.anchored) continue;
        checked++;
        if (f.body.endsWith('/*')) {
          // Child-scoped exclude (vendor/*, packages/*): enumerate the
          // REAL children on disk — probing a literal `packages/*` path
          // would let a stray un-negated sibling slip through unnamed.
          final root = f.body.substring(0, f.body.length - 2);
          final dir = Directory(root);
          if (dir.existsSync()) {
            for (final child in dir.listSync().whereType<Directory>()) {
              if (negated.contains(child.path)) continue;
              expect(
                _ignoredByPubIgnore(rules, '${child.path}/pubspec.yaml', false),
                isTrue,
                reason:
                    'the stage strips /${f.body} but .pubignore does not '
                    'exclude ${child.path} — the root-level dry-run packs '
                    'the tree again (gh-1220)',
              );
            }
            continue;
          }
        }
        expect(
          _ignoredByPubIgnore(rules, '${f.body}/pubspec.yaml', false),
          isTrue,
          reason:
              'the stage strips /${f.body} but .pubignore does not exclude '
              'it — the root-level dry-run packs the tree again (gh-1220)',
        );
      }
      expect(
        checked,
        greaterThan(0),
        reason: 'lint is real: root-scoped stage excludes must exist',
      );
    });

    test('pubspec_overrides.yaml never rides the pub payload', () {
      expect(
        _publishedByPub(_overridesFile),
        isFalse,
        reason:
            'workspace-only dart_tui pin — shipped, it dangles dart_tui '
            'onto the excluded vendor dir (v0.1.407)',
      );
    });

    test('CHANGELOG_ARCHIVE.md never rides the publish payload (gh-1452)', () {
      // The archive is the lossless tail of the trimmed CHANGELOG.md (PR
      // #1462) — GitHub carries the per-version history, pub consumers
      // never read it, and it grows ~230 KB/year at the current release
      // cadence. It must be excluded from BOTH publish surfaces together:
      // .pubignore mirrors stage_publish_package.sh (gh-1220), and the
      // root-level dry-run packs whatever .pubignore does not exclude.
      expect(
        File('CHANGELOG_ARCHIVE.md').existsSync(),
        isTrue,
        reason: 'fixture sanity: the archive stays on disk (git history)',
      );
      expect(
        _landsInStage(_stagingFilters(), 'CHANGELOG_ARCHIVE.md'),
        isFalse,
        reason: 'the archive must stay out of the staged publish tree',
      );
      expect(
        _publishedByPub('CHANGELOG_ARCHIVE.md'),
        isFalse,
        reason:
            '.pubignore must mirror the stage — otherwise the root-level '
            '`dart publish --dry-run` packs the archive into the payload '
            '(gh-1220 mirror drift)',
      );
    });
  });

  // ── gh-1511 — a sub-package publish must see its own tree ────────────
  // Pub walks ignore rules up to the git root, so the root .pubignore's
  // /packages/* hid packages/fa_llm from its OWN publish: `dart pub
  // publish --dry-run` in packages/fa_llm failed with "The pubspec is
  // hidden" + "missing LICENSE", and the tag-triggered OIDC publish
  // (publish-fa-llm.yml) would have died the same way. The
  // !/packages/fa_llm/ negation is pubignore-ONLY — the staging rsync
  // keeps fa_llm out of the core payload (it is not a core path dep);
  // the anti-drift mirror test above tolerates the divergence ONLY for
  // negations pinned by the explicit-allowlist test below.
  group('gh-1511 — sub-package publish sees its own tree', () {
    test('fa_llm payload carries its own required files', () {
      for (final probe in [
        'packages/fa_llm/pubspec.yaml',
        'packages/fa_llm/LICENSE',
        'packages/fa_llm/README.md',
        'packages/fa_llm/CHANGELOG.md',
        'packages/fa_llm/lib/fa_llm.dart',
      ]) {
        expect(
          File(probe).existsSync(),
          isTrue,
          reason: 'fixture sanity: $probe is on disk',
        );
        expect(
          _publishedByPub(probe),
          isTrue,
          reason:
              'pub walks ignore rules up to the git root — /packages/* '
              'hides packages/fa_llm from its own publish (dry-run: "The '
              'pubspec is hidden" + "missing LICENSE", gh-1511)',
        );
      }
    });

    test('.pubignore negations are an explicit allowlist', () {
      // Every negated tree ships on the pub payload; only fa_llm_mock and
      // vendor/xterm are mirrored by a stage INCLUDE (core path
      // dev-deps), fa_llm is pubignore-only (gh-1511). A negation
      // outside this set is mirror drift the anti-drift test would
      // otherwise silently tolerate.
      final negated = _pubIgnoreRules()
          .where((r) => r.negated)
          .map((r) => r.body)
          .toSet();
      expect(
        negated,
        unorderedEquals([
          'vendor/xterm',
          'packages/fa_llm_mock',
          'packages/fa_llm',
        ]),
      );
    });

    test('other packages/* trees stay out of the pub payload', () {
      // /packages/* + !fa_llm_mock + !fa_llm must keep hiding every
      // sibling: dap_hub and fa_ui are repo tooling, fa_llm_flutter is
      // publish_to: none (never published from this repo, so it needs no
      // sub-package visibility either).
      for (final probe in [
        'packages/dap_hub/pubspec.yaml',
        'packages/fa_ui/pubspec.yaml',
        'packages/fa_llm_flutter/pubspec.yaml',
      ]) {
        if (!File(probe).existsSync()) continue;
        expect(
          _publishedByPub(probe),
          isFalse,
          reason:
              '$probe is not part of the pub package — only fa_llm_mock '
              '(core path dev-dep) and fa_llm (gh-1511 sub-package '
              'publish) may negate /packages/*',
        );
      }
    });
  });
}
