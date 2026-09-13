// Issue #282 release-hygiene guards (AC1/AC2/AC3/AC4/AC5) + review of
// #294 hardening: static lint over the workflows/scripts plus behavioral
// tests of the release lifecycle scripts (notes generation, ownership-
// scoped draft guard, race-idempotent attach-or-create, daily sweeper)
// against fixture git repos and a stubbed `gh` (same style as
// store_automation_guard_test.dart). The stub enforces the GITHUB_TOKEN
// permissions declared in the workflows, so a missing grant fails tests
// instead of silently killing a production feature.
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
    if (!RegExp(r'gh\s+release\s+create\b').hasMatch(stripComment(lines[i]))) continue;
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
/// files in [dir] (releases.json, issues.tsv, runs.tsv, release-state.txt,
/// release-body.txt, view-seq.txt, create-fails).
String stubGh(String dir) {
  final bin = Directory('$dir/bin')..createSync(recursive: true);
  File('${bin.path}/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
cmd="\$1"

# Permission enforcement (review of #294): mirror the GITHUB_TOKEN scope
# each subcommand needs, so a workflow forgetting to grant one fails TESTS
# instead of dying silently in production (gh run list 403s without
# actions:read and the sweeper's || true hides the dead "creating run"
# feature). GH_STUB_PERMISSIONS is a space-separated granted-scope list;
# unset means full access.
granted="\${GH_STUB_PERMISSIONS:-*}"
need=""
case "\$cmd \$2" in
  "run list"|"run view"|"run watch"|"run rerun") need=actions ;;
  "issue "*|"label "*) need=issues ;;
  "release "*|"api"*) need=contents ;;
esac
if [ "\$granted" != "*" ] && [ -n "\$need" ] \\
   && ! printf '%s\\n' "\$granted" | grep -qw "\$need"; then
  echo "gh: HTTP 403: Resource not accessible by integration (stub: '\$cmd \$2' needs '\$need'; granted: '\$granted')" >&2
  exit 1
fi

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
      view)
        # Scripted view sequence for the attach-or-create tests: one word
        # per call (exists|missing), popped off the top.
        if [ -f "\$GH_STUB_DIR/view-seq.txt" ]; then
          w=\$(head -1 "\$GH_STUB_DIR/view-seq.txt")
          sed -i.bak '1d' "\$GH_STUB_DIR/view-seq.txt" && rm -f "\$GH_STUB_DIR/view-seq.txt.bak"
          [ "\$w" = "exists" ] && exit 0
          echo "release not found (stub)" >&2
          exit 1
        fi
        case " \$*" in
          *--json\\ body*) cat "\$GH_STUB_DIR/release-body.txt" 2>/dev/null || echo "" ;;
          *) cat "\$GH_STUB_DIR/release-state.txt" 2>/dev/null || echo "missing" ;;
        esac
        ;;
      create)
        if [ -f "\$GH_STUB_DIR/create-fails" ]; then
          echo "gh: HTTP 422: Reference already exists (stub: create lost the race)" >&2
          exit 1
        fi
        while [ \$# -gt 0 ]; do
          if [ "\$1" = "--notes-file" ]; then
            cp "\$2" "\$GH_STUB_DIR/last-create-notes.md" 2>/dev/null || true
          fi
          shift
        done
        ;;
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

/// Permission scopes the sweep-drafts job's GITHUB_TOKEN actually carries,
/// read live from daily-publish.yml — the stub enforces them, so a
/// missing grant (e.g. actions:read for `gh run list`) turns into a test
/// failure instead of a silently dead feature (review of #294).
String sweepPermissions() {
  final sweep = jobsOf('.github/workflows/daily-publish.yml')['sweep-drafts'] as YamlMap;
  final perms = sweep['permissions'];
  if (perms is! YamlMap || perms.isEmpty) return '';
  return perms.keys.map((k) => k.toString()).join(' ');
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
      'GH_STUB_PERMISSIONS': sweepPermissions(),
    },
  );
  return SweepRun(res.stdout.toString(), File('${dir.path}/log').readAsLinesSync(),
      File('${dir.path}/last-body.md').existsSync() ? File('${dir.path}/last-body.md').readAsStringSync() : null);
}

class GuardRun {
  GuardRun(this.exitCode, this.out, this.log);
  final int exitCode;
  final String out;
  final List<String> log;
}

class _AttachOut {
  _AttachOut(this.exitCode, this.out, this.log, this.createdNotes);
  final int exitCode;
  final String out;
  final List<String> log;
  final String? createdNotes; // release body the create would publish (stub capture)
}

/// Runs the draft guard as workflow job [job] of run [runId], with the
/// release state/body served by the stub.
GuardRun runGuard(String name, String state, {String? body, String runId = '111', String job = 'release-macos'}) {
  final dir = Directory('${_fixtureRoot.path}/guard-$name-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
  final bin = stubGh(dir.path);
  File('${dir.path}/release-state.txt').writeAsStringSync(state);
  if (body != null) File('${dir.path}/release-body.txt').writeAsStringSync(body);
  File('${dir.path}/log').writeAsStringSync('');
  final res = Process.runSync(
    'bash',
    ['scripts/release_draft_guard.sh', 'v1.2.3'],
    workingDirectory: Directory.current.path,
    environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GITHUB_RUN_ID': runId,
      'GITHUB_JOB': job,
    },
  );
  return GuardRun(res.exitCode, '${res.stdout}${res.stderr}',
      File('${dir.path}/log').readAsLinesSync());
}

void main() {
  // ── AC1 — draft lifecycle invariant (UT-lifecycle) ──────────────────────
  group('AC1 — every draft-capable create has a failure-path guard', () {
    for (final wf in ['.github/workflows/build-macos.yml', '.github/workflows/build-mobile.yml']) {
      test('$wf: asset-carrying create -> guard step in the same job', () {
        final jobs = jobsOf(wf);
        var checked = 0;
        bool draftCapable(dynamic job) {
          // A job is draft-capable when it creates a release with assets —
          // inline, or routed through release_attach_or_create.sh (whose
          // create uploads through a draft).
          if (job is! Map || !job.containsKey('steps')) return false;
          for (final step in (job['steps'] as YamlList)) {
            if (step is YamlMap && step.containsKey('run')) {
              final run = step['run'].toString();
              if (run.contains('release_attach_or_create.sh')) return true;
              if (extractCreates(run).any((c) => c.carriesAssets)) return true;
            }
          }
          return false;
        }

        jobs.forEach((jobId, job) {
          if (!draftCapable(job)) return;
          checked++;
          expect(
            draftGuardSteps(job),
            isNotEmpty,
            reason: '$wf job "$jobId" creates release with assets '
                '(gh uploads them through a draft) but has no always()/failure() '
                'draft-deletion guard step in the same job',
          );
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

    test('guard script: deletes own draft, spares published/missing releases', () {
      for (final state in ['true', 'false', 'missing']) {
        final run = runGuard('states-$state', state,
            body: '<!-- release-draft-owner: run/111/job/release-macos -->');
        if (state == 'true') {
          expect(run.log, contains('release delete v1.2.3 --repo OWNER/REPO --yes'),
              reason: 'own draft must be deleted');
        } else {
          expect(run.log.where((l) => l.contains('delete')), isEmpty,
              reason: 'state $state must not delete');
        }
      }
    });

    test('ownership: a failed leg cannot delete the sibling leg\'s mid-upload draft', () {
      // daily-publish runs the macOS and mobile legs concurrently on the
      // same derived tag: build-mobile run 999 is mid-upload (its draft is
      // stamped run/999/job/release-mobile) when build-macos run 111 fails
      // and its guard fires — it must refuse, not destroy the sibling.
      final run = runGuard('sibling', 'true',
          body: '<!-- release-draft-owner: run/999/job/release-mobile -->',
          runId: '111', job: 'release-macos');
      expect(run.log.where((l) => l.contains('release delete')), isEmpty,
          reason: 'a draft owned by another run+job must never be deleted');
      expect(run.exitCode, 0, reason: 'refusal is a warning, not a failure');
      expect(run.out, contains('refusing'),
          reason: 'the refusal must be visible in the job log');
      expect(run.out, contains('run/999/job/release-mobile'),
          reason: 'the warning must name the actual owner');
    });

    test('ownership: a cross-job draft within the same run is still refused', () {
      // build-macos run 111 has three draft-capable jobs; release-linux's
      // guard must not delete release-macos's draft from the same run.
      final run = runGuard('cross-job', 'true',
          body: '<!-- release-draft-owner: run/111/job/release-macos -->',
          runId: '111', job: 'release-linux');
      expect(run.log.where((l) => l.contains('release delete')), isEmpty);
      expect(run.out, contains('refusing'));
    });

    test('ownership: an unmarked draft (legacy/foreign) is left to the sweeper', () {
      final run = runGuard('unmarked', 'true', body: 'Some legacy draft body');
      expect(run.log.where((l) => l.contains('release delete')), isEmpty,
          reason: 'no marker, no proof of ownership — only the >24h sweeper may reclaim');
      expect(run.out, contains('refusing'));
    });

    test('ownership: marker match is exact, not prefix/substring', () {
      final run = runGuard('prefix', 'true',
          body: '<!-- release-draft-owner: run/1111/job/release-macos -->',
          runId: '111', job: 'release-macos');
      expect(run.log.where((l) => l.contains('release delete')), isEmpty,
          reason: 'run id 1111 must not be mistaken for 111');
    });
  });

  // ── E3 — idempotent attach-or-create (review of #294) ───────────────────
  group('release_attach_or_create.sh — race-idempotent create, ownership-stamped', () {
    _AttachOut runAttach(String name, List<String> viewSeq, {bool createFails = false}) {
      final dir = Directory(
          '${_fixtureRoot.path}/attach-$name-${DateTime.now().microsecondsSinceEpoch}')
        ..createSync(recursive: true);
      final bin = stubGh(dir.path);
      File('${dir.path}/view-seq.txt').writeAsStringSync('${viewSeq.join('\n')}\n');
      if (createFails) File('${dir.path}/create-fails').writeAsStringSync('');
      File('${dir.path}/a.zip').writeAsStringSync('asset-a');
      File('${dir.path}/b.zip').writeAsStringSync('asset-b');
      File('${dir.path}/release-notes.md').writeAsStringSync('curated notes\n');
      File('${dir.path}/log').writeAsStringSync('');
      final res = Process.runSync(
        'bash',
        [File('scripts/release_attach_or_create.sh').absolute.path, 'v1.2.3', 'a.zip', 'b.zip'],
        workingDirectory: dir.path,
        environment: {
          'PATH': '$bin:${Platform.environment['PATH']}',
          'GITHUB_REPOSITORY': 'OWNER/REPO',
          'GH_STUB_DIR': dir.path,
          'GH_LOG_FILE': '${dir.path}/log',
          'GITHUB_RUN_ID': '111',
          'GITHUB_JOB': 'release-macos',
        },
      );
      return _AttachOut(
        res.exitCode,
        '${res.stdout}${res.stderr}',
        File('${dir.path}/log').readAsLinesSync(),
        File('${dir.path}/last-create-notes.md').existsSync()
            ? File('${dir.path}/last-create-notes.md').readAsStringSync()
            : null,
      );
    }
    test('release exists → attach: upload every asset --clobber, re-assert --latest, no create', () {
      final run = runAttach('exists', ['exists']);
      expect(run.exitCode, 0);
      expect(run.log.where((l) => l.contains('release create')), isEmpty,
          reason: 'the release already exists — only attach');
      expect(run.log, contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'));
      expect(run.log, contains('release upload v1.2.3 b.zip --clobber --repo OWNER/REPO'));
      expect(run.log, contains('release edit v1.2.3 --latest --repo OWNER/REPO'));
    });

    test('missing → create: bare-tag title, --latest, assets ride the create, body carries the ownership marker', () {
      final run = runAttach('create', ['missing']);
      expect(run.exitCode, 0);
      final createLine = run.log.firstWhere((l) => l.contains('release create'));
      expect(createLine, contains('v1.2.3'));
      expect(createLine, contains('--title v1.2.3'));
      expect(createLine, contains('--latest'));
      expect(createLine, contains('a.zip'));
      expect(createLine, contains('b.zip'));
      expect(run.createdNotes, isNotNull);
      expect(run.createdNotes, contains('curated notes'),
          reason: 'the prepared notes must stay the body');
      expect(run.createdNotes, contains('release-draft-owner: run/111/job/release-macos'),
          reason: 'the draft body must stamp its owner so the guard can verify it');
    });

    test('E3 race: create loses to a concurrent winner → attach idempotently, exit 0', () {
      // The view said "missing", another job/run created the release
      // before our create landed. Old code failed here — and the failing
      // job's guard then deleted the WINNER's in-flight draft.
      final run = runAttach('race', ['missing', 'exists'], createFails: true);
      expect(run.exitCode, 0, reason: 'a lost create race must not fail the job');
      expect(run.log.where((l) => l.contains('release create')).length, 1,
          reason: 'the create was attempted exactly once');
      expect(run.log, contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
          reason: 'the loser must attach to the winner\'s release');
      expect(run.log, contains('release edit v1.2.3 --latest --repo OWNER/REPO'));
      expect(run.out.toLowerCase(), contains('race'));
    });

    test('create fails and nothing exists → loud failure (not a silent || true)', () {
      final run = runAttach('genuine-fail', ['missing', 'missing'], createFails: true);
      expect(run.exitCode, isNot(0));
      expect(run.log.where((l) => l.contains('release upload')), isEmpty,
          reason: 'nothing to attach to — no blind uploads');
    });

    test('workflows route draft-capable creates through the script (one race-safe path)', () {
      final script = File('scripts/release_attach_or_create.sh');
      expect(script.existsSync(), isTrue, reason: 'release_attach_or_create.sh must exist');
      for (final wf in ['.github/workflows/build-macos.yml', '.github/workflows/build-mobile.yml']) {
        expect(read(wf), contains('release_attach_or_create.sh'),
            reason: '$wf must route its asset-carrying create through the shared script');
        jobsOf(wf).forEach((jobId, job) {
          for (final c in jobCreates(job)) {
            expect(c.carriesAssets, isFalse,
                reason: '$wf job "$jobId": asset-carrying creates must live in '
                    'release_attach_or_create.sh (race-idempotent, marker-stamped)');
          }
        });
      }
      final creates = extractCreates(read('scripts/release_attach_or_create.sh'));
      expect(creates, hasLength(1));
      expect(creates.single.carriesAssets, isTrue);
      expect(creates.single.hasTitle, isTrue);
      expect(creates.single.title, creates.single.tag);
      expect(creates.single.text, contains('--latest'));
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
      final attachCreates = extractCreates(read('scripts/release_attach_or_create.sh'));
      expect(attachCreates, isNotEmpty);
      for (final c in attachCreates) {
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
        // Draft-capable creates live in release_attach_or_create.sh; the
        // workflow must route through it and not inline a parallel path.
        expect(read(wf), contains('release_attach_or_create.sh'));
        final script = read('scripts/release_attach_or_create.sh');
        expect(script, contains('--latest'),
            reason: 'release create must mark latest explicitly');
        expect(script, contains('gh release edit'),
            reason: 'attach-to-existing path must re-assert latest');
        expect(extractCreates(script).single.text, contains('--latest'));
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

    test('sweep-drafts grants actions:read — gh run list 403s without it (review of #294)', () {
      // The sweeper names each swept draft's creating run via `gh run list`;
      // without actions:read GitHub answers 403 and the script's || true
      // hides it, silently degrading every sweep issue to "no run on ref".
      // The stub enforces the YAML-declared scopes on every AC2 run above;
      // this pins the grant explicitly.
      final perms = jobsOf('.github/workflows/daily-publish.yml')['sweep-drafts']['permissions']
          as YamlMap;
      expect(perms.containsKey('actions'), isTrue,
          reason: 'sweep-drafts must grant actions:read for gh run list');
      expect(perms['actions'].toString(), 'read');
      expect(sweepPermissions().split(RegExp(r'\s+')), contains('actions'),
          reason: 'the stub-enforced scope list must include actions');
    });
  });
}

