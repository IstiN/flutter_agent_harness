// gh-2463 — changelog/ entries generator (`scripts/gen_changelog.dart`).
//
// Per-change entry files replace the single curated CHANGELOG.md as the
// merge surface: each PR adds `changelog/entries/<issue-or-pr>-<slug>.md`
// (YAML frontmatter `type`/`scope`/`issue` + 1–3 user-facing bullet lines)
// and NEVER edits CHANGELOG.md — zero conflicts by construction. The
// generator aggregates the pending entries into the release-notes body
// (byte-parity shape with the old curated `## Unreleased` body: flat
// bullets, deterministic order), regenerates the thin CHANGELOG.md index,
// and validates the entry set for CI.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

final _tmpRoot = Directory.systemTemp.createTempSync('changelog-gen-');

late String _script;

ProcessResult _gen(List<String> args, String cwd) => Process.runSync(
  'dart',
  [_script, ...args],
  workingDirectory: cwd,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

String _fixture(String name) {
  final dir = '${_tmpRoot.path}/$name';
  Directory('$dir/changelog/entries').createSync(recursive: true);
  return dir;
}

void _entry(String dir, String name, String body) {
  File('$dir/changelog/entries/$name').writeAsStringSync(body);
}

const _fm = '---\ntype: %T\nscope: %S\nissue: %I\n---\n';

String _entryBody(String type, String scope, String issue, String bullet) =>
  '${_fm.replaceFirst('%T', type).replaceFirst('%S', scope).replaceFirst('%I', issue)}'
  '\n$bullet\n';

void main() {
  setUpAll(() {
    _script = File('scripts/gen_changelog.dart').absolute.path;
  });

  group('flat aggregate (release-notes body, parity shape)', () {
    test('bullets in (numeric-prefix, filename) order, nothing else', () {
      final dir = _fixture('flat-order');
      // Added out of order on purpose: numeric prefixes drive the order,
      // not file creation time.
      _entry(dir, '42-second-fix.md', _entryBody('fix', 'cli', '42', '- fix B'));
      _entry(dir, '7-first-feat.md', _entryBody('feat', 'ui', '7', '- feat A'));
      _entry(dir, '100-third-docs.md', _entryBody('docs', '', '', '- docs C'));
      final r = _gen(['--stdout'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, '- feat A\n- fix B\n- docs C\n');
    });

    test('multi-line bullet bodies ride verbatim', () {
      final dir = _fixture('verbatim');
      _entry(
        dir,
        '9-multi.md',
        '---\ntype: fix\nissue: 9\n---\n\n- wrapped bullet line one\n  '
        'continuation stays glued to the bullet\n',
      );
      final r = _gen(['--stdout'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(
        r.stdout,
        '- wrapped bullet line one\n  continuation stays glued to the bullet\n',
      );
    });

    test('empty entries dir → empty stdout, exit 0', () {
      final dir = _fixture('empty');
      final r = _gen(['--stdout'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, '');
    });
  });

  group('issue dedupe (rework commits)', () {
    test('same issue twice → last-sorted file wins, loser reported', () {
      final dir = _fixture('dedupe');
      _entry(dir, '5-initial.md', _entryBody('fix', 'x', '5', '- initial text'));
      _entry(dir, '5-rework.md', _entryBody('fix', 'x', '5', '- reworked text'));
      final r = _gen(['--stdout'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, '- reworked text\n');
      expect(r.stderr, contains('5-initial.md'));
      expect(r.stderr, contains('issue 5'));
    });

    test('entries WITHOUT an issue are never deduped', () {
      final dir = _fixture('dedupe-no-issue');
      _entry(dir, '1-a.md', '---\ntype: fix\n---\n\n- bullet A\n');
      _entry(dir, '2-b.md', '---\ntype: fix\n---\n\n- bullet B\n');
      final r = _gen(['--stdout'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, '- bullet A\n- bullet B\n');
    });
  });

  group('--group-by-type', () {
    test('groups under fixed headings, unknown type lands in Other', () {
      final dir = _fixture('grouped');
      _entry(dir, '1-c.md', _entryBody('ci', '', '1', '- ci bullet'));
      _entry(dir, '2-a.md', _entryBody('feat', '', '2', '- feat bullet'));
      _entry(dir, '3-b.md', _entryBody('fix', '', '3', '- fix bullet'));
      // 'other' is the documented fallback; truly unknown types are a
      // --validate ERROR (pinned in the validate group below).
      _entry(dir, '4-d.md', '---\ntype: other\n---\n\n- odd bullet\n');
      final r = _gen(['--group-by-type'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(
        r.stdout,
        '### Features\n\n- feat bullet\n\n'
        '### Fixes\n\n- fix bullet\n\n'
        '### CI\n\n- ci bullet\n\n'
        '### Other\n\n- odd bullet\n',
      );
    });
  });

  group('--validate', () {
    test('a well-formed set passes (exit 0)', () {
      final dir = _fixture('validate-ok');
      _entry(dir, '11-ok.md', _entryBody('perf', 'redact', '11', '- fast path'));
      expect(_gen(['--validate'], dir).exitCode, 0);
    });

    test('missing type fails with ::error::', () {
      final dir = _fixture('validate-no-type');
      _entry(dir, '12-x.md', '---\nscope: cli\n---\n\n- bullet\n');
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
      expect(r.stdout, contains('12-x.md'));
    });

    test('unknown type fails naming the allowed set', () {
      final dir = _fixture('validate-bad-type');
      _entry(dir, '13-x.md', '---\ntype: sparkle\n---\n\n- bullet\n');
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
      expect(r.stdout, contains('sparkle'));
    });

    test('non-numeric filename prefix fails (the sort/dedupe key)', () {
      final dir = _fixture('validate-bad-name');
      _entry(dir, 'not-an-issue-slug.md', '---\ntype: fix\n---\n\n- bullet\n');
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
      expect(r.stdout, contains('not-an-issue-slug.md'));
    });

    test('empty body fails', () {
      final dir = _fixture('validate-empty-body');
      _entry(dir, '14-x.md', '---\ntype: fix\nissue: 14\n---\n\n\n');
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
    });

    test('missing frontmatter block fails', () {
      final dir = _fixture('validate-no-fm');
      _entry(dir, '15-x.md', '- just a bullet, no frontmatter\n');
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
    });

    test('more than 3 bullets warns but passes', () {
      final dir = _fixture('validate-long');
      _entry(
        dir,
        '16-x.md',
        '---\ntype: fix\n---\n\n- one\n- two\n- three\n- four\n',
      );
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('::warning::'));
    });

    test('stray non-md file in entries/ is ignored, not an error', () {
      final dir = _fixture('validate-stray');
      _entry(dir, '17-x.md', '---\ntype: fix\n---\n\n- bullet\n');
      File('$dir/changelog/entries/.gitkeep')
          .writeAsStringSync('');
      expect(_gen(['--validate'], dir).exitCode, 0);
    });

    // gh-2463 review thread 3 (IMPORTANT): a file whose frontmatter close
    // is the LAST line (no trailing newline) used to make
    // `text.indexOf('\n', close + 1)` return -1 → substring(0) took the
    // WHOLE file as the "body" → the raw frontmatter rode --validate
    // (exit 0) and the release-notes aggregate verbatim.
    test('frontmatter close at EOF (no trailing newline) fails loudly', () {
      final dir = _fixture('validate-fm-close-eof');
      _entry(dir, '18-x.md', '---\ntype: fix\nissue: 18\n---');
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
      expect(r.stdout, contains('18-x.md'));
      expect(r.stdout, contains('no body after the frontmatter close'));
      // The aggregate modes must fail loudly too — never publish the
      // frontmatter as the notes body.
      final agg = _gen(['--stdout'], dir);
      expect(agg.exitCode, 1);
      expect(agg.stdout, isNot(contains('type: fix')));
    });

    // gh-2463 review thread 4 (SUGGESTION): the notes body is pinned as
    // flat `- ` bullets (the AC2 parity shape) — a prose body with zero
    // bullet lines used to pass --validate and land bullet-less in the
    // release notes. (4 bullets → warn-but-pass is pinned above at
    // 'more than 3 bullets warns but passes'.)
    test('bullet-less prose body fails (notes shape is 1–3 `- ` lines)', () {
      final dir = _fixture('validate-no-bullets');
      _entry(
        dir,
        '19-x.md',
        '---\ntype: fix\nissue: 19\n---\n\n'
        'Just a prose paragraph with no bullet lines at all.\n',
      );
      final r = _gen(['--validate'], dir);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('::error::'));
      expect(r.stdout, contains('19-x.md'));
      expect(r.stdout, contains('body must be 1–3 `- ` bullet lines'));
    });
  });

  group('--write-changelog (thin generated index)', () {
    test('preamble + generated Unreleased + sorted archive index', () {
      final dir = _fixture('write');
      Directory('$dir/changelog/archive').createSync();
      _entry(dir, '21-f.md', _entryBody('feat', 'release', '21', '- new flow'));
      for (final v in ['1.0.506', '1.0.551', 'legacy-unreleased']) {
        File('$dir/changelog/archive/$v.md')
            .writeAsStringSync('## $v\n\n- old\n');
      }
      final r = _gen(['--write-changelog'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      final out = File('$dir/CHANGELOG.md').readAsStringSync();
      // Generated marker so nobody hand-edits it.
      expect(out, contains('gen_changelog.dart --write-changelog'));
      expect(out, contains('DO NOT HAND-EDIT'));
      // The pending aggregate rides under ## Unreleased.
      expect(out, contains('## Unreleased'));
      expect(out, contains('- new flow'));
      // Archive index: version files newest-first, non-version last.
      final i551 = out.indexOf('changelog/archive/1.0.551.md');
      final i506 = out.indexOf('changelog/archive/1.0.506.md');
      final iLegacy = out.indexOf('changelog/archive/legacy-unreleased.md');
      expect(i551, greaterThan(0));
      expect(i506, greaterThan(i551), reason: '1.0.551 before 1.0.506');
      expect(iLegacy, greaterThan(i506), reason: 'non-version files last');
    });

    test('deterministic bytes across runs', () {
      final dir = _fixture('write-deterministic');
      Directory('$dir/changelog/archive').createSync();
      _entry(dir, '22-f.md', _entryBody('feat', '', '22', '- x'));
      File('$dir/changelog/archive/1.0.9.md').writeAsStringSync('# a\n');
      expect(_gen(['--write-changelog'], dir).exitCode, 0);
      final first = File('$dir/CHANGELOG.md').readAsStringSync();
      expect(_gen(['--write-changelog'], dir).exitCode, 0);
      expect(File('$dir/CHANGELOG.md').readAsStringSync(), first);
    });

    test('no pending entries → explicit placeholder, never an empty section', () {
      final dir = _fixture('write-empty');
      Directory('$dir/changelog/archive').createSync();
      expect(_gen(['--write-changelog'], dir).exitCode, 0);
      final out = File('$dir/CHANGELOG.md').readAsStringSync();
      expect(out, contains('## Unreleased'));
      expect(out, contains('changelog/entries/'));
    });
  });

  // gh-2463 AC1: two PRs touching the changelog in parallel must merge with
  // NO conflict — structurally, because each PR adds ITS OWN file and the
  // generator only READS the entries dir (it never writes into it), so the
  // aggregated view is the union of both PRs' files.
  group('AC1 — parallel PRs conflict-free by construction', () {
    test('two PRs’ files aggregate together; generator writes nothing into '
        'the shared tree', () {
      final dir = _fixture('ac1-parallel');
      // PR A's entry, already on main.
      _entry(dir, '31-a.md', _entryBody('feat', 'x', '31', '- PR A bullet'));
      // PR B's entry, landing in parallel.
      _entry(dir, '32-b.md', _entryBody('fix', 'y', '32', '- PR B bullet'));
      final before = _snapshot(dir);
      final r = _gen(['--stdout'], dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('- PR A bullet'));
      expect(r.stdout, contains('- PR B bullet'));
      // The only mutation a regeneration may make is CHANGELOG.md itself
      // (--write-changelog); plain aggregation is read-only.
      expect(_snapshot(dir), before);
    });
  });
}

Map<String, String> _snapshot(String dir) {
  final out = <String, String>{};
  for (final e in Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()) {
    out[e.path] = e.readAsStringSync();
  }
  return out;
}
