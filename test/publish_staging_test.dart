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
      final rules = _pubIgnoreRules();
      expect(rules, isNotEmpty);
      var checked = 0;
      for (final f in _stagingFilters()) {
        if (f.include || !f.anchored) continue;
        checked++;
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

  // ── gh-1522 — the tag is the version; the stage is stamped from it ───────
  // The committed pubspecs carry the FIXED 0.0.0-dev placeholder (CI guards
  // hand-bumps in the static job) and the real version is stamped into the
  // STAGED tree at publish time. These tests pin the stamp contract so the
  // tag↔staged-file invariant cannot silently rot.
  group('gh-1522 — tag-sourced version stamp', () {
    test('committed pubspecs carry the 0.0.0-dev placeholder', () {
      for (final f in ['pubspec.yaml', 'flutter_app/pubspec.yaml']) {
        final pubspec = loadYaml(File(f).readAsStringSync()) as YamlMap;
        final version = pubspec['version']?.toString() ?? '';
        expect(
          version.split('+').first,
          '0.0.0-dev',
          reason:
              '$f must carry the 0.0.0-dev placeholder (gh-1522) — the git '
              'tag is the single source of truth; a hand-bump desyncs the '
              'staged stamp and reintroduces the lockfile churn this ticket '
              'retires',
        );
      }
    });

    test(
      'stage script forwards an optional version to the stamper, after the size guard',
      () {
        final script = File(_stagingScript).readAsStringSync();
        final guard = script.indexOf('size=\$(du -sm');
        final stamp = script.indexOf('/stamp_staged_release.sh"');
        expect(
          stamp,
          greaterThan(guard),
          reason:
              'the stamp must run on the COMPLETE staged tree (after the '
              'rsync + size guard), never before',
        );
        expect(script, contains('if [ "\${2:-}" ]'));
      },
    );

    test('stamper enforces the tag↔staged-version invariant before upload', () {
      final stamp = File('scripts/stamp_staged_release.sh').readAsStringSync();
      // The stamp writes the version, then GUARDS staged == <version> —
      // a desync (missing version line, second version field) fails before
      // the upload instead of shipping 0.0.0-dev to pub.dev.
      final sed = stamp.indexOf('sed -i "s/^version:');
      final guard = stamp.indexOf("!= \"\$version\"");
      expect(sed, greaterThan(-1));
      expect(guard, greaterThan(sed));
      // The changelog section comes from release_notes.sh (curated section →
      // curated Unreleased → conventional-commits fallback) and the staged
      // file never shows an `## Unreleased` header.
      expect(stamp, contains('release_notes.sh'));
      expect(stamp, contains('## Unreleased'));
    });

    test(
      'staged changelog is capped: guard runs, oldest sections trim, re-check',
      () {
        // Mirrors the changelog_cap_guard wiring — asserted here as part of
        // the stamp contract (the stage is a publish surface).
        final stamp = File(
          'scripts/stamp_staged_release.sh',
        ).readAsStringSync();
        expect(stamp, contains('check_changelog_size.sh'));
        expect(stamp, contains('keeping only the fresh section'));
      },
    );

    test(
      'ci.yml publish stage passes the tag version and verifies the staged stamp',
      () {
        final ci = File('.github/workflows/ci.yml').readAsStringSync();
        final publish = ci.indexOf('  publish:');
        expect(publish, greaterThan(0));
        expect(
          ci.contains(
            'stage_publish_package.sh /tmp/publish-stage "\${GITHUB_REF_NAME#v}"',
          ),
          isTrue,
          reason:
              'the publish job must stamp the stage from the TAG '
              '(v1.0.550 → 1.0.550), not ship the placeholder',
        );
        final stage = ci.indexOf(
          'stage_publish_package.sh /tmp/publish-stage',
          publish,
        );
        final verify = ci.indexOf('Verify staged version matches tag', stage);
        expect(
          verify,
          greaterThan(stage),
          reason:
              'the staged-version↔tag guard must run after staging, before '
              'the upload (gh-1522)',
        );
      },
    );

    test(
      'install_local.sh stamps version.txt from git describe, not the pubspec',
      () {
        // gh-1522 AC4: `fa --version` shows the stamped value from
        // install_local.sh builds — the committed pubspec is the 0.0.0-dev
        // placeholder, so the build entry point must derive the version from
        // the tags (`git describe`), never from a pubspec grep.
        final install = File('install_local.sh').readAsStringSync();
        expect(install, contains('git describe --tags'));
        expect(
          RegExp(r"grep .^.version:").hasMatch(install),
          isFalse,
          reason:
              'install_local.sh must not read the version from pubspec.yaml — '
              'that is the 0.0.0-dev placeholder now (gh-1522)',
        );
        expect(install, contains('version.txt'));
      },
    );

    test('nightly dry-run rehearses the tag-stamped stage', () {
      final nightly = File('.github/workflows/nightly.yml').readAsStringSync();
      expect(
        nightly.contains(
          'stage_publish_package.sh /tmp/publish-stage "\$next"',
        ),
        isTrue,
        reason:
            'the nightly publish dry-run must validate the STAMPED staged '
            'tree (gh-1522 risk note: the dry-run now also validates the '
            'stamp, not only the payload)',
      );
    });
  });

  // ── gh-1522 rework (PR #1526 thread) — the stamper, exercised ────────────
  // The string assertions above pin the WIRING; this group runs the real
  // script against a fixture stage and asserts the staged BYTES — a bad
  // stamp ships 0.0.0-dev or a malformed changelog to pub.dev. The fixture
  // repo dir doubles as the CWD: release_notes.sh reads CHANGELOG.md from
  // the CWD, exactly like the publish job running at the repo root.
  group('gh-1522 rework — stamp_staged_release.sh behavior', () {
    final tmp = Directory.systemTemp.createTempSync('stamp-fixture-');

    /// A fixture "repo" (CWD for the run) plus a staged tree inside it.
    _StampFixture fixture({String? repoChangelog, String? stagedChangelog}) {
      final dir = Directory(
        '${tmp.path}/fx-${tmp.listSync().length}',
      )..createSync(recursive: true);
      final repo = '${dir.path}/repo';
      final stage = '${dir.path}/stage';
      Directory(repo).createSync();
      Directory(stage).createSync();
      File('$repo/CHANGELOG.md').writeAsStringSync(
        repoChangelog ??
            '# Changelog\n\nCurated window.\n\n## Unreleased\n\n'
                '- pending bullet\n\n## 1.0.998\n\n- old entry\n',
      );
      File('$stage/pubspec.yaml').writeAsStringSync(
        'name: fa\nversion: 0.0.0-dev\n',
      );
      File('$stage/CHANGELOG.md').writeAsStringSync(
        stagedChangelog ?? File('$repo/CHANGELOG.md').readAsStringSync(),
      );
      return _StampFixture(repo: repo, stage: stage);
    }

    ProcessResult stamp(_StampFixture fx, String version) => Process.runSync(
      'bash',
      [
        File('scripts/stamp_staged_release.sh').absolute.path,
        fx.stage,
        version,
      ],
      workingDirectory: fx.repo,
    );

    test('stamps the pubspec to exactly the tag version', () {
      final fx = fixture();
      final r = stamp(fx, '1.0.999');
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(
        File('${fx.stage}/pubspec.yaml').readAsStringSync(),
        contains('version: 1.0.999'),
      );
    });

    test(
      'folds the curated Unreleased body under the tag section; no Unreleased header survives',
      () {
        final fx = fixture();
        final r = stamp(fx, '1.0.999');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final staged = File('${fx.stage}/CHANGELOG.md').readAsStringSync();
        expect(staged, isNot(contains('## Unreleased')));
        expect(staged, contains('## 1.0.999'));
        expect(staged, contains('- pending bullet'));
        // the older curated section is preserved after the fresh one
        expect(staged, contains('## 1.0.998'));
        expect(
          staged.indexOf('## 1.0.999'),
          lessThan(staged.indexOf('## 1.0.998')),
        );
      },
    );

    test(
      'generated section matches the repo formatting convention (blank lines, PR #1526 thread 4)',
      () {
        final fx = fixture();
        final r = stamp(fx, '1.0.999');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final staged = File('${fx.stage}/CHANGELOG.md').readAsStringSync();
        // blank line after the fresh section header, and a blank line
        // between the fresh section and the next `## ` — raw markdown must
        // not run sections together (the repo's hand-curated convention).
        expect(staged, contains('## 1.0.999\n\n- pending bullet'));
        expect(staged, contains('- pending bullet\n\n## 1.0.998'));
      },
    );

    test(
      'over-cap staged file trims oldest-first, keeping the fresh section',
      () {
        // A ~300 KiB older section plus the small fresh one: the trim must
        // drop the old section so the staged file lands under the pub.dev
        // cap.
        final old = 'x' * 300000;
        final fx = fixture(
          stagedChangelog:
              '# Changelog\n\n## Unreleased\n\n- pending bullet\n\n'
              '## 1.0.998\n\n- $old\n',
        );
        final r = stamp(fx, '1.0.999');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final stagedFile = File('${fx.stage}/CHANGELOG.md');
        expect(
          stagedFile.lengthSync(),
          lessThan(262144),
          reason: 'the staged changelog must fit the pub.dev cap',
        );
        final staged = stagedFile.readAsStringSync();
        expect(staged, contains('## 1.0.999'));
        expect(staged, contains('- pending bullet'));
        expect(staged, isNot(contains('## 1.0.998')));
      },
    );

    test(
      'a curated ## <version> section for the same version never duplicates',
      () {
        // The repo file already carries a curated section for the version
        // being released (release_notes.sh prefers it): the stamper must
        // not prepend a generated copy AND keep the existing one.
        final fx = fixture(
          repoChangelog:
              '# Changelog\n\n## 1.0.999\n\n- curated notes\n\n'
              '## 1.0.998\n\n- old entry\n',
        );
        final r = stamp(fx, '1.0.999');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final staged = File('${fx.stage}/CHANGELOG.md').readAsStringSync();
        expect('## 1.0.999\n'.allMatches(staged).length, 1);
        expect(staged, contains('- curated notes'));
      },
    );

    test('staged pubspec missing the version line fails loud', () {
      final fx = fixture();
      File('${fx.stage}/pubspec.yaml').writeAsStringSync('name: fa\n');
      final r = stamp(fx, '1.0.999');
      expect(r.exitCode, 1, reason: 'a stage without a version line must fail');
      expect(
        '${r.stdout}${r.stderr}',
        contains('refusing to publish'),
        reason:
            'the loud fail must name the tag↔file invariant — a bare '
            'set -e death with no message is a silent failure',
      );
    });
  });
}

class _StampFixture {
  _StampFixture({required this.repo, required this.stage});

  final String repo;
  final String stage;
}
