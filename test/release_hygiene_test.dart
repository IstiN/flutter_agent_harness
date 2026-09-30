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

/// Every `uses:` ref in the YAML AST at any depth (workflow job steps,
/// composite action `runs.steps`), grouped by action name → set of pins.
/// Unlike a raw grep over the file text this never matches `@v4` fixture
/// strings embedded in `run:` bodies (the supply-chain selftest writes
/// those on purpose).
void collectUses(dynamic node, Map<String, Set<String>> byAction) {
  if (node is YamlMap) {
    final uses = node['uses'];
    if (uses is String) {
      final ref = uses.trim();
      final at = ref.lastIndexOf('@');
      if (!ref.startsWith('./') && !ref.startsWith('docker://') && at > 0) {
        byAction.putIfAbsent(ref.substring(0, at), () => {}).add(ref.substring(at + 1));
      }
    }
    for (final key in node.keys) {
      collectUses(node[key], byAction);
    }
  } else if (node is YamlList) {
    for (final item in node) {
      collectUses(item, byAction);
    }
  }
}

/// All third-party `uses:` pins across the workflows and composite actions.
Map<String, Set<String>> usesByAction() {
  final byAction = <String, Set<String>>{};
  final files = <String>[
    ...Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
        .map((f) => f.path),
    ...Directory('.github/actions')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('action.yml') || f.path.endsWith('action.yaml'))
        .map((f) => f.path),
  ];
  for (final f in files) {
    collectUses(loadYaml(read(f)), byAction);
  }
  return byAction;
}

/// Shell glob (`*` wildcards) → anchored regexp.
RegExp globToRegExp(String glob) =>
    RegExp('^${glob.split('*').map(RegExp.escape).join('.*')}\$');

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
  label)
    case "\$2" in
      # gh-1134: view succeeds only when the fixture label exists; create
      # self-heals it (unless label-create-fails is planted) — mirrors real
      # GitHub: create is idempotent-failure when the label already exists.
      view) [ -f "\$GH_STUB_DIR/label-exists" ] && exit 0 || exit 1 ;;
      create)
        if [ -f "\$GH_STUB_DIR/label-create-fails" ]; then
          echo "gh: label create failed (stub)" >&2
          exit 1
        fi
        touch "\$GH_STUB_DIR/label-exists" ;;
      *) : ;;
    esac
    ;;
  pr)
    case "\$2" in
      list)
        if printf '%s' "\$*" | grep -q -- '--state closed'; then echo 0
        elif printf '%s' "\$*" | grep -q 'headRefName'; then echo 0
        else cat "\$GH_STUB_DIR/open-pr.txt" 2>/dev/null || true; fi ;;
      *) : ;;
    esac
    ;;
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

class AutoRun {
  AutoRun(this.exitCode, this.output, this.log);
  final int exitCode;
  final String output;
  final List<String> log;
}

/// Full behavioral sandbox for scripts/auto_release.sh (gh-1134): a bare
/// origin whose main carries pubspec 0.1.495 tagged v0.1.495 three hours ago
/// (past the 2h coalesce window) plus one pending commit, a seed clone the
/// script runs in, and the stubbed gh. [staleBranch] pushes an older tree to
/// chore/release-v0.1.496 so the refresh path runs instead of create;
/// [openPr] is the PR number the stub reports for that branch; [labelExists]
/// pre-seeds the chore:pin label; [labelCreateWorks]=false makes even
/// `gh label create` fail (E1's hard case).
AutoRun runAutoRelease(
  String name, {
  bool labelExists = true,
  bool labelCreateWorks = true,
  bool staleBranch = false,
  String? openPr,
}) {
  final root = Directory(
          '${_fixtureRoot.path}/auto-$name-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
  final origin = '${root.path}/origin.git';
  final seed = '${root.path}/seed';
  final bin = stubGh(root.path);
  // auto_release.sh uses GNU `sed -i` (CI-authored, ubuntu); BSD hosts need
  // the empty-suffix form — transparent shim, real sed either way.
  File('$bin/sed').writeAsStringSync('''
#!/usr/bin/env bash
if [ "\${1:-}" = "-i" ]; then shift
  if /usr/bin/sed --version >/dev/null 2>&1; then exec /usr/bin/sed -i "\$@"
  else exec /usr/bin/sed -i '' "\$@"; fi
fi
exec /usr/bin/sed "\$@"
''');
  Process.runSync('chmod', ['+x', '$bin/sed']);

  void git(List<String> args, {String? cwd, Map<String, String> env = const {}}) {
    final r = Process.runSync('git', args,
        workingDirectory: cwd ?? seed,
        environment: env,
        includeParentEnvironment: true);
    expect(r.exitCode, 0, reason: 'fixture git $args failed: ${r.stderr}');
  }

  Directory(origin).createSync();
  git(['init', '-q', '--bare', '-b', 'main', origin], cwd: root.path);
  git(['clone', '-q', origin, seed], cwd: root.path);
  git(['config', 'user.email', 't@t']);
  git(['config', 'user.name', 't']);
  Directory('$seed/flutter_app').createSync();
  File('$seed/pubspec.yaml').writeAsStringSync('version: 0.1.495\n');
  File('$seed/flutter_app/pubspec.yaml').writeAsStringSync('version: 0.1.495+1\n');
  File('$seed/CHANGELOG.md').writeAsStringSync('# Changelog\n\n## Unreleased\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'seed'],
      env: {
        'GIT_COMMITTER_DATE':
            (DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000)
                .toString()
      });
  git(['tag', 'v0.1.495']);
  File('$seed/README.md').writeAsStringSync('pending\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'pending work']);
  git(['push', '-q', 'origin', 'main']);
  if (staleBranch) {
    final c1 = Process.runSync('git', ['rev-list', '--max-parents=0', 'HEAD'],
            workingDirectory: seed)
        .stdout
        .toString()
        .trim();
    git(['push', '-q', 'origin', '$c1:refs/heads/chore/release-v0.1.496']);
  }
  if (openPr != null) File('${root.path}/open-pr.txt').writeAsStringSync(openPr);
  if (labelExists) File('${root.path}/label-exists').writeAsStringSync('');
  if (!labelCreateWorks) {
    File('${root.path}/label-create-fails').writeAsStringSync('');
  }
  File('${root.path}/log').writeAsStringSync('');

  final res = Process.runSync(
    'bash',
    ['${Directory.current.path}/scripts/auto_release.sh'],
    workingDirectory: seed,
    environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GH_STUB_DIR': root.path,
      'GH_LOG_FILE': '${root.path}/log',
      'GH_TOKEN': 'dummy-stub',
    },
  );
  return AutoRun(res.exitCode, '${res.stdout}${res.stderr}',
      File('${root.path}/log').readAsLinesSync());
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
      final haystacks = [
        ...workflows.map(read),
        read('scripts/auto_release.sh'),
        read('scripts/tag_release.sh'),
      ];
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
      // PR-path (2026-09-29): auto_release.sh only opens the chore/release-vX.Y.Z
      // bump PR and creates nothing; tag_release.sh (the release-tag job) owns
      // the single gh release create cut from the merged bump commit.
      expect(extractCreates(read('scripts/auto_release.sh')), isEmpty,
          reason: 'auto_release.sh must not create releases — the bump rides a PR; '
              'tag_release.sh owns the create');
      final tagCreates = extractCreates(read('scripts/tag_release.sh'));
      expect(tagCreates, hasLength(1),
          reason: 'tag_release.sh is the one race-free release-create path');
      for (final c in tagCreates) {
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

    test('tag_release.sh marks the new release latest explicitly', () {
      final creates = extractCreates(read('scripts/tag_release.sh'));
      expect(creates, isNotEmpty);
      for (final c in creates) {
        expect(c.text, contains('--latest'));
      }
    });
  });

  // ── gh-1134 — auto_release.sh labels release PRs chore:pin ──────────────
  // Behavioral: full sandbox (bare origin + seeded main @ v0.1.495 + stubbed
  // gh), same stubbed-gh pattern as the draft guard / sweeper tests above.
  group('gh-1134 — release PRs carry chore:pin (create + refresh self-heal)', () {
    List<String> calls(AutoRun r, String prefix) =>
        r.log.where((l) => l.startsWith(prefix)).toList();

    test('AC1: fresh branch — gh pr create carries --label chore:pin', () {
      final r = runAutoRelease('ac1-create');
      expect(r.exitCode, 0, reason: r.output);
      final creates = calls(r, 'gh pr create');
      expect(creates, hasLength(1), reason: r.log.join('\n'));
      expect(creates.single, contains('--label chore:pin'));
      expect(creates.single, contains('--title chore(release): v0.1.496'));
      expect(creates.single, contains('--head chore/release-v0.1.496'));
    });

    test('AC2+AC3: refresh adds the label to the open PR; already-labeled stays silent', () {
      final r = runAutoRelease('ac2-refresh', staleBranch: true, openPr: '12');
      expect(r.exitCode, 0, reason: r.output);
      final edits = calls(r, 'gh pr edit');
      expect(edits, hasLength(1), reason: r.log.join('\n'));
      expect(edits.single, contains('gh pr edit 12 --add-label chore:pin'));
      expect(r.output, isNot(contains('WARNING')),
          reason: 'label present: refresh must not warn (AC3)');
    });

    test('E1a: label missing — self-heals via gh label create, PR still labeled', () {
      final r = runAutoRelease('e1a-selfheal', labelExists: false);
      expect(r.exitCode, 0, reason: r.output);
      expect(calls(r, 'gh label create'), hasLength(1));
      final creates = calls(r, 'gh pr create');
      expect(creates, hasLength(1));
      expect(creates.single, contains('--label chore:pin'));
      expect(r.output, isNot(contains('WARNING')));
    });

    test('E1b: even the label create fails — loud warning, PR still ships unlabeled', () {
      final r = runAutoRelease('e1b-create-fails',
          labelExists: false, labelCreateWorks: false);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains("WARNING: label 'chore:pin' missing"));
      final creates = calls(r, 'gh pr create');
      expect(creates, hasLength(1));
      expect(creates.single, contains('--head chore/release-v0.1.496'));
      expect(creates.single, isNot(contains('--label')),
          reason: 'must not pass --label when the label could not be ensured');
    });
  });

  // ── AC6 — regression: no "Release v" bodies, atomic flow intact ─────────
  group('AC6 — regression', () {
    test('no "Release vX" filler bodies remain', () {
      final haystacks = [
        ...workflows.map(read),
        read('scripts/auto_release.sh'),
        read('scripts/tag_release.sh'),
      ];
      for (final text in haystacks) {
        expect(text, isNot(contains('--notes "Release v')));
      }
    });

    test('release flow is PR-path: auto_release.sh opens the bump PR, tag_release.sh cuts tag+release', () {
      // Protected main enforces admins+strict (2026-09-29): direct bot pushes
      // to main are rejected, so the bump lands as a chore/release-vX.Y.Z PR
      // (owner directive: tag-only variant rejected) and the release-tag job
      // cuts the tag + GitHub Release from the merged bump commit — the tag
      // must ride RELEASE_PAT so the tag-scoped binaries/publish jobs fire.
      final auto = read('scripts/auto_release.sh');
      expect(auto, contains('chore/release-v'));
      expect(auto, contains('gh pr create'));
      expect(auto, isNot(contains('git push --atomic origin main')),
          reason: 'direct main pushes are rejected by branch protection — PR path only');
      expect(auto, isNot(contains('git tag -a')),
          reason: 'tagging moved to tag_release.sh (tag rides RELEASE_PAT)');
      final tagScript = read('scripts/tag_release.sh');
      expect(tagScript, contains(r'git tag -a "$tag"'));
      expect(tagScript, contains(r'git push origin "$tag"'));
    });

    test('auto_release.sh labels release PRs chore:pin on create and refresh (gh-1134)', () {
      // PR #1130 shipped with zero labels: no --label anywhere in
      // auto_release.sh. Pin the real wiring (both paths + the self-heal),
      // never a script comment — same lesson as the RELEASE_PAT pin above.
      final auto = read('scripts/auto_release.sh');
      expect(auto, contains('release_label="chore:pin"'),
          reason: 'one shared constant so create and refresh paths cannot desync');
      expect(auto, contains(r'--label "$release_label"'),
          reason: 'release PRs must be created with chore:pin (gh-1134)');
      expect(auto, contains(r'--add-label "$release_label"'),
          reason: 'refresh path must self-heal label-less release PRs (gh-1134)');
      expect(auto, contains(r'gh label create "$release_label"'),
          reason: 'a missing label must self-heal per repo convention, warn-only on failure');
    });

    test('release jobs authenticate gh via RELEASE_PAT (env + checkout), not by comment (#1093 review)', () {
      // BLOCK finding on PR #1093 (2026-09-30): neither release job set
      // GH_TOKEN, so `gh pr create` in auto_release.sh died under set -e and
      // `gh release create` in tag_release.sh was a guaranteed silent no-op
      // — the curated notes never reached the release object. Pin the REAL
      // wiring (job env + checkout token), never a script comment.
      final ci = jobsOf('.github/workflows/ci.yml');
      for (final jobName in ['release', 'release-tag']) {
        final job = ci[jobName] as YamlMap;
        final env = job['env'] as YamlMap?;
        expect(env?['GH_TOKEN']?.toString(),
            equals(r'${{ secrets.RELEASE_PAT }}'),
            reason: '$jobName must export GH_TOKEN=RELEASE_PAT for its gh calls');
        final steps = job['steps'] as YamlList;
        final checkout = steps
            .map((s) => s as YamlMap)
            .firstWhere((s) => s['uses']?.toString().startsWith('actions/checkout') ?? false);
        expect(checkout['with']['token']?.toString(),
            equals(r'${{ secrets.RELEASE_PAT }}'),
            reason:
                '$jobName checkout must ride RELEASE_PAT — GITHUB_TOKEN tags/pushes never fire tag-scoped jobs');
      }
    });

    test('auto_release.sh untagged guard keys on pubspec version with a wedge escape, and remembers rejections', () {
      // IMPORTANT findings on PR #1093 (2026-09-30): subject-keying wedged
      // auto-release forever when release-tag missed (any non-squash or
      // interleaved merge changes the subject, not the version), and a
      // machine-closed release PR was re-created every 2h forever.
      final auto = read('scripts/auto_release.sh');
      expect(
          auto,
          contains(r'''head_version=$(git show origin/main:pubspec.yaml | sed -n 's/^version: //p')'''),
          reason: 'the untagged guard must key on the pubspec version');
      expect(auto, contains('-lt 3600'),
          reason: 'after 1h untagged the guard must let the next bump absorb the range (no indefinite wedge)');
      expect(auto, contains("--state closed"),
          reason: 'rejection memory: a machine-closed release PR must not be re-created every 2h');
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

  // ── gh-995 — artifact action pins + PTY shard pipeline coherence ────────
  // 2026-09-27 outage: the PTY legs were the only jobs still uploading
  // artifacts with the stale upload-artifact@ea165f8d (v4 line) pin while
  // the rest of the repo had moved to 043fb46d (v7.0.1). The gate downloads
  // with download-artifact@3e5f45b2 (v8.0.1), which digest-validates every
  // download — the stale uploads stopped verifying (digest-mismatch), the
  // shard merge saw < 3 reports and pty-coverage-gate wedged every run.
  // check_action_pins.sh cannot see this class (both forms are valid
  // full-SHA pins), so pin drift is guarded here instead.
  group('gh-995 — artifact action pins + PTY shard pipeline coherence', () {
    test('every third-party action is pinned at exactly ONE full SHA repo-wide', () {
      final byAction = usesByAction();
      expect(byAction, isNotEmpty);
      final drifted = <String>[];
      byAction.forEach((action, pins) {
        if (pins.length > 1) drifted.add('$action: ${pins.join(', ')}');
      });
      expect(drifted, isEmpty,
          reason: 'a second pin for the same action means one workflow was '
              'left behind on an old version — exactly how the pty legs '
              'wedge happened (their v4-era upload-artifact uploads failed '
              'the gate\'s v8 download digest validation)');
    });

    test('upload-artifact is pinned to the current digest-validating line everywhere', () {
      expect(usesByAction()['actions/upload-artifact'],
          {'043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'},
          reason: 'pty-coverage-gate downloads with download-artifact v8 '
              '(strict SHA256 digest validation); every upload must come '
              'from the same current action line or the download '
              'digest-mismatches and the shard merge loses a report');
    });

    test('pty shard coverage artifacts: upload name, download pattern and count check agree', () {
      // gh-1005: the consolidated leg is pty-integration-linux (the former
      // mac `pty-integration` shards merged in; there is no mac leg anymore).
      final jobs = jobsOf('.github/workflows/ci.yml');
      final integration = jobs['pty-integration-linux'] as YamlMap;
      final gate = jobs['pty-coverage-gate'] as YamlMap;

      // The matrix width is the source of truth for the expected report count.
      final shardCount =
          ((integration['strategy'] as YamlMap)['matrix'] as YamlMap)['shard'] as YamlList;
      expect(shardCount.length, 3, reason: 'the leg is documented as 3 shards');

      // Exactly one coverage upload per shard leg, named pty-coverage-shard-N.
      final uploadNames = <String>[];
      for (final step in integration['steps'] as YamlList) {
        if (step is YamlMap &&
            step['uses'].toString().startsWith('actions/upload-artifact')) {
          uploadNames.add(((step['with'] as YamlMap)['name']).toString());
        }
      }
      final coverageUploads =
          uploadNames.where((n) => n.startsWith('pty-coverage-shard-')).toList();
      expect(coverageUploads, hasLength(1),
          reason: 'exactly one pty-coverage-shard artifact per shard leg');

      // The gate downloads the pattern; every uploaded shard name matches it.
      String? pattern;
      for (final step in gate['steps'] as YamlList) {
        if (step is YamlMap &&
            step['uses'].toString().startsWith('actions/download-artifact') &&
            step['with'] is YamlMap &&
            ((step['with'] as YamlMap)['pattern'] ?? '').toString().startsWith('pty-coverage-shard-')) {
          pattern = ((step['with'] as YamlMap)['pattern']).toString();
        }
      }
      expect(pattern, isNotNull, reason: 'the gate must download pty-coverage-shard-*');
      final concreteName = coverageUploads.single.replaceAll(r'${{ matrix.shard }}', '0');
      expect(globToRegExp(pattern!).hasMatch(concreteName), isTrue,
          reason: 'upload name "${coverageUploads.single}" must match '
              'download pattern "$pattern"');

      // The merge step's hard count check must expect the matrix width.
      final mergeRuns = <String>[];
      for (final step in gate['steps'] as YamlList) {
        if (step is YamlMap && step['run'].toString().contains('pty shard coverage reports')) {
          mergeRuns.add(step['run'].toString());
        }
      }
      expect(mergeRuns, hasLength(1));
      final expected =
          RegExp(r'expected (\d+) pty shard coverage reports').firstMatch(mergeRuns.single);
      expect(expected, isNotNull);
      expect(int.parse(expected!.group(1)!), shardCount.length,
          reason: 'the count check must expect exactly the configured shard count');

      // A shard report that downloads but carries no SF: records (empty or
      // truncated upload) must fail the merge LOUDLY — the 2026-09-27
      // outage also showed a partial merge reading 7.95% against the
      // 11.00% baseline because a hollow report still satisfied the count.
      expect(mergeRuns.single, contains("'^SF:'"),
          reason: 'merge must reject hollow per-shard lcov reports before merging');
    });
  });

  // ── gh-1005 — PTY legs are hosted-linux-only, fa-m5-1 never on the PR path
  // The on-prem M5 pool is ONE runner reserved for macOS-specific work
  // (cube-kernel-live). These pins freeze the migration topology: the
  // runner-pick probe is gone, the consolidated linux leg carries coverage
  // + duration reporting, and no PTY screenshot leg sits on macOS.
  group('gh-1005 — PTY legs never route to fa-m5 / hosted macOS', () {
    test('no runner-pick probe and no mac pty-integration leg remains', () {
      final ci = jobsOf('.github/workflows/ci.yml');
      final nightly = jobsOf('.github/workflows/nightly.yml');
      expect(ci.containsKey('runner-pick'), isFalse,
          reason: 'the M5_POOL probe would route PR legs back onto fa-m5-1');
      expect(ci.containsKey('pty-integration'), isFalse,
          reason: 'the mac shards merged into pty-integration-linux (gh-1005)');
      expect(nightly.containsKey('runner-pick'), isFalse);
      // The reserved runner's only PR-time consumer stays the macOS kernel E2E.
      expect((ci['cube-kernel-live'] as YamlMap)['runs-on'].toString(),
          contains('macos-m5'),
          reason: 'cube-kernel-live keeps the genuinely macOS-only gate on fa-m5-1');
    });

    test('every PR PTY leg runs on ubuntu-24.04-arm', () {
      final ci = jobsOf('.github/workflows/ci.yml');
      for (final id in ['pty-integration-linux', 'pty-visual', 'cli-visual-settings']) {
        expect((ci[id] as YamlMap)['runs-on'].toString(), 'ubuntu-24.04-arm',
            reason: '\$id must stay on the hosted linux arm64 pool');
      }
      final nightly = jobsOf('.github/workflows/nightly.yml');
      expect((nightly['pty-integration'] as YamlMap)['runs-on'].toString(),
          'ubuntu-24.04-arm');
      expect((nightly['cli-visual'] as YamlMap)['runs-on'].toString(),
          'ubuntu-24.04-arm');
    });

    test('the consolidated linux leg carries the coverage + duration reporting', () {
      final job = jobsOf('.github/workflows/ci.yml')['pty-integration-linux'] as YamlMap;
      final steps = job['steps'] as YamlList;
      final runText = steps.whereType<YamlMap>().map((s) {
        final withBlock = s['with'];
        return '${s['run'] ?? ''} ${s['uses'] ?? ''} ${withBlock ?? ''}';
      }).join('\n');
      expect(runText, contains('--coverage=coverage'),
          reason: 'the leg feeds the CLI coverage ratchet');
      expect(runText, contains('--file-reporter'),
          reason: 'the leg feeds the #928 duration gate');
      for (final artifact in ['pty-coverage-shard-', 'integration-json-shard-']) {
        expect(runText, contains(artifact),
            reason: '\$artifact uploads must survive the consolidation '
                '(pty-coverage-gate downloads them)');
      }
      // The gate consumes THIS leg, not a phantom mac leg.
      expect((jobsOf('.github/workflows/ci.yml')['pty-coverage-gate'] as YamlMap)['needs']
          .toString(), contains('pty-integration-linux'));
    });
  });

  group('committed-artifact hygiene (gh-1033 review thread 11)', () {
    test('no cov-*/ raw coverage dump directories exist in the tree', () {
      final offenders = Directory('.')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .where((name) => name.startsWith('cov-'))
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'scratch coverage runs must write under the ignored '
            'coverage/ dir — a WIP auto-save swept cov-raw2/ (2.8 MB of '
            'VM coverage JSON with absolute runner paths) onto the branch '
            'once already',
      );
    });

    test('.gitignore sweeps future cov-*/ scratch dirs', () {
      expect(
        read('.gitignore').split('\n').map((line) => line.trim()),
        contains('cov-*/'),
        reason: 'next to the coverage/ entries: a stray cov-* run dir '
            'must never become committable again',
      );
    });
  });
}

