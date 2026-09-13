// Issue #282 release-hygiene guards (AC1/AC2/AC3/AC4/AC5): static lint
// over the workflows/scripts plus behavioral tests of the new release
// lifecycle scripts (notes generation, draft guard, daily sweeper) against
// fixture git repos and a stubbed `gh` — same style as
// store_automation_guard_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

// ── workflow parsing helpers ───────────────────────────────────────────────

YamlMap jobsOf(String workflowPath) => loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// One `gh release create ...` command, continuation lines included.
class CreateBlock {
  CreateBlock(this.text, this.tag, this.title, this.positionalArgs);

  final String text; // full command text (all lines joined with \n)
  final String? tag; // first positional argument of the create line
  final String? title; // literal value after --title, if present
  final List<String> positionalArgs; // continuation args that are not flags

  bool get hasTitle => title != null;
  bool get carriesAssets => positionalArgs.isNotEmpty;
}

String? _after(String line, String flag) {
  final m = RegExp('$flag\\s+("[^"]*"|\\S+)').firstMatch(line);
  return m?.group(1)?.trim();
}

/// Extracts every `gh release create` command (with backslash continuations)
/// from a shell run-block string.
List<CreateBlock> extractCreates(String runText) {
  final lines = runText.split('\n');
  final blocks = <CreateBlock>[];

  String stripComment(String l) => l.contains('#') && !l.contains('"#') ? l.split('#').first : l;

  for (var i = 0; i < lines.length; i++) {
    if (!RegExp(r'gh\s+release\s+create\b').hasMatch(lines[i])) continue;
    final cmdLines = <String>[lines[i]];
    var j = i;
    while (j < lines.length - 1 && stripComment(cmdLines.last).trimRight().endsWith(r'\')) {
      j++;
      cmdLines.add(lines[j]);
    }
    i = j;

    // tag = first positional argument on the create line itself.
    final createLine = stripComment(cmdLines.first).trim();
    final tagMatch = RegExp(r'gh\s+release\s+create\s+("[^"]*"|\S+)').firstMatch(createLine);
    final tag = tagMatch?.group(1);

    var title = <String?>[]; // collect from any line
    final positional = <String>[];
    for (final raw in cmdLines) {
      final line = stripComment(raw).trimRight();
      final bare = line.replaceAll(r'\', '').trim();
      if (bare.isEmpty) continue;
      final t = _after(bare, '--title');
      if (t != null) title.add(t);
      final onFlagLine = bare.startsWith('--') || RegExp(r'gh\s+release\s+create').hasMatch(bare);
      if (!onFlagLine && !bare.startsWith('- ')) {
        positional.add(bare);
      }
    }
    blocks.add(CreateBlock(cmdLines.join('\n'), tag, title.isEmpty ? null : title.last, positional));
  }
  return blocks;
}

/// All create blocks of a parsed job (YamlMap or Map).
List<CreateBlock> jobCreates(dynamic job) {
  final blocks = <CreateBlock>[];
  if (job is! Map || !job.containsKey('steps')) return blocks;
  for (final step in (job['steps'] as YamlList)) {
    if (step is YamlMap && step.containsKey('run')) {
      blocks.addAll(extractCreates(step['run'].toString()));
    }
  }
  return blocks;
}

/// Steps of a job whose `if` is an always/failure guard and whose run body
/// deletes drafts (directly or via scripts/release_draft_guard.sh).
List<String> draftGuardSteps(dynamic job) {
  final guards = <String>[];
  if (job is! Map || !job.containsKey('steps')) return guards;
  for (final step in (job['steps'] as YamlList)) {
    if (step is! YamlMap || !step.containsKey('if') || !step.containsKey('run')) continue;
    final cond = step['if'].toString();
    final body = step['run'].toString();
    final isAlways = cond.contains('always()') || cond.contains('failure()');
    final deletesDraft = body.contains('release_draft_guard.sh') ||
        (body.contains('gh release delete') && body.contains('isDraft'));
    if (isAlways && deletesDraft) guards.add(step['name']?.toString() ?? body);
  }
  return guards;
}

const workflows = [
  '.github/workflows/build-macos.yml',
  '.github/workflows/build-mobile.yml',
  '.github/workflows/ci.yml',
];

// ── fixture helpers ────────────────────────────────────────────────────────

final _fixtureRoot = Directory.systemTemp.createTempSync('release-hygiene-');

/// A real git repo fixture: commits, tags, optional post-tag commits (the
/// "since previous tag" range), optional CHANGELOG.
String fixtureRepo(
  String name,
  List<String> commitSubjects,
  List<String> tags, [
  String? changelog,
  List<String> postTagSubjects = const [],
]) {
  final dir = Directory('${_fixtureRoot.path}/$name');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
  Process.runSync('git', ['config', 'user.email', 't@t'], workingDirectory: dir.path);
  Process.runSync('git', ['config', 'user.name', 't'], workingDirectory: dir.path);
  if (changelog != null) File('${dir.path}/CHANGELOG.md').writeAsStringSync(changelog);
  var i = 0;
  for (final group in [commitSubjects, postTagSubjects]) {
    for (final subject in group) {
      File('${dir.path}/f$i.txt').writeAsStringSync('$i');
      Process.runSync('git', ['add', '.'], workingDirectory: dir.path);
      Process.runSync('git', ['commit', '-q', '-m', subject], workingDirectory: dir.path);
      i++;
    }
    for (final tag in tags) {
      Process.runSync('git', ['tag', tag], workingDirectory: dir.path);
    }
    tags = const [];
  }
  return dir.path;
}

/// Installs a stub `gh` that logs every invocation and answers from canned
/// files in [dir] (releases.json, issues.tsv, runs.tsv, release-state.txt).
String stubGh(String dir) {
  final bin = Directory('$dir/bin')..createSync(recursive: true);
  File('${bin.path}/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
cmd="\$1"
case "\$cmd" in
  api)
    case "\$2 \$3" in
      "-X DELETE"*) : ;;
      *) cat "\$GH_STUB_DIR/releases.json" ;;
    esac
    ;;
  label) : ;;
  run) [ "\$2" = "list" ] && cat "\$GH_STUB_DIR/runs.tsv" 2>/dev/null || true ;;
  issue)
    if [ "\$2" = "list" ]; then cat "\$GH_STUB_DIR/issues.tsv" 2>/dev/null || true; exit 0; fi
    want_url=""
    [ "\$2" = "create" ] && want_url=1
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--body-file" ]; then
        cp "\$2" "\$GH_STUB_DIR/last-body.md" 2>/dev/null || true
      fi
      shift
    done
    [ -n "\$want_url" ] && echo "https://github.com/OWNER/REPO/issues/13"
    ;;
  release)
    case "\$2" in
      view) cat "\$GH_STUB_DIR/release-state.txt" 2>/dev/null || echo "missing" ;;
      *) : ;;
    esac
    ;;
esac
exit 0
''');
  Process.runSync('chmod', ['+x', '${bin.path}/gh']);
  return bin.path;
}

class SweepRun {
  SweepRun(this.stdoutText, this.log, this.body);
  final String stdoutText;
  final List<String> log;
  final String? body; // issue body captured by the stub, when one was filed
}

SweepRun runSweeper(String stubDir, Map<String, String> stubFiles) {
  final dir = Directory('${_fixtureRoot.path}/sweep-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
  final stubBin = stubGh(dir.path);
  for (final e in stubFiles.entries) {
    File('${dir.path}/${e.key}').writeAsStringSync(e.value);
  }
  File('${dir.path}/log').writeAsStringSync('');
  final res = Process.runSync(
    'bash',
    ['scripts/sweep_stale_drafts.sh'],
    workingDirectory: Directory.current.path,
    environment: {
      'PATH': '$stubBin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GITHUB_STEP_SUMMARY': '${dir.path}/summary.md',
    },
  );
  return SweepRun(res.stdout.toString(), File('${dir.path}/log').readAsLinesSync(),
      File('${dir.path}/last-body.md').existsSync() ? File('${dir.path}/last-body.md').readAsStringSync() : null);
}

void main() {
  // ── AC1 — draft lifecycle invariant (UT-lifecycle) ──────────────────────
  group('AC1 — every draft-capable create has a failure-path guard', () {
    for (final wf in ['.github/workflows/build-macos.yml', '.github/workflows/build-mobile.yml']) {
      test('$wf: asset-carrying create -> guard step in the same job', () {
        final jobs = jobsOf(wf);
        var checked = 0;
        jobs.forEach((jobId, job) {
          for (final create in jobCreates(job)) {
            if (!create.carriesAssets) continue;
            checked++;
            expect(
              draftGuardSteps(job),
              isNotEmpty,
              reason: '$wf job "$jobId" creates release with assets '
                  '(gh uploads them through a draft) but has no always()/failure() '
                  'draft-deletion guard step in the same job',
            );
          }
        });
        expect(checked, greaterThan(0), reason: 'lint must find the known asset-carrying creates');
      });
    }

    test('lint is real: a fixture job that creates a draft and dies is flagged', () {
      final fixture = loadYaml(r'''
jobs:
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: create
        run: |
          gh release create "$RELEASE_TAG" \
            --title "$RELEASE_TAG" \
            fa-binary.zip
      - name: upload
        run: exit 1
  good:
    runs-on: ubuntu-latest
    steps:
      - name: create
        run: |
          gh release create "$RELEASE_TAG" \
            --title "$RELEASE_TAG" \
            fa-binary.zip
      - name: Draft lifecycle guard
        if: always() && job.status != 'success'
        run: bash scripts/release_draft_guard.sh "$RELEASE_TAG"
''');
      expect(draftGuardSteps(fixture['jobs']['bad']), isEmpty);
      expect(jobCreates(fixture['jobs']['bad']).single.carriesAssets, isTrue);
      expect(draftGuardSteps(fixture['jobs']['good']), isNotEmpty);
    });

    test('AC6: ci.yml tag-publish path stays untouched (its creates are not draft-capable)', () {
      final jobs = jobsOf('.github/workflows/ci.yml');
      var creates = 0;
      jobs.forEach((_, job) => creates += jobCreates(job).length);
      expect(creates, greaterThan(0), reason: 'ci.yml tag release create must still exist');
      jobs.forEach((_, job) {
        for (final c in jobCreates(job)) {
          expect(c.carriesAssets, isFalse, reason: 'ci.yml create must stay asset-free (AC6)');
        }
      });
    });

    test('guard script: deletes a draft, spares published/missing releases', () {
      final dir = Directory('${_fixtureRoot.path}/guard')..createSync(recursive: true);
      for (final state in ['true', 'false', 'missing']) {
        final bin = stubGh(dir.path);
        File('${dir.path}/release-state.txt').writeAsStringSync(state);
        File('${dir.path}/log').writeAsStringSync('');
        Process.runSync(
          'bash',
          ['scripts/release_draft_guard.sh', 'v1.2.3'],
          workingDirectory: Directory.current.path,
          environment: {
            'PATH': '$bin:${Platform.environment['PATH']}',
            'GITHUB_REPOSITORY': 'OWNER/REPO',
            'GH_STUB_DIR': dir.path,
            'GH_LOG_FILE': '${dir.path}/log',
          },
        );
        final log = File('${dir.path}/log').readAsLinesSync();
        if (state == 'true') {
          expect(log, contains('release delete v1.2.3 --repo OWNER/REPO --yes'),
              reason: 'draft must be deleted');
        } else {
          expect(log.where((l) => l.contains('delete')), isEmpty,
              reason: 'state $state must not delete');
        }
      }
    });
  });

  // ── AC3 — one naming scheme: bare vX.Y.Z (UT-naming) ────────────────────
  group('AC3 — bare vX.Y.Z titles everywhere', () {
    test('no "Fa " title prefix survives in any release-creating path', () {
      final haystacks = [...workflows.map(read), read('scripts/auto_release.sh')];
      for (final text in haystacks) {
        expect(text, isNot(contains('--title "Fa ')),
            reason: 'release titles must be bare vX.Y.Z, not "Fa vX.Y.Z"');
      }
    });

    test('every gh release create is titled and the title equals the tag', () {
      for (final wf in workflows) {
        jobsOf(wf).forEach((jobId, job) {
          for (final c in jobCreates(job)) {
            expect(c.hasTitle, isTrue,
                reason: '$wf job "$jobId": untitled release create is forbidden');
            expect(c.title, c.tag,
                reason: '$wf job "$jobId": --title must equal the bare tag (${c.tag})');
          }
        });
      }
      final scriptCreates = extractCreates(read('scripts/auto_release.sh'));
      expect(scriptCreates, isNotEmpty);
      for (final c in scriptCreates) {
        expect(c.title, c.tag);
      }
    });

    test('lint is real: fixture with "Fa " prefix / missing title is flagged', () {
      final bad = extractCreates(r'''
gh release create "$RELEASE_TAG" \
  --title "Fa $RELEASE_TAG" \
  --generate-notes
gh release create "v9.9.9" \
  --generate-notes
''');
      expect(bad.first.title, isNot(bad.first.tag));
      expect(bad.last.hasTitle, isFalse);
    });
  });

  // ── AC5 — generated release notes (UT-notes) ────────────────────────────
  group('AC5 — release_notes.sh', () {
    String notes(String cwd, List<String> args) {
      final r = Process.runSync(
        'bash',
        [File('scripts/release_notes.sh').absolute.path, ...args],
        workingDirectory: cwd,
      );
      return r.stdout.toString();
    }

    test('CHANGELOG section for the version wins', () {
      final repo = fixtureRepo('notes-changelog', ['feat: real work'], ['v1.2.2'], '''
# Changelog

## 1.2.3

- Curated note alpha
- Curated note beta

## 1.2.2

- Older
''');
      final out = notes(repo, ['1.2.3']);
      expect(out, contains('Curated note alpha'));
      expect(out, contains('Curated note beta'));
      expect(out, isNot(contains('Older')));
      expect(out, isNot(contains('feat: real work')));
    });

    test('fallback: conventional commits since the previous tag, grouped', () {
      final repo = fixtureRepo(
        'notes-group',
        ['chore: seed'],
        ['v2.0.0'],
        null,
        ['feat(cli): shiny new thing', 'fix: crash on start', 'chore: deps bump', 'docs: readme'],
      );
      final out = notes(repo, ['2.0.1']);
      expect(out, contains('Features'));
      expect(out, contains('shiny new thing'));
      expect(out, contains('Fixes'));
      expect(out, contains('crash on start'));
      expect(out, contains('Maintenance'));
      expect(out, contains('deps bump'));
      expect(out, contains('readme'));
    });

    test('zero commits since previous tag -> clean "no changes" body (E5)', () {
      final repo = fixtureRepo('notes-empty', ['feat: only old work'], ['v3.0.0']);
      final out = notes(repo, ['3.0.1']);
      expect(out.toLowerCase(), contains('no changes'));
      expect(out.trim(), isNot(''));
    });

    test('E4: 200 commits -> capped at 50 with an "and N more" line', () {
      final repo = fixtureRepo(
        'notes-cap',
        ['chore: seed'],
        ['v4.0.0'],
        null,
        [for (var i = 1; i <= 200; i++) 'feat: change $i'],
      );
      final out = notes(repo, ['4.0.1']);
      final bullets = RegExp(r'^- ', multiLine: true).allMatches(out).length;
      expect(bullets, lessThanOrEqualTo(50));
      expect(out, contains('and 150 more'));
      expect(out, contains('change 200'), reason: 'newest commits stay, oldest drop');
    });
  });

  // ── AC2 — daily draft sweeper (IT-sweep) ────────────────────────────────
  group('AC2 — sweep_stale_drafts.sh', () {
    final oldDate = '2020-01-01T00:00:00Z';
    String releasesJson(List<Map<String, Object>> drafts) => jsonEncode(drafts
        .map((d) => {
              'tag_name': d['tag'],
              'id': d['id'],
              'draft': true,
              'created_at': d['created'],
              'author': {'login': d['author'], 'type': d['type']},
            })
        .toList());

    test('old bot draft deleted, fresh untouched, human kept; issue filed naming the run', () {
      final freshDate = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String()
          .substring(0, 19);
      final run = runSweeper('one', {
        'releases.json': releasesJson([
          {'tag': 'v0.1.190', 'id': 111, 'created': oldDate, 'author': 'github-actions[bot]', 'type': 'Bot'},
          {'tag': 'v9.9.9', 'id': 222, 'created': '${freshDate}Z', 'author': 'github-actions[bot]', 'type': 'Bot'},
          {'tag': 'v0.2.0', 'id': 333, 'created': oldDate, 'author': 'somehuman', 'type': 'User'},
        ]),
        'issues.tsv': '',
        'runs.tsv': 'https://github.com/OWNER/REPO/actions/runs/9999\n',
      });
      expect(run.log, contains('api -X DELETE repos/OWNER/REPO/releases/111'),
          reason: 'stale bot draft must be deleted by release id');
      expect(run.log, isNot(contains('releases/222')),
          reason: 'fresh (<24h) draft must be untouched');
      expect(run.log, isNot(contains('releases/333')),
          reason: 'human draft must never be deleted (E1)');
      expect(run.log, anyElement(contains('issue create')), reason: 'dedup issue must be filed');
      expect(run.body, isNotNull, reason: 'an issue body must have been filed');
      expect(run.body, contains('v0.1.190'),
          reason: 'deleted draft must be named in the issue');
      expect(run.body, contains('actions/runs/9999'),
          reason: 'the creating run must be named in the issue');
      expect(run.body, contains('v0.2.0'), reason: 'human draft must be listed in the issue');
      expect(run.stdoutText, contains('v0.1.190'),
          reason: 'deleted draft must be named in the report');
    });

    test('idempotent re-run: comments on the open issue instead of duplicating', () {
      final run = runSweeper('two', {
        'releases.json': releasesJson([
          {'tag': 'v0.1.190', 'id': 111, 'created': oldDate, 'author': 'github-actions[bot]', 'type': 'Bot'},
        ]),
        'issues.tsv': '12\t[daily-publish] stale release drafts swept\n',
        'runs.tsv': '',
      });
      final creates = run.log.where((l) => l.contains('issue create')).length;
      final comments = run.log.where((l) => l.contains('issue comment')).length;
      expect(creates, 0, reason: 'open issue exists — no duplicate may be filed');
      expect(comments, 1, reason: 'the existing issue gets a fresh comment');
      expect(run.log, contains('api -X DELETE repos/OWNER/REPO/releases/111'));
    });

    test('clean sweep auto-closes the open issue (self-closing convention)', () {
      final run = runSweeper('three', {
        'releases.json': '[]',
        'issues.tsv': '12\t[daily-publish] stale release drafts swept\n',
        'runs.tsv': '',
      });
      expect(run.log, anyElement(contains('issue close')));
      expect(run.log.where((l) => l.contains('-X DELETE')), isEmpty);
      expect(run.log.where((l) => l.contains('issue create')), isEmpty);
    });
  });

  // ── AC4 — truthful Latest (IT-latest) ───────────────────────────────────
  group('AC4 — latest is explicit on publishes, impossible for drafts', () {
    for (final wf in ['.github/workflows/build-macos.yml', '.github/workflows/build-mobile.yml']) {
      test('$wf: publish paths carry --latest (create) or edit --latest (attach to existing)', () {
        final text = read(wf);
        expect(text, contains('--latest'), reason: 'release create must mark latest explicitly');
        expect(text, contains('gh release edit'), reason: 'attach-to-existing path must re-assert latest');
        jobsOf(wf).forEach((jobId, job) {
          for (final c in jobCreates(job)) {
            if (c.carriesAssets) {
              expect(c.text, contains('--latest'),
                  reason: '$wf job "$jobId": asset-carrying create must pass --latest');
            }
          }
        });
      });
    }

    test('guards and sweeper never touch the latest badge', () {
      for (final script in ['scripts/release_draft_guard.sh', 'scripts/sweep_stale_drafts.sh']) {
        expect(read(script), isNot(contains('--latest')));
      }
    });

    test('auto_release.sh marks the new release latest explicitly', () {
      final creates = extractCreates(read('scripts/auto_release.sh'));
      expect(creates, isNotEmpty);
      for (final c in creates) {
        expect(c.text, contains('--latest'));
      }
    });
  });

  // ── AC6 — regression: no "Release v" bodies, atomic flow intact ─────────
  group('AC6 — regression', () {
    test('no "Release vX" filler bodies remain', () {
      final haystacks = [...workflows.map(read), read('scripts/auto_release.sh')];
      for (final text in haystacks) {
        expect(text, isNot(contains('--notes "Release v')));
      }
    });

    test('auto_release.sh atomic push+tag flow unchanged', () {
      final text = read('scripts/auto_release.sh');
      expect(text, contains('git push --atomic origin main --follow-tags'));
      expect(text, contains(r'git tag -a "v$next"'));
    });

    test('daily-publish.yml carries the sweeper job, ungated by leg results', () {
      final jobs = jobsOf('.github/workflows/daily-publish.yml');
      expect(jobs.keys, contains('sweep-drafts'));
      final sweep = jobs['sweep-drafts'] as YamlMap;
      expect(sweep['if'].toString(), contains('always()'),
          reason: 'hygiene must run even when legs skip');
      expect((sweep['permissions'] as YamlMap).containsKey('contents'), isTrue);
      expect(sweep.toString(), contains('sweep_stale_drafts.sh'));
    });
  });
}

