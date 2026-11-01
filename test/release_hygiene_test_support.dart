// Shared harness for release_hygiene_test.dart (issue #282 AC1-AC5 + review
// of #294 + gh-1172/gh-1522): workflow parsing helpers (gh release create
// block extraction, job iteration) and the behavioral fixture sandboxes.
// Extracted verbatim when the loc-scope gate capped the test file at 2800
// lines — no behavioral change; the library-privacy renames are mechanical.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

// ── workflow parsing helpers ───────────────────────────────────────────────

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

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

  String stripComment(String l) =>
      l.contains('#') && !l.contains('"#') ? l.split('#').first : l;

  for (var i = 0; i < lines.length; i++) {
    if (!RegExp(r'gh\s+release\s+create\b').hasMatch(stripComment(lines[i]))) {
      continue;
    }
    final cmdLines = <String>[lines[i]];
    var j = i;
    while (j < lines.length - 1 &&
        stripComment(cmdLines.last).trimRight().endsWith(r'\')) {
      j++;
      cmdLines.add(lines[j]);
    }
    i = j;

    // tag = first positional argument on the create line itself.
    final createLine = stripComment(cmdLines.first).trim();
    final tagMatch = RegExp(r'gh\s+release\s+create\s+("[^"]*"|\S+)')
        .firstMatch(createLine);
    final tag = tagMatch?.group(1);

    var title = <String?>[]; // collect from any line
    final positional = <String>[];
    for (final raw in cmdLines) {
      final line = stripComment(raw).trimRight();
      final bare = line.replaceAll(r'\', '').trim();
      if (bare.isEmpty) continue;
      final t = _after(bare, '--title');
      if (t != null) title.add(t);
      final onFlagLine =
          bare.startsWith('--') ||
          RegExp(r'gh\s+release\s+create').hasMatch(bare);
      if (!onFlagLine && !bare.startsWith('- ')) {
        positional.add(bare);
      }
    }
    blocks.add(
      CreateBlock(
        cmdLines.join('\n'),
        tag,
        title.isEmpty ? null : title.last,
        positional,
      ),
    );
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
    if (step is! YamlMap ||
        !step.containsKey('if') ||
        !step.containsKey('run')) {
      continue;
    }
    final cond = step['if'].toString();
    final body = step['run'].toString();
    final isAlways = cond.contains('always()') || cond.contains('failure()');
    final deletesDraft =
        body.contains('release_draft_guard.sh') ||
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

final hygieneFixtureRoot = Directory.systemTemp.createTempSync(
  'release-hygiene-',
);

/// Full behavioral sandbox for the gh-1522 tag-only release flow of
/// scripts/auto_release.sh: a bare origin whose main carries 2 commits
/// ('seed' backdated [commitAgeHours] (default [tagAgeHours]) + 'pending
/// work') and an annotated tag v0.1.495 [tagAgeHours] ago (3h = past the
/// 2h coalesce window; 0 = cut just now — the two ages diverge to pin the
/// tagger-date-vs-commit-date coalesce measurement), a seed
/// clone the script runs in, a `gh` stub that logs every invocation (the
/// script's create is `|| true`), and a `git` shim that can pre-push the
/// same tag from a second clone right before each
/// `git push origin refs/tags/v*` ([raceMode] `once`/`always` — the E1
/// tag-push race: the remote answers 'already exists' and the retry loop
/// re-derives the next version from the freshly fetched tags). NO sed /
/// flutter / file-mutation shims: the tag-only script mutates ZERO files —
/// the git tag is the single source of truth.
AutoReleaseRun runAutoReleaseDirect(
  String name, {
  int tagAgeHours = 3,
  int? commitAgeHours,
  bool dryRun = false,
  String raceMode = 'never',
}) {
  final root = Directory(
    '${hygieneFixtureRoot.path}/direct-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final origin = '${root.path}/origin.git';
  final seed = '${root.path}/seed';
  final racer = '${root.path}/racer';
  final bin = '${root.path}/bin';
  Directory(bin).createSync(recursive: true);

  // gh stub: log every invocation and exit 0 — auto_release.sh's
  // `gh release create ... || true` must reach the log so tests can assert
  // exactly one create per release, with the right tag.
  final ghLogPath = '${root.path}/gh.log';
  File('$bin/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$FA_GH_LOG"
exit 0
''');
  Process.runSync('chmod', ['+x', '$bin/gh']);

  final realGit = resolveRealGit(bin);
  // git shim: forward everything to real git, but in race mode pre-push the
  // same annotated tag from the racer clone right before each tag push, so
  // the script's push rejects with 'already exists' for real (the
  // re-derive-on-fresh-tags path of E1). The countdown lives in a FILE, not
  // an env var: every push spawns a fresh shim process, so an exported
  // decrement would never persist. The racer's own push goes through the
  // REAL git binary so the hook never fires recursively.
  final raceFile = '${root.path}/race-left';
  File(raceFile).writeAsStringSync(
    raceMode == 'once' ? '1' : (raceMode == 'always' ? '9' : '0'),
  );
  final raceHook = raceMode == 'never'
      ? ''
      : '''
if [ "\$1" = "push" ]; then
  raced_tag=""
  for a in "\$@"; do
    case "\$a" in
      refs/tags/v*) raced_tag="\${a#refs/tags/}" ;;
    esac
  done
  if [ -n "\$raced_tag" ] && [ -f "\$FA_RACE_FILE" ]; then
    race_left=\$(cat "\$FA_RACE_FILE")
    if [ "\$race_left" -gt 0 ]; then
      echo \$((race_left-1)) > "\$FA_RACE_FILE"
      # gh-1522 rework: the racer clone has no ambient git identity (the
      # seed clone's `git config` does not leak into it), and an annotated
      # tag fails without one on hosts with no global identity (GitHub
      # runners, the hostile-env leg) — carry the identity inline, matching
      # the retired pre-gh-1522 hook's pattern. One line: a trailing
      # backslash continuation misbehaves inside the generated shim.
      "\$FA_REAL_GIT" -c user.email=t@t -c user.name=t -C "\$FA_RACER" tag -a "\$raced_tag" -m "Release \$raced_tag" origin/main
      "\$FA_REAL_GIT" -C "\$FA_RACER" push -q origin "refs/tags/\$raced_tag"
    fi
  fi
fi
''';
  File('$bin/git').writeAsStringSync('''
#!/usr/bin/env bash
$raceHook
exec "\$FA_REAL_GIT" "\$@"
''');
  Process.runSync('chmod', ['+x', '$bin/git']);

  void git(
    List<String> args, {
    String? cwd,
    Map<String, String> env = const {},
  }) {
    final r = Process.runSync(
      realGit,
      args,
      workingDirectory: cwd ?? seed,
      environment: env,
      includeParentEnvironment: true,
    );
    expect(r.exitCode, 0, reason: 'fixture git $args failed: ${r.stderr}');
  }

  Directory(origin).createSync();
  git(['init', '-q', '--bare', '-b', 'main', origin], cwd: root.path);
  git(['clone', '-q', origin, seed], cwd: root.path);
  git(['config', 'user.email', 't@t']);
  git(['config', 'user.name', 't']);
  // gh-1522: the script reads NO repo file — the fixture seeds only git
  // history: 'seed' (backdated so the v0.1.495 tag sits past the 2h
  // coalesce window), an annotated v0.1.495 tag on it, and one pending
  // commit on main.
  File('$seed/README.md').writeAsStringSync('seed\n');
  git(['add', '-A']);
  git(
    ['commit', '-q', '-m', 'seed'],
    env: {
      'GIT_COMMITTER_DATE':
          (DateTime.now()
                      .subtract(Duration(hours: commitAgeHours ?? tagAgeHours))
                      .millisecondsSinceEpoch ~/
                  1000)
              .toString(),
    },
  );
  git(
    ['tag', '-a', 'v0.1.495', '-m', 'Release v0.1.495'],
    env: {
      'GIT_COMMITTER_DATE':
          (DateTime.now()
                      .subtract(Duration(hours: tagAgeHours))
                      .millisecondsSinceEpoch ~/
                  1000)
              .toString(),
    },
  );
  File('$seed/README.md').writeAsStringSync('pending\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'pending work']);
  git(['push', '-q', 'origin', 'main']);
  git(['push', '-q', 'origin', 'v0.1.495']);
  git(['clone', '-q', origin, racer], cwd: root.path);

  String originMain() {
    final r = Process.runSync(realGit, [
      '--git-dir',
      origin,
      'rev-parse',
      'refs/heads/main',
    ]);
    expect(r.exitCode, 0, reason: 'fixture rev-parse failed: ${r.stderr}');
    return r.stdout.toString().trim();
  }

  final headBefore = originMain();

  // Sanitize GIT_* out of the inherited environment: `git commit` exports
  // GIT_AUTHOR_*/GIT_COMMITTER_* (the COMMITTING repo's identity) into hook
  // processes, and ci_fast_gate.sh unsets only GIT_DIR/GIT_INDEX_FILE/
  // GIT_WORK_TREE — under the pre-commit gate those vars overrode the
  // sandbox script's own `git config user.name fa-release-bot[bot]`, making
  // tag authorship flake (hook runs only; direct `dart test` was green).
  final baseEnv = <String, String>{
    for (final e in Platform.environment.entries)
      if (!e.key.startsWith('GIT_')) e.key: e.value,
    'PATH': '$bin:${Platform.environment['PATH']}',
    'FA_REAL_GIT': realGit,
    'FA_RACER': racer,
    'FA_RACE_FILE': raceFile,
    'FA_GH_LOG': ghLogPath,
    'GITHUB_REPOSITORY': 'OWNER/REPO',
    'GH_TOKEN': 'stub',
  };
  final env = Map<String, String>.from(baseEnv);
  if (dryRun) env['RELEASE_DRY_RUN'] = '1';

  final res = Process.runSync(
    'bash',
    ['${Directory.current.path}/scripts/auto_release.sh'],
    workingDirectory: seed,
    environment: env,
    includeParentEnvironment: false, // sanitized above — no GIT_* leak
  );
  return AutoReleaseRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    headBefore,
    originMain(),
    realGit,
    seed,
    origin,
    baseEnv,
    ghLogPath,
  );
}

class AutoReleaseRun {
  AutoReleaseRun(
    this.exitCode,
    this.output,
    this.originHeadBefore,
    this.originHeadAfter,
    this.gitBin,
    this.seedPath,
    this._originGitDir,
    this._baseEnv,
    this._ghLogPath,
  );

  final int exitCode;
  final String output; // stdout+stderr
  final String originHeadBefore;
  final String originHeadAfter;
  final String gitBin;
  final String seedPath;
  final String _originGitDir;
  final Map<String, String> _baseEnv;
  final String _ghLogPath;

  /// Subjects of the last [n] commits on origin/main, newest first.
  List<String> originSubjects([int n = 3]) => _git([
    '--git-dir',
    _originGitDir,
    'log',
    '--pretty=%s',
    '-n',
    '$n',
    'main',
  ]).split('\n');

  /// Author identity of origin/main's head commit.
  String originHeadAuthor() => _git([
    '--git-dir',
    _originGitDir,
    'log',
    '--pretty=%an <%ae>',
    '-n',
    '1',
    'main',
  ]);

  /// All tags on origin, sorted.
  List<String> originTags() =>
      _git(['--git-dir', _originGitDir, 'tag', '--sort=v:refname']).split('\n');

  /// Whether [tag] exists on origin.
  bool originTagExists(String tag) =>
      Process.runSync(gitBin, [
        '--git-dir',
        _originGitDir,
        'rev-parse',
        '-q',
        '--verify',
        'refs/tags/$tag',
      ]).exitCode ==
      0;

  /// The commit [tag] on origin points at (peeled).
  String originTagTarget(String tag) =>
      _git(['--git-dir', _originGitDir, 'rev-parse', 'refs/tags/$tag^{}']);

  /// Every line the `gh` stub logged (empty when the script never called gh).
  List<String> ghLog() => File(_ghLogPath).existsSync()
      ? File(_ghLogPath).readAsLinesSync()
      : const [];

  /// Whether the seed clone still carries [tag] locally.
  bool seedTagExists(String tag) =>
      Process.runSync(gitBin, [
        '-C',
        seedPath,
        'rev-parse',
        '-q',
        '--verify',
        'refs/tags/$tag',
      ]).exitCode ==
      0;

  String _git(List<String> args) {
    final r = Process.runSync(gitBin, args);
    expect(r.exitCode, 0, reason: 'sandbox git $args failed: ${r.stderr}');
    return r.stdout.toString().trim();
  }

  /// Re-runs auto_release.sh in the SAME sandbox (seed + origin keep their
  /// state from the previous run) — for multi-release tag sequences.
  AutoReleaseRun rerun({bool dryRun = false}) {
    final before = _git(['--git-dir', _originGitDir, 'rev-parse', 'main']);
    final env = Map<String, String>.from(_baseEnv);
    if (dryRun) env['RELEASE_DRY_RUN'] = '1';
    final res = Process.runSync(
      'bash',
      ['${Directory.current.path}/scripts/auto_release.sh'],
      workingDirectory: seedPath,
      environment: env,
      includeParentEnvironment: false, // sanitized baseEnv — no GIT_* leak
    );
    return AutoReleaseRun(
      res.exitCode,
      '${res.stdout}${res.stderr}',
      before,
      _git(['--git-dir', _originGitDir, 'rev-parse', 'main']),
      gitBin,
      seedPath,
      _originGitDir,
      _baseEnv,
      _ghLogPath,
    );
  }
}

/// The real git binary for sandbox shims AND for the fixture helpers: the
/// session PATH may carry git-push-guard.sh shims (agent-session push guard)
/// — skip any copy of those plus [skipDir] (the sandbox's own shim dir) so
/// every git call this suite makes resolves to a real binary, whatever the
/// host put at the front of PATH (gh-1172 round-3 suggestion).
String resolveRealGit([String? skipDir]) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty || dir == skipDir) continue;
    final cand = '$dir/git';
    if (!File(cand).existsSync()) continue;
    final resolved = File(cand).resolveSymbolicLinksSync();
    if (resolved.endsWith('git-push-guard.sh')) continue;
    return resolved;
  }
  return '/usr/bin/git';
}

/// A real git repo fixture: commits, tags, optional post-tag commits (the
/// "since previous tag" range), optional CHANGELOG.
String fixtureRepo(
  String name,
  List<String> commitSubjects,
  List<String> tags, [
  String? changelog,
  List<String> postTagSubjects = const [],
]) {
  final dir = Directory('${hygieneFixtureRoot.path}/$name');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  // Route through the resolved real git — a session shim first on PATH (e.g.
  // a broken git-push-guard copy) would silently fail init/commit and the
  // notes tests would read an empty history (gh-1172 round-3 suggestion).
  final git = resolveRealGit();
  Process.runSync(git, ['init', '-q'], workingDirectory: dir.path);
  Process.runSync(git, [
    'config',
    'user.email',
    't@t',
  ], workingDirectory: dir.path);
  Process.runSync(git, [
    'config',
    'user.name',
    't',
  ], workingDirectory: dir.path);
  if (changelog != null) {
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(changelog);
  }
  var i = 0;
  for (final group in [commitSubjects, postTagSubjects]) {
    for (final subject in group) {
      File('${dir.path}/f$i.txt').writeAsStringSync('$i');
      Process.runSync(git, ['add', '.'], workingDirectory: dir.path);
      Process.runSync(git, [
        'commit',
        '-q',
        '-m',
        subject,
      ], workingDirectory: dir.path);
      i++;
    }
    for (final tag in tags) {
      Process.runSync(git, ['tag', tag], workingDirectory: dir.path);
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
        # per call (exists|missing), popped off the top. An EXHAUSTED
        # (empty) sequence file falls through to the structured answers —
        # the gh-1801 rework adds a servability query (assets) after the
        # scripted exists/missing verdicts.
        if [ -s "\$GH_STUB_DIR/view-seq.txt" ]; then
          w=\$(head -1 "\$GH_STUB_DIR/view-seq.txt")
          sed -i.bak '1d' "\$GH_STUB_DIR/view-seq.txt" && rm -f "\$GH_STUB_DIR/view-seq.txt.bak"
          [ "\$w" = "exists" ] && exit 0
          echo "release not found (stub)" >&2
          exit 1
        fi
        case " \$*" in
          *--json\\ assets*) cat "\$GH_STUB_DIR/asset-names.txt" 2>/dev/null || echo "" ;;
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
  final sweep =
      jobsOf('.github/workflows/daily-publish.yml')['sweep-drafts'] as YamlMap;
  final perms = sweep['permissions'];
  if (perms is! YamlMap || perms.isEmpty) return '';
  return perms.keys.map((k) => k.toString()).join(' ');
}

SweepRun runSweeper(String stubDir, Map<String, String> stubFiles) {
  final dir = Directory(
    '${hygieneFixtureRoot.path}/sweep-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
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
  return SweepRun(
    res.stdout.toString(),
    File('${dir.path}/log').readAsLinesSync(),
    File('${dir.path}/last-body.md').existsSync()
        ? File('${dir.path}/last-body.md').readAsStringSync()
        : null,
  );
}

class GuardRun {
  GuardRun(this.exitCode, this.out, this.log);
  final int exitCode;
  final String out;
  final List<String> log;
}

class AttachOut {
  AttachOut(this.exitCode, this.out, this.log, this.createdNotes);
  final int exitCode;
  final String out;
  final List<String> log;
  final String?
  createdNotes; // release body the create would publish (stub capture)
}

/// Runs the draft guard as workflow job [job] of run [runId], with the
/// release state/body served by the stub.
GuardRun runGuard(
  String name,
  String state, {
  String? body,
  String runId = '111',
  String job = 'release-macos',
}) {
  final dir = Directory(
    '${hygieneFixtureRoot.path}/guard-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = stubGh(dir.path);
  File('${dir.path}/release-state.txt').writeAsStringSync(state);
  if (body != null) {
    File('${dir.path}/release-body.txt').writeAsStringSync(body);
  }
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
  return GuardRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/log').readAsLinesSync(),
  );
}
