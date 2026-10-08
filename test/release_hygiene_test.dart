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
    if (!RegExp(r'gh\s+release\s+create\b').hasMatch(stripComment(lines[i])))
      continue;
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
    final tagMatch = RegExp(
      r'gh\s+release\s+create\s+("[^"]*"|\S+)',
    ).firstMatch(createLine);
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
    if (step is! YamlMap || !step.containsKey('if') || !step.containsKey('run'))
      continue;
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
        byAction
            .putIfAbsent(ref.substring(0, at), () => {})
            .add(ref.substring(at + 1));
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
        .where(
          (f) =>
              f.path.endsWith('action.yml') || f.path.endsWith('action.yaml'),
        )
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

/// Full behavioral sandbox for the gh-1172 direct-push path of
/// scripts/auto_release.sh: a bare origin whose main carries pubspec 0.1.495
/// tagged v0.1.495 [tagAgeHours] ago (3h = past the 2h coalesce window) plus
/// one pending commit, a seed clone the script runs in, and a `git` shim that
/// can advance origin/main from a second clone right before each
/// `git push origin HEAD:main` ([raceMode] `once`/`always` — E1 race
/// injection). No `gh` stub: the direct-push path is git + python3 only.
AutoReleaseRun runAutoReleaseDirect(
  String name, {
  int tagAgeHours = 3,
  bool dryRun = false,
  String raceMode = 'never',
  bool flutterFails = false,
  bool flutterDirty = false,
  bool brokenInventory = false,
}) {
  final root = Directory(
    '${_fixtureRoot.path}/direct-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final origin = '${root.path}/origin.git';
  final seed = '${root.path}/seed';
  final racer = '${root.path}/racer';
  final bin = '${root.path}/bin';
  Directory(bin).createSync(recursive: true);

  // auto_release.sh uses GNU `sed -i` (CI-authored, ubuntu); BSD hosts need
  // the empty-suffix form — transparent shim, real sed either way.
  File('$bin/sed').writeAsStringSync(r'''
#!/usr/bin/env bash
if [ "${1:-}" = "-i" ]; then shift
  if /usr/bin/sed --version >/dev/null 2>&1; then exec /usr/bin/sed -i "$@"
  else exec /usr/bin/sed -i '' "$@"; fi
fi
exec /usr/bin/sed "$@"
''');
  Process.runSync('chmod', ['+x', '$bin/sed']);

  final realGit = _resolveRealGit(bin);
  // git shim: forward everything to real git, but in race mode advance
  // origin/main from the racer clone right before each push so the script's
  // FF-only push races for real (the recompute-on-fresh-head path of E1).
  // The countdown lives in a FILE, not an env var: every push spawns a fresh
  // shim process, so an exported decrement would never persist.
  final raceFile = '${root.path}/race-left';
  File(raceFile).writeAsStringSync(
    raceMode == 'once' ? '1' : (raceMode == 'always' ? '9' : '0'),
  );
  final raceHook = raceMode == 'never'
      ? ''
      : '''
if [ "\$1" = "push" ] && [ -f "\$FA_RACE_FILE" ]; then
  race_left=\$(cat "\$FA_RACE_FILE")
  if [ "\$race_left" -gt 0 ]; then
    echo \$((race_left-1)) > "\$FA_RACE_FILE"
    "\$FA_REAL_GIT" -C "\$FA_RACER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "raced commit"
    "\$FA_REAL_GIT" -C "\$FA_RACER" push -q origin main
  fi
fi
''';
  File('$bin/git').writeAsStringSync('''
#!/usr/bin/env bash
$raceHook
exec "\$FA_REAL_GIT" "\$@"
''');
  Process.runSync('chmod', ['+x', '$bin/git']);

  // gh-1299 flutter stub: `pub get` regenerates flutter_app/pubspec.lock
  // from flutter_app/pubspec.yaml — the path-dep version line carries the
  // pubspec version, exactly the drift class the real refresh fixes.
  // FA_FLUTTER_FAIL present -> exit 65 (the real enforce-lockfile exit
  // code); FA_FLUTTER_DIRTY present -> leaves a TRACKED inventory lockfile
  // modified (the pod-install-only drift class pub get cannot fix).
  File('$bin/flutter').writeAsStringSync(r'''
#!/usr/bin/env bash
case " $* " in
  *" pub get"*) ;;
  *) echo "flutter-stub: unexpected invocation: $*" >&2; exit 64 ;;
esac
if [ -f "$FA_FLUTTER_FAIL" ]; then
  echo "Unable to satisfy \`pubspec.yaml\` using \`pubspec.lock\`. (stub)" >&2
  exit 65
fi
ver=$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' pubspec.yaml)
printf '# Generated by pub (sandbox stub)\npackages:\n  flutter_agent_harness:\n    description:\n      path: ".."\n    source: path\n    version: "%s"\n' "$ver" > pubspec.lock
if [ -f "$FA_FLUTTER_DIRTY" ]; then
  echo "  - StalePod (9.9.9): pod-install-only drift" >> ios/Podfile.lock
fi
''');
  Process.runSync('chmod', ['+x', '$bin/flutter']);
  if (flutterFails) File('${root.path}/flutter-fail').writeAsStringSync('1');
  if (flutterDirty) File('${root.path}/flutter-dirty').writeAsStringSync('1');

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
  Directory('$seed/flutter_app').createSync();
  File('$seed/pubspec.yaml').writeAsStringSync('version: 0.1.495\n');
  File(
    '$seed/flutter_app/pubspec.yaml',
  ).writeAsStringSync('version: 0.1.495+1\n');
  File(
    '$seed/CHANGELOG.md',
  ).writeAsStringSync('# Changelog\n\n## Unreleased\n');
  // gh-1299: the seed ships the committed-lockfile shape of the real repo —
  // a STALE pubspec.lock (pins the PRE-bump parent version, exactly the
  // v1.0.515 drift) plus the tracked Podfile.lock inventory sibling.
  File('$seed/flutter_app/pubspec.lock').writeAsStringSync(
    '# Generated by pub (sandbox seed)\n'
    'packages:\n'
    '  flutter_agent_harness:\n'
    '    description:\n'
    '      path: ".."\n'
    '    source: path\n'
    '    version: "0.1.495"\n',
  );
  Directory('$seed/flutter_app/ios').createSync();
  File(
    '$seed/flutter_app/ios/Podfile.lock',
  ).writeAsStringSync('PODS:\n  - Flutter (3.47.6)\n');
  // The release script consumes the REAL lockfile inventory
  // (scripts/check_lockfiles.sh) for its dirty-tree gate — ship the real
  // gate script so the sandbox exercises the production list, not a copy.
  Directory('$seed/scripts').createSync();
  File('$seed/scripts/check_lockfiles.sh').writeAsStringSync(
    File(
      '${Directory.current.path}/scripts/check_lockfiles.sh',
    ).readAsStringSync(),
  );
  if (brokenInventory) {
    // PR #1304 rework threads 1+5: model a BROKEN inventory source — a bad
    // merge / partial checkout where `check_lockfiles.sh list` exits 0
    // printing NOTHING. The dirty-tree gate must refuse to release
    // unguarded, never degrade to an unrestricted whole-tree scan.
    File('$seed/scripts/check_lockfiles.sh').writeAsStringSync(
      '#!/usr/bin/env bash\n'
      '# sandbox: broken inventory — silent success, zero paths\n'
      'exit 0\n',
    );
  }
  git(['add', '-A']);
  git(
    ['commit', '-q', '-m', 'seed'],
    env: {
      'GIT_COMMITTER_DATE':
          (DateTime.now()
                      .subtract(Duration(hours: tagAgeHours))
                      .millisecondsSinceEpoch ~/
                  1000)
              .toString(),
    },
  );
  git(['tag', 'v0.1.495']);
  File('$seed/README.md').writeAsStringSync('pending\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'pending work']);
  git(['push', '-q', 'origin', 'main']);
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
  // sandbox script's own `git config user.name fa-release-bot[bot]` and the
  // bump came out authored as the host repo's identity, flaking the
  // authorship assertion (hook runs only; direct `dart test` was green).
  final baseEnv = <String, String>{
    for (final e in Platform.environment.entries)
      if (!e.key.startsWith('GIT_')) e.key: e.value,
    'PATH': '$bin:${Platform.environment['PATH']}',
    'FA_REAL_GIT': realGit,
    'FA_RACER': racer,
    'FA_RACE_FILE': raceFile,
    'FA_FLUTTER_FAIL': '${root.path}/flutter-fail',
    'FA_FLUTTER_DIRTY': '${root.path}/flutter-dirty',
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
  );
}

class AutoReleaseRun {
  AutoReleaseRun(
    this.exitCode,
    this.output,
    this.originHeadBefore,
    this.originHeadAfter,
    this._gitBin,
    this._seedPath,
    this._originGitDir,
    this._baseEnv,
  );

  final int exitCode;
  final String output; // stdout+stderr
  final String originHeadBefore;
  final String originHeadAfter;
  final String _gitBin;
  final String _seedPath;
  final String _originGitDir;
  final Map<String, String> _baseEnv;

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

  /// Subject of the seed clone's HEAD (the local would-be/landed bump).
  String seedLastSubject() =>
      _git(['-C', _seedPath, 'log', '--pretty=%s', '-n', '1', 'HEAD']);

  String _git(List<String> args) {
    final r = Process.runSync(_gitBin, args);
    expect(r.exitCode, 0, reason: 'sandbox git $args failed: ${r.stderr}');
    return r.stdout.toString().trim();
  }

  /// Re-runs auto_release.sh in the SAME sandbox (seed + origin keep their
  /// state from the previous run) — for multi-release sequences like the
  /// CHANGELOG '## Unreleased' dedupe test.
  AutoReleaseRun rerun({bool dryRun = false}) {
    final before = _git(['--git-dir', _originGitDir, 'rev-parse', 'main']);
    final env = Map<String, String>.from(_baseEnv);
    if (dryRun) env['RELEASE_DRY_RUN'] = '1';
    final res = Process.runSync(
      'bash',
      ['${Directory.current.path}/scripts/auto_release.sh'],
      workingDirectory: _seedPath,
      environment: env,
      includeParentEnvironment: false, // sanitized baseEnv — no GIT_* leak
    );
    return AutoReleaseRun(
      res.exitCode,
      '${res.stdout}${res.stderr}',
      before,
      _git(['--git-dir', _originGitDir, 'rev-parse', 'main']),
      _gitBin,
      _seedPath,
      _originGitDir,
      _baseEnv,
    );
  }

  /// Reads [path] from origin/main (post-run remote file state).
  String originFile(String path) =>
      _git(['--git-dir', _originGitDir, 'show', 'main:$path']);
}

/// The real git binary for sandbox shims AND for the fixture helpers: the
/// session PATH may carry git-push-guard.sh shims (agent-session push guard)
/// — skip any copy of those plus [skipDir] (the sandbox's own shim dir) so
/// every git call this suite makes resolves to a real binary, whatever the
/// host put at the front of PATH (gh-1172 round-3 suggestion).
String _resolveRealGit([String? skipDir]) {
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
  final dir = Directory('${_fixtureRoot.path}/$name');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  // Route through the resolved real git — a session shim first on PATH (e.g.
  // a broken git-push-guard copy) would silently fail init/commit and the
  // notes tests would read an empty history (gh-1172 round-3 suggestion).
  final git = _resolveRealGit();
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
  if (changelog != null)
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(changelog);
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
    '${_fixtureRoot.path}/sweep-${DateTime.now().microsecondsSinceEpoch}',
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

class _AttachOut {
  _AttachOut(this.exitCode, this.out, this.log, this.createdNotes);
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
    '${_fixtureRoot.path}/guard-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = stubGh(dir.path);
  File('${dir.path}/release-state.txt').writeAsStringSync(state);
  if (body != null)
    File('${dir.path}/release-body.txt').writeAsStringSync(body);
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

void main() {
  // ── AC1 — draft lifecycle invariant (UT-lifecycle) ──────────────────────
  group('AC1 — every draft-capable create has a failure-path guard', () {
    for (final wf in [
      '.github/workflows/build-macos.yml',
      '.github/workflows/build-mobile.yml',
    ]) {
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
            reason:
                '$wf job "$jobId" creates release with assets '
                '(gh uploads them through a draft) but has no always()/failure() '
                'draft-deletion guard step in the same job',
          );
        });
        expect(
          checked,
          greaterThan(0),
          reason: 'lint must find the known asset-carrying creates',
        );
      });
    }

    test(
      'lint is real: a fixture job that creates a draft and dies is flagged',
      () {
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
      },
    );

    test(
      'AC6: ci.yml tag-publish path stays untouched (its creates are not draft-capable)',
      () {
        final jobs = jobsOf('.github/workflows/ci.yml');
        var creates = 0;
        jobs.forEach((_, job) => creates += jobCreates(job).length);
        expect(
          creates,
          greaterThan(0),
          reason: 'ci.yml tag release create must still exist',
        );
        jobs.forEach((_, job) {
          for (final c in jobCreates(job)) {
            expect(
              c.carriesAssets,
              isFalse,
              reason: 'ci.yml create must stay asset-free (AC6)',
            );
          }
        });
      },
    );

    test(
      'guard script: deletes own draft, spares published/missing releases',
      () {
        for (final state in ['true', 'false', 'missing']) {
          final run = runGuard(
            'states-$state',
            state,
            body: '<!-- release-draft-owner: run/111/job/release-macos -->',
          );
          if (state == 'true') {
            expect(
              run.log,
              contains('release delete v1.2.3 --repo OWNER/REPO --yes'),
              reason: 'own draft must be deleted',
            );
          } else {
            expect(
              run.log.where((l) => l.contains('delete')),
              isEmpty,
              reason: 'state $state must not delete',
            );
          }
        }
      },
    );

    test(
      'ownership: a failed leg cannot delete the sibling leg\'s mid-upload draft',
      () {
        // daily-publish runs the macOS and mobile legs concurrently on the
        // same derived tag: build-mobile run 999 is mid-upload (its draft is
        // stamped run/999/job/release-mobile) when build-macos run 111 fails
        // and its guard fires — it must refuse, not destroy the sibling.
        final run = runGuard(
          'sibling',
          'true',
          body: '<!-- release-draft-owner: run/999/job/release-mobile -->',
          runId: '111',
          job: 'release-macos',
        );
        expect(
          run.log.where((l) => l.contains('release delete')),
          isEmpty,
          reason: 'a draft owned by another run+job must never be deleted',
        );
        expect(run.exitCode, 0, reason: 'refusal is a warning, not a failure');
        expect(
          run.out,
          contains('refusing'),
          reason: 'the refusal must be visible in the job log',
        );
        expect(
          run.out,
          contains('run/999/job/release-mobile'),
          reason: 'the warning must name the actual owner',
        );
      },
    );

    test(
      'ownership: a cross-job draft within the same run is still refused',
      () {
        // build-macos run 111 has three draft-capable jobs; release-linux's
        // guard must not delete release-macos's draft from the same run.
        final run = runGuard(
          'cross-job',
          'true',
          body: '<!-- release-draft-owner: run/111/job/release-macos -->',
          runId: '111',
          job: 'release-linux',
        );
        expect(run.log.where((l) => l.contains('release delete')), isEmpty);
        expect(run.out, contains('refusing'));
      },
    );

    test(
      'ownership: an unmarked draft (legacy/foreign) is left to the sweeper',
      () {
        final run = runGuard(
          'unmarked',
          'true',
          body: 'Some legacy draft body',
        );
        expect(
          run.log.where((l) => l.contains('release delete')),
          isEmpty,
          reason:
              'no marker, no proof of ownership — only the >24h sweeper may reclaim',
        );
        expect(run.out, contains('refusing'));
      },
    );

    test('ownership: marker match is exact, not prefix/substring', () {
      final run = runGuard(
        'prefix',
        'true',
        body: '<!-- release-draft-owner: run/1111/job/release-macos -->',
        runId: '111',
        job: 'release-macos',
      );
      expect(
        run.log.where((l) => l.contains('release delete')),
        isEmpty,
        reason: 'run id 1111 must not be mistaken for 111',
      );
    });
  });

  // ── E3 — idempotent attach-or-create (review of #294) ───────────────────
  group('release_attach_or_create.sh — race-idempotent create, ownership-stamped', () {
    _AttachOut runAttach(
      String name,
      List<String> viewSeq, {
      bool createFails = false,
    }) {
      final dir = Directory(
        '${_fixtureRoot.path}/attach-$name-${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      final bin = stubGh(dir.path);
      File(
        '${dir.path}/view-seq.txt',
      ).writeAsStringSync('${viewSeq.join('\n')}\n');
      if (createFails) File('${dir.path}/create-fails').writeAsStringSync('');
      File('${dir.path}/a.zip').writeAsStringSync('asset-a');
      File('${dir.path}/b.zip').writeAsStringSync('asset-b');
      File('${dir.path}/release-notes.md').writeAsStringSync('curated notes\n');
      File('${dir.path}/log').writeAsStringSync('');
      final res = Process.runSync(
        'bash',
        [
          File('scripts/release_attach_or_create.sh').absolute.path,
          'v1.2.3',
          'a.zip',
          'b.zip',
        ],
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

    test(
      'release exists → attach: upload every asset --clobber, re-assert --latest, no create',
      () {
        final run = runAttach('exists', ['exists']);
        expect(run.exitCode, 0);
        expect(
          run.log.where((l) => l.contains('release create')),
          isEmpty,
          reason: 'the release already exists — only attach',
        );
        expect(
          run.log,
          contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
        );
        expect(
          run.log,
          contains('release upload v1.2.3 b.zip --clobber --repo OWNER/REPO'),
        );
        expect(
          run.log,
          contains('release edit v1.2.3 --latest --repo OWNER/REPO'),
        );
      },
    );

    test(
      'missing → create: bare-tag title, --latest, assets ride the create, body carries the ownership marker',
      () {
        final run = runAttach('create', ['missing']);
        expect(run.exitCode, 0);
        final createLine = run.log.firstWhere(
          (l) => l.contains('release create'),
        );
        expect(createLine, contains('v1.2.3'));
        expect(createLine, contains('--title v1.2.3'));
        expect(createLine, contains('--latest'));
        expect(createLine, contains('a.zip'));
        expect(createLine, contains('b.zip'));
        expect(run.createdNotes, isNotNull);
        expect(
          run.createdNotes,
          contains('curated notes'),
          reason: 'the prepared notes must stay the body',
        );
        expect(
          run.createdNotes,
          contains('release-draft-owner: run/111/job/release-macos'),
          reason:
              'the draft body must stamp its owner so the guard can verify it',
        );
      },
    );

    test(
      'E3 race: create loses to a concurrent winner → attach idempotently, exit 0',
      () {
        // The view said "missing", another job/run created the release
        // before our create landed. Old code failed here — and the failing
        // job's guard then deleted the WINNER's in-flight draft.
        final run = runAttach('race', ['missing', 'exists'], createFails: true);
        expect(
          run.exitCode,
          0,
          reason: 'a lost create race must not fail the job',
        );
        expect(
          run.log.where((l) => l.contains('release create')).length,
          1,
          reason: 'the create was attempted exactly once',
        );
        expect(
          run.log,
          contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
          reason: 'the loser must attach to the winner\'s release',
        );
        expect(
          run.log,
          contains('release edit v1.2.3 --latest --repo OWNER/REPO'),
        );
        expect(run.out.toLowerCase(), contains('race'));
      },
    );

    test(
      'create fails and nothing exists → loud failure (not a silent || true)',
      () {
        final run = runAttach('genuine-fail', [
          'missing',
          'missing',
        ], createFails: true);
        expect(run.exitCode, isNot(0));
        expect(
          run.log.where((l) => l.contains('release upload')),
          isEmpty,
          reason: 'nothing to attach to — no blind uploads',
        );
      },
    );

    test(
      'workflows route draft-capable creates through the script (one race-safe path)',
      () {
        final script = File('scripts/release_attach_or_create.sh');
        expect(
          script.existsSync(),
          isTrue,
          reason: 'release_attach_or_create.sh must exist',
        );
        for (final wf in [
          '.github/workflows/build-macos.yml',
          '.github/workflows/build-mobile.yml',
        ]) {
          expect(
            read(wf),
            contains('release_attach_or_create.sh'),
            reason:
                '$wf must route its asset-carrying create through the shared script',
          );
          jobsOf(wf).forEach((jobId, job) {
            for (final c in jobCreates(job)) {
              expect(
                c.carriesAssets,
                isFalse,
                reason:
                    '$wf job "$jobId": asset-carrying creates must live in '
                    'release_attach_or_create.sh (race-idempotent, marker-stamped)',
              );
            }
          });
        }
        final creates = extractCreates(
          read('scripts/release_attach_or_create.sh'),
        );
        expect(creates, hasLength(1));
        expect(creates.single.carriesAssets, isTrue);
        expect(creates.single.hasTitle, isTrue);
        expect(creates.single.title, creates.single.tag);
        expect(creates.single.text, contains('--latest'));
      },
    );
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
        expect(
          text,
          isNot(contains('--title "Fa ')),
          reason: 'release titles must be bare vX.Y.Z, not "Fa vX.Y.Z"',
        );
      }
    });

    test('every gh release create is titled and the title equals the tag', () {
      for (final wf in workflows) {
        jobsOf(wf).forEach((jobId, job) {
          for (final c in jobCreates(job)) {
            expect(
              c.hasTitle,
              isTrue,
              reason: '$wf job "$jobId": untitled release create is forbidden',
            );
            expect(
              c.title,
              c.tag,
              reason:
                  '$wf job "$jobId": --title must equal the bare tag (${c.tag})',
            );
          }
        });
      }
      // Direct-push path (gh-1172): auto_release.sh pushes the bump commit
      // straight to main as the fa-release-bot App and creates nothing;
      // tag_release.sh (the release-tag job) owns the single gh release
      // create cut from the pushed bump commit.
      expect(
        extractCreates(read('scripts/auto_release.sh')),
        isEmpty,
        reason:
            'auto_release.sh must not create releases — it only pushes '
            'the bump; tag_release.sh owns the create',
      );
      final tagCreates = extractCreates(read('scripts/tag_release.sh'));
      expect(
        tagCreates,
        hasLength(1),
        reason: 'tag_release.sh is the one race-free release-create path',
      );
      for (final c in tagCreates) {
        expect(c.title, c.tag);
      }
      final attachCreates = extractCreates(
        read('scripts/release_attach_or_create.sh'),
      );
      expect(attachCreates, isNotEmpty);
      for (final c in attachCreates) {
        expect(c.title, c.tag);
      }
    });

    test(
      'lint is real: fixture with "Fa " prefix / missing title is flagged',
      () {
        final bad = extractCreates(r'''
gh release create "$RELEASE_TAG" \
  --title "Fa $RELEASE_TAG" \
  --generate-notes
gh release create "v9.9.9" \
  --generate-notes
''');
        expect(bad.first.title, isNot(bad.first.tag));
        expect(bad.last.hasTitle, isFalse);
      },
    );
  });

  // ── AC5 — generated release notes (UT-notes) ────────────────────────────
  group('AC5 — release_notes.sh', () {
    // release_notes.sh shells out to git — route that subprocess through the
    // resolved real git as well, so a session shim first on PATH can never
    // decide the notes (gh-1172 round-3 suggestion; on the review host a
    // broken shim made these tests read an empty history).
    final gitShimBin = Directory(
      '${_fixtureRoot.path}/gitshim-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    File('${gitShimBin.path}/git').writeAsStringSync(
      '#!/usr/bin/env bash\nexec "${_resolveRealGit()}" "\$@"\n',
    );
    Process.runSync('chmod', ['+x', '${gitShimBin.path}/git']);

    String notes(String cwd, List<String> args) {
      final r = Process.runSync(
        'bash',
        [File('scripts/release_notes.sh').absolute.path, ...args],
        workingDirectory: cwd,
        environment: {
          'PATH': '${gitShimBin.path}:${Platform.environment['PATH']}',
        },
      );
      return r.stdout.toString();
    }

    test('CHANGELOG section for the version wins', () {
      final repo = fixtureRepo(
        'notes-changelog',
        ['feat: real work'],
        ['v1.2.2'],
        '''
# Changelog

## 1.2.3

- Curated note alpha
- Curated note beta

## 1.2.2

- Older
''',
      );
      final out = notes(repo, ['1.2.3']);
      expect(out, contains('Curated note alpha'));
      expect(out, contains('Curated note beta'));
      expect(out, isNot(contains('Older')));
      expect(out, isNot(contains('feat: real work')));
    });

    test('fallback: conventional commits since the previous tag, grouped', () {
      final repo =
          fixtureRepo('notes-group', ['chore: seed'], ['v2.0.0'], null, [
            'feat(cli): shiny new thing',
            'fix: crash on start',
            'chore: deps bump',
            'docs: readme',
          ]);
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
      final repo = fixtureRepo(
        'notes-empty',
        ['feat: only old work'],
        ['v3.0.0'],
      );
      final out = notes(repo, ['3.0.1']);
      expect(out.toLowerCase(), contains('no changes'));
      expect(out.trim(), isNot(''));
    });

    test('E4: 200 commits -> capped at 50 with an "and N more" line', () {
      final repo = fixtureRepo('notes-cap', ['chore: seed'], ['v4.0.0'], null, [
        for (var i = 1; i <= 200; i++) 'feat: change $i',
      ]);
      final out = notes(repo, ['4.0.1']);
      final bullets = RegExp(r'^- ', multiLine: true).allMatches(out).length;
      expect(bullets, lessThanOrEqualTo(50));
      expect(out, contains('and 150 more'));
      expect(
        out,
        contains('change 200'),
        reason: 'newest commits stay, oldest drop',
      );
    });
  });

  // ── AC2 — daily draft sweeper (IT-sweep) ────────────────────────────────
  group('AC2 — sweep_stale_drafts.sh', () {
    final oldDate = '2020-01-01T00:00:00Z';
    String releasesJson(List<Map<String, Object>> drafts) => jsonEncode(
      drafts
          .map(
            (d) => {
              'tag_name': d['tag'],
              'id': d['id'],
              'draft': true,
              'created_at': d['created'],
              'author': {'login': d['author'], 'type': d['type']},
            },
          )
          .toList(),
    );

    test(
      'old bot draft deleted, fresh untouched, human kept; issue filed naming the run',
      () {
        final freshDate = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .toIso8601String()
            .substring(0, 19);
        final run = runSweeper('one', {
          'releases.json': releasesJson([
            {
              'tag': 'v0.1.190',
              'id': 111,
              'created': oldDate,
              'author': 'github-actions[bot]',
              'type': 'Bot',
            },
            {
              'tag': 'v9.9.9',
              'id': 222,
              'created': '${freshDate}Z',
              'author': 'github-actions[bot]',
              'type': 'Bot',
            },
            {
              'tag': 'v0.2.0',
              'id': 333,
              'created': oldDate,
              'author': 'somehuman',
              'type': 'User',
            },
          ]),
          'issues.tsv': '',
          'runs.tsv': 'https://github.com/OWNER/REPO/actions/runs/9999\n',
        });
        expect(
          run.log,
          contains('api -X DELETE repos/OWNER/REPO/releases/111'),
          reason: 'stale bot draft must be deleted by release id',
        );
        expect(
          run.log,
          isNot(contains('releases/222')),
          reason: 'fresh (<24h) draft must be untouched',
        );
        expect(
          run.log,
          isNot(contains('releases/333')),
          reason: 'human draft must never be deleted (E1)',
        );
        expect(
          run.log,
          anyElement(contains('issue create')),
          reason: 'dedup issue must be filed',
        );
        expect(
          run.body,
          isNotNull,
          reason: 'an issue body must have been filed',
        );
        expect(
          run.body,
          contains('v0.1.190'),
          reason: 'deleted draft must be named in the issue',
        );
        expect(
          run.body,
          contains('actions/runs/9999'),
          reason: 'the creating run must be named in the issue',
        );
        expect(
          run.body,
          contains('v0.2.0'),
          reason: 'human draft must be listed in the issue',
        );
        expect(
          run.stdoutText,
          contains('v0.1.190'),
          reason: 'deleted draft must be named in the report',
        );
      },
    );

    test(
      'idempotent re-run: comments on the open issue instead of duplicating',
      () {
        final run = runSweeper('two', {
          'releases.json': releasesJson([
            {
              'tag': 'v0.1.190',
              'id': 111,
              'created': oldDate,
              'author': 'github-actions[bot]',
              'type': 'Bot',
            },
          ]),
          'issues.tsv': '12\t[daily-publish] stale release drafts swept\n',
          'runs.tsv': '',
        });
        final creates = run.log.where((l) => l.contains('issue create')).length;
        final comments = run.log
            .where((l) => l.contains('issue comment'))
            .length;
        expect(
          creates,
          0,
          reason: 'open issue exists — no duplicate may be filed',
        );
        expect(comments, 1, reason: 'the existing issue gets a fresh comment');
        expect(
          run.log,
          contains('api -X DELETE repos/OWNER/REPO/releases/111'),
        );
      },
    );

    test(
      'clean sweep auto-closes the open issue (self-closing convention)',
      () {
        final run = runSweeper('three', {
          'releases.json': '[]',
          'issues.tsv': '12\t[daily-publish] stale release drafts swept\n',
          'runs.tsv': '',
        });
        expect(run.log, anyElement(contains('issue close')));
        expect(run.log.where((l) => l.contains('-X DELETE')), isEmpty);
        expect(run.log.where((l) => l.contains('issue create')), isEmpty);
      },
    );
  });

  // ── AC4 — truthful Latest (IT-latest) ───────────────────────────────────
  group('AC4 — latest is explicit on publishes, impossible for drafts', () {
    for (final wf in [
      '.github/workflows/build-macos.yml',
      '.github/workflows/build-mobile.yml',
    ]) {
      test(
        '$wf: publish paths carry --latest (create) or edit --latest (attach to existing)',
        () {
          // Draft-capable creates live in release_attach_or_create.sh; the
          // workflow must route through it and not inline a parallel path.
          expect(read(wf), contains('release_attach_or_create.sh'));
          final script = read('scripts/release_attach_or_create.sh');
          expect(
            script,
            contains('--latest'),
            reason: 'release create must mark latest explicitly',
          );
          expect(
            script,
            contains('gh release edit'),
            reason: 'attach-to-existing path must re-assert latest',
          );
          expect(extractCreates(script).single.text, contains('--latest'));
          jobsOf(wf).forEach((jobId, job) {
            for (final c in jobCreates(job)) {
              if (c.carriesAssets) {
                expect(
                  c.text,
                  contains('--latest'),
                  reason:
                      '$wf job "$jobId": asset-carrying create must pass --latest',
                );
              }
            }
          });
        },
      );
    }

    test('guards and sweeper never touch the latest badge', () {
      for (final script in [
        'scripts/release_draft_guard.sh',
        'scripts/sweep_stale_drafts.sh',
      ]) {
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

    test(
      'release flow is direct-push: auto_release.sh pushes the bump to main as the App, tag_release.sh cuts tag+release',
      () {
        // gh-1172: the fa-release-bot GitHub App is the only bypass actor on
        // the main ruleset, so the bump commit pushes directly (the 2026-09-29
        // PR stopgap is retired — it burned a full CI queue cycle + machine
        // review round per chore bump). The release-tag job cuts the tag +
        // GitHub Release from the pushed bump commit; the tag rides the same
        // App token so the tag-scoped binaries/publish jobs fire.
        final auto = read('scripts/auto_release.sh');
        expect(
          auto,
          contains('git push origin HEAD:main'),
          reason: 'the bump pushes straight to main (App bypass) — no PR',
        );
        expect(
          auto,
          isNot(contains('gh pr create')),
          reason: 'release PRs are retired (gh-1172)',
        );
        expect(
          auto,
          isNot(contains('chore/release-v')),
          reason: 'no release branch is created anymore',
        );
        expect(
          auto,
          isNot(contains('git tag -a')),
          reason: 'tagging moved to tag_release.sh (tag rides the App token)',
        );
        expect(
          auto,
          contains('RELEASE_DRY_RUN'),
          reason: 'AC1: the dry-run switch must gate the push',
        );
        final tagScript = read('scripts/tag_release.sh');
        expect(tagScript, contains(r'git tag -a "$tag"'));
        expect(tagScript, contains(r'git push origin "$tag"'));
      },
    );

    test(
      'release jobs authenticate via the fa-release-bot App token (mint step + checkout + GH_TOKEN)',
      () {
        // gh-1172 fix-contract item 1: both release jobs mint a job-scoped
        // installation token via actions/create-github-app-token from
        // RELEASE_APP_ID / RELEASE_APP_PRIVATE_KEY and use it for checkout
        // (push auth) — and release-tag additionally exports it as GH_TOKEN
        // for `gh release create` (the #1093 BLOCK finding: without an
        // explicit token the create was a guaranteed silent no-op).
        final ci = jobsOf('.github/workflows/ci.yml');
        for (final jobName in ['release', 'release-tag']) {
          final job = ci[jobName] as YamlMap;
          final steps = job['steps'] as YamlList;
          final mint = steps
              .map((s) => s as YamlMap)
              .firstWhere(
                (s) =>
                    s['uses']?.toString().startsWith(
                      'actions/create-github-app-token@',
                    ) ??
                    false,
                orElse: () => throw TestFailure(
                  '$jobName must mint the fa-release-bot token via '
                  'actions/create-github-app-token',
                ),
              );
          expect(
            mint['id']?.toString(),
            'app-token',
            reason:
                '$jobName token step id must be app-token for the wiring below',
          );
          expect(
            mint['with']['app-id']?.toString(),
            equals(r'${{ secrets.RELEASE_APP_ID }}'),
          );
          expect(
            mint['with']['private-key']?.toString(),
            equals(r'${{ secrets.RELEASE_APP_PRIVATE_KEY }}'),
          );
          expect(
            mint['with']['permissions']?.toString(),
            'contents:write',
            reason:
                '$jobName mint must scope the token to contents:write — the App '
                'is the ruleset bypass actor, so an unscoped token carries every '
                'permission the installation has (gh-1172 round-2 review, least privilege)',
          );
          final checkout = steps
              .map((s) => s as YamlMap)
              .firstWhere(
                (s) =>
                    s['uses']?.toString().startsWith('actions/checkout') ??
                    false,
              );
          expect(
            checkout['with']['token']?.toString(),
            jobName == 'release'
                ? equals(
                    r'${{ steps.app-token.outputs.token || github.token }}',
                  )
                : equals(r'${{ steps.app-token.outputs.token }}'),
            reason:
                '$jobName checkout must ride the App token — GITHUB_TOKEN '
                'tags/pushes never fire tag-scoped jobs (release additionally '
                'falls back to github.token when the dry-run gate skips the mint)',
          );
        }
        final tagSteps = ci['release-tag']['steps'] as YamlList;
        final tagStep = tagSteps
            .map((s) => s as YamlMap)
            .firstWhere(
              (s) => s['run']?.toString().contains('tag_release.sh') ?? false,
            );
        expect(
          (tagStep['env'] as YamlMap)['GH_TOKEN']?.toString(),
          equals(r'${{ steps.app-token.outputs.token }}'),
          reason: 'gh release create needs GH_TOKEN=App token (#1093 review)',
        );
      },
    );
    test(
      'dry-run dispatch carries no bypass credential (mint gated, checkout falls back, job reads)',
      () {
        // gh-1172 round-3 BLOCK: the AC1 dry-run arm fires on ANY ref, so the
        // dispatched (PR-head) auto_release.sh must never hold the bypass App
        // token — "never pushes" would otherwise be enforced only by the very
        // script under test (a PR can edit it to ignore the flag, or spend
        // the checkout-stored token directly: push HEAD to main, push a v*
        // tag → the OIDC publish job → attacker-controlled pub.dev package).
        // A dry-run needs no push credential at all: the mint is gated off on
        // dry-run, checkout falls back to the plain GITHUB_TOKEN, and the job
        // token itself stays read-only so no write-capable second credential
        // exists on an untrusted ref.
        final ci = jobsOf('.github/workflows/ci.yml');
        final job = ci['release'] as YamlMap;
        final steps = job['steps'] as YamlList;
        final mint = steps
            .map((s) => s as YamlMap)
            .firstWhere(
              (s) =>
                  s['uses']?.toString().startsWith(
                    'actions/create-github-app-token@',
                  ) ??
                  false,
            );
        expect(
          mint['if']?.toString(),
          equals('inputs.releaseDryRun != true'),
          reason:
              'dry-run never pushes — mint NO bypass credential on untrusted '
              'refs (the real arms — push, schedule, releaseDispatch — all see '
              'a non-true releaseDryRun and still mint)',
        );
        final checkout = steps
            .map((s) => s as YamlMap)
            .firstWhere(
              (s) =>
                  s['uses']?.toString().startsWith('actions/checkout') ?? false,
            );
        expect(
          checkout['with']['token']?.toString(),
          equals(r'${{ steps.app-token.outputs.token || github.token }}'),
          reason:
              'with the mint skipped, checkout must fall back to the plain '
              'GITHUB_TOKEN (a skipped step emits empty outputs, falsy in GHA)',
        );
        expect(
          (job['permissions'] as YamlMap)['contents'].toString(),
          'read',
          reason:
              'the push rides the checkout App token exclusively — the job '
              'GITHUB_TOKEN never needs write, so a dry-run dispatch of a PR '
              'head holds no write-capable credential at all',
        );
      },
    );

    test(
      'auto_release.sh untagged guard keys on pubspec version with a wedge escape',
      () {
        // IMPORTANT finding on PR #1093 (2026-09-30): subject-keying wedged
        // auto-release forever when release-tag missed (any non-squash or
        // interleaved merge changes the subject, not the version). Keyed on
        // the pubspec version with a 1h escape hatch instead.
        final auto = read('scripts/auto_release.sh');
        expect(
          auto,
          contains(
            r'''head_version=$(git show origin/main:pubspec.yaml | sed -n 's/^version: //p')''',
          ),
          reason: 'the untagged guard must key on the pubspec version',
        );
        expect(
          auto,
          contains('-lt 3600'),
          reason:
              'after 1h untagged the guard must let the next bump absorb the range (no indefinite wedge)',
        );
      },
    );

    test(
      'daily-publish.yml carries the sweeper job, ungated by leg results',
      () {
        final jobs = jobsOf('.github/workflows/daily-publish.yml');
        expect(jobs.keys, contains('sweep-drafts'));
        final sweep = jobs['sweep-drafts'] as YamlMap;
        expect(
          sweep['if'].toString(),
          contains('always()'),
          reason: 'hygiene must run even when legs skip',
        );
        expect(
          (sweep['permissions'] as YamlMap).containsKey('contents'),
          isTrue,
        );
        expect(sweep.toString(), contains('sweep_stale_drafts.sh'));
      },
    );

    test(
      'sweep-drafts grants actions:read — gh run list 403s without it (review of #294)',
      () {
        // The sweeper names each swept draft's creating run via `gh run list`;
        // without actions:read GitHub answers 403 and the script's || true
        // hides it, silently degrading every sweep issue to "no run on ref".
        // The stub enforces the YAML-declared scopes on every AC2 run above;
        // this pins the grant explicitly.
        final perms =
            jobsOf(
                  '.github/workflows/daily-publish.yml',
                )['sweep-drafts']['permissions']
                as YamlMap;
        expect(
          perms.containsKey('actions'),
          isTrue,
          reason: 'sweep-drafts must grant actions:read for gh run list',
        );
        expect(perms['actions'].toString(), 'read');
        expect(
          sweepPermissions().split(RegExp(r'\s+')),
          contains('actions'),
          reason: 'the stub-enforced scope list must include actions',
        );
      },
    );
    test(
      'release job never fires from a bare workflow_dispatch (SM validation dispatches pass no inputs)',
      () {
        // gh-1172 round-2 BLOCK: ci.yml is the repo's dispatch-only CI —
        // machine-sm.yml -> smAgent.js dispatchCiWorkflow() runs
        // `gh workflow run ci.yml --ref <pr-branch>` with NO inputs, and
        // sm-kicker / machine-merge dispatch it the same way. An ungated
        // `|| github.event_name == 'workflow_dispatch'` arm makes every green
        // validation dispatch execute the dispatched (PR-head) ref's
        // auto_release.sh with the bypass App's push credentials — an
        // accidental release and a privilege-escalation path in one. Every
        // dispatch arm must be conjunctive with an explicit inputs.release*
        // opt-in, and the real-push arm must additionally be ref-restricted
        // to main.
        final ci = jobsOf('.github/workflows/ci.yml');
        final releaseIf = (ci['release'] as YamlMap)['if'].toString();

        // Dispatch arms are the parenthesized `(...)` groups whose condition
        // STARTS with the workflow_dispatch check — balanced-paren scan so a
        // nested `chore(release):` string can never confuse the split.
        const wd = "github.event_name == 'workflow_dispatch'";
        final dispatchArms = <String>[];
        for (var i = 0; i < releaseIf.length; i++) {
          if (releaseIf[i] != '(') continue;
          var depth = 0;
          for (var j = i; j < releaseIf.length; j++) {
            if (releaseIf[j] == '(') {
              depth++;
            } else if (releaseIf[j] == ')') {
              depth--;
              if (depth == 0) {
                final inner = releaseIf.substring(i + 1, j).trim();
                if (inner.startsWith(wd)) dispatchArms.add(inner);
                break;
              }
            }
          }
        }
        // The invariant itself: EVERY occurrence of the workflow_dispatch
        // check must live inside a gated arm. A bare `|| workflow_dispatch`
        // arm shows up as an occurrence no arm accounts for.
        final armOccurrences = dispatchArms.fold<int>(
          0,
          (n, a) => n + a.split(wd).length - 1,
        );
        expect(
          releaseIf.split(wd).length - 1,
          armOccurrences,
          reason:
              'a bare `|| github.event_name == \'workflow_dispatch\'` arm must '
              'never return — SM validation dispatches (machine-sm.yml -> '
              'smAgent.js dispatchCiWorkflow, sm-kicker, machine-merge) pass NO '
              'inputs, so an ungated arm auto-releases from any dispatched ref',
        );
        expect(
          dispatchArms.length,
          2,
          reason:
              'exactly two dispatch arms: the AC1 dry-run (releaseDryRun) and '
              'the manual catch-up release (releaseDispatch on main)',
        );
        for (final arm in dispatchArms) {
          expect(
            RegExp(r"inputs\.release[A-Za-z]*\s*==\s*true").hasMatch(arm),
            isTrue,
            reason:
                'every workflow_dispatch arm must be conjunctive with an explicit '
                'inputs.release* opt-in — a bare dispatch (no inputs) arms nothing; '
                'got: $arm',
          );
          if (!arm.contains('inputs.releaseDryRun')) {
            expect(
              arm.contains("github.ref == 'refs/heads/main'"),
              isTrue,
              reason:
                  'the real-push dispatch arm must be ref-restricted to main — a '
                  'PR-head dispatch must never reach the bump push; got: $arm',
            );
            expect(
              arm.contains('inputs.releaseDispatch'),
              isTrue,
              reason:
                  'the real-push dispatch arm must require the explicit '
                  'releaseDispatch opt-in; got: $arm',
            );
          }
        }

        // The typed opt-in input must exist (boolean, default false) so the
        // gate above is satisfiable without accidents.
        final ciRaw = read('.github/workflows/ci.yml');
        expect(
          RegExp(
            r'^\s*releaseDispatch:\n\s+description:[^\n]*\n\s+required: false\n\s+type: boolean\n\s+default: false$',
            multiLine: true,
          ).hasMatch(ciRaw),
          isTrue,
          reason:
              'releaseDispatch must be a typed boolean input defaulting to false',
        );
        // The dry-run env must normalize through == 'true' — the bare
        // `inputs.releaseDryRun || '0'` fallback is dead code (a typed boolean
        // input always arrives as 'true'/'false', and 'false' is truthy in
        // GitHub expressions), so it must never return (gh-1172 round-2 thread 3).
        expect(
          ciRaw,
          isNot(contains('inputs.releaseDryRun ||')),
          reason:
              "the dead `inputs.releaseDryRun || '0'` fallback must not return",
        );
        final steps = (ci['release'] as YamlMap)['steps'] as YamlList;
        final bumpStep = steps
            .map((s) => s as YamlMap)
            .firstWhere(
              (s) => s['run']?.toString().contains('auto_release.sh') ?? false,
            );
        expect(
          (bumpStep['env'] as YamlMap)['RELEASE_DRY_RUN']?.toString(),
          equals(
            r"${{ github.event.inputs.releaseDryRun == 'true' && '1' || '0' }}",
          ),
          reason:
              "RELEASE_DRY_RUN must normalize via == 'true' to a literal 1/0",
        );
      },
    );

    test(
      'release-tag contract comment documents the direct-push mechanism, not the retired PR path',
      () {
        // gh-1172 round-2 IMPORTANT: the block comment above `release-tag:`
        // still described the retired release-PR mechanism (merged release PR,
        // RELEASE_PAT, "bump PR job") and contradicted the job it documents.
        // This repo treats CI comments as binding contract docs — pin the
        // rewrite so the retired text cannot return.
        final lines = read('.github/workflows/ci.yml').split('\n');
        final jobLine = lines.indexWhere((l) => l == '  release-tag:');
        expect(jobLine, greaterThan(0), reason: 'release-tag job must exist');
        var start = jobLine - 1;
        while (start >= 0 && lines[start].trimLeft().startsWith('#')) {
          start--;
        }
        final comment = lines.sublist(start + 1, jobLine).join('\n');
        for (final retired in [
          'RELEASE_PAT',
          'merged release PR',
          'bump PR job',
          'rejects direct bot pushes',
        ]) {
          expect(
            comment,
            isNot(contains(retired)),
            reason:
                'retired PR-path text "$retired" must not return above release-tag',
          );
        }
        expect(
          comment,
          contains('fa-release-bot'),
          reason: 'the comment must name the App the tag rides',
        );
        expect(
          comment,
          contains('direct push'),
          reason: 'the comment must describe the direct-push contract',
        );
      },
    );
  });

  // ── gh-1172 — direct-push behavioral coverage ────────────────────────────
  // Round-2 review: the PR deleted the gh-1134 PR-path sandbox (bare origin +
  // stubbed gh) together with the code it exercised — correct — but shipped
  // the new direct-push path with string-assertions only. The riskiest logic
  // gets the same treatment here: a bare origin IS a real git remote, so
  // `git push origin HEAD:main` genuinely executes; a git shim races the push
  // by advancing origin/main from a second clone between the script's fetch
  // and its push (E1).
  group('gh-1172 — direct-push behavioral coverage (dry-run, coalesce, E1 race)', () {
    test(
      'AC1 — dry-run commits the bump locally, exits before the push, origin/main unchanged',
      () {
        final r = runAutoReleaseDirect('dry-run', dryRun: true);
        expect(r.exitCode, 0, reason: r.output);
        expect(r.output, contains('DRY-RUN: would push'));
        expect(r.output, contains('v0.1.496'));
        expect(r.output, contains('would then cut annotated tag v0.1.496'));
        expect(
          r.originHeadAfter,
          r.originHeadBefore,
          reason: 'AC1: a dry run must not land anything on origin/main',
        );
        expect(
          r.seedLastSubject(),
          'chore(release): v0.1.496',
          reason: 'the would-be commit+tag are computed and committed locally',
        );
      },
    );

    test('coalesce guard — a tag younger than 2h skips the run entirely', () {
      final r = runAutoReleaseDirect('coalesce', tagAgeHours: 1);
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('coalesced'));
      expect(
        r.originHeadAfter,
        r.originHeadBefore,
        reason: 'no bump may land inside the coalesce window',
      );
      expect(r.originSubjects(1), isNot(contains('chore(release): v0.1.496')));
    });

    test(
      'E1 race — a main that advanced mid-run rejects the push; the bump recomputes on the fresh head and lands',
      () {
        final r = runAutoReleaseDirect('race-retry', raceMode: 'once');
        expect(r.exitCode, 0, reason: r.output);
        expect(r.output, contains('Main push raced, retrying'));
        final subjects = r.originSubjects(4);
        expect(
          subjects.where((s) => s.startsWith('chore(release):')),
          hasLength(1),
          reason:
              'exactly one bump lands — the raced attempt is discarded, not stacked',
        );
        expect(subjects.first, 'chore(release): v0.1.496');
        expect(
          subjects,
          contains('raced commit'),
          reason:
              'the bump must sit on top of the raced main — recomputed, never a blind push',
        );
        expect(
          r.originHeadAuthor(),
          'fa-release-bot[bot] <fa-release-bot[bot]@users.noreply.github.com>',
          reason:
              'the bump commit is authored by the App (auditability contract)',
        );
      },
    );

    test(
      'E1 exhaustion — a main that advances on every attempt exits 1 after 3 tries without landing a bump',
      () {
        final r = runAutoReleaseDirect('race-exhaust', raceMode: 'always');
        expect(r.exitCode, 1, reason: 'exhaustion must fail loud: ${r.output}');
        expect(r.output, contains('failed after 3 attempts'));
        expect(
          r.originSubjects(6).where((s) => s.startsWith('chore(release):')),
          isEmpty,
          reason: 'a raced-out run must never land a bump',
        );
        expect(r.originSubjects(6), contains('raced commit'));
      },
    );

    test(
      "CHANGELOG '## Unreleased' dedupe — a second release never stacks duplicate sections",
      () {
        // Round-4 review: the dedupe side-fix (append a fresh empty
        // Unreleased exactly once) shipped untested. Drive TWO real releases
        // through the sandbox: after the first push, play the release-tag
        // job catching up — backdate the landed bump (so the 2h coalesce
        // window and the untagged guard both open), tag it, queue new work —
        // then release again. Both runs regenerate CHANGELOG.md, which is
        // where a naive append would stack a second '## Unreleased'.
        final r1 = runAutoReleaseDirect('dedupe');
        expect(r1.exitCode, 0, reason: r1.output);
        expect(r1.originSubjects(1).single, 'chore(release): v0.1.496');
        expect(
          '## Unreleased'.allMatches(r1.originFile('CHANGELOG.md')),
          hasLength(1),
          reason:
              'one release from a changelog WITH an Unreleased section '
              'must end with exactly one',
        );

        // release-tag catch-up: tag the bump (commit backdated 3h so the
        // coalesce guard opens), then queue the next pending work.
        final backdate = {
          'GIT_COMMITTER_DATE':
              (DateTime.now()
                          .subtract(const Duration(hours: 3))
                          .millisecondsSinceEpoch ~/
                      1000)
                  .toString(),
        };
        void git(List<String> args, {Map<String, String> env = const {}}) {
          final res = Process.runSync(
            r1._gitBin,
            args,
            workingDirectory: r1._seedPath,
            environment: env,
            includeParentEnvironment: true,
          );
          expect(res.exitCode, 0, reason: 'dedupe git $args: ${res.stderr}');
        }

        git(['commit', '-q', '--amend', '--no-edit'], env: backdate);
        git(['push', '-q', '-f', 'origin', 'HEAD:main']);
        git(['tag', 'v0.1.496'], env: backdate);
        git(['push', '-q', 'origin', 'v0.1.496']);
        File('${r1._seedPath}/README.md').writeAsStringSync('more work\n');
        git(['add', '-A']);
        git(['commit', '-q', '-m', 'more pending work']);
        git(['push', '-q', 'origin', 'HEAD:main']);

        final r2 = r1.rerun();
        expect(r2.exitCode, 0, reason: r2.output);
        expect(r2.originSubjects(1).single, 'chore(release): v0.1.497');
        final changelog = r2.originFile('CHANGELOG.md');
        expect(changelog, contains('## 0.1.497'));
        expect(changelog, contains('## 0.1.496'));
        expect(
          '## Unreleased'.allMatches(changelog),
          hasLength(1),
          reason: 'repeated runs must not stack duplicate Unreleased sections',
        );
      },
    );

    test(
      'suite git resolution is host-independent — no session shim decides fixture behavior',
      () {
        // gh-1172 round-3 suggestion: the pre-existing fixture helpers called
        // bare `Process.runSync('git', ...)`, inheriting whatever git sat first
        // on PATH — on shim-hostile hosts that was a broken git-push-guard copy
        // and the AC5 notes tests failed with "No changes since the previous
        // release." All fixture/notes git traffic now routes through the
        // resolved real binary; pin its invariants.
        final git = _resolveRealGit();
        expect(File(git).existsSync(), isTrue, reason: '$git must exist');
        expect(
          git.endsWith('git-push-guard.sh'),
          isFalse,
          reason: 'the resolved git must never be an agent-session guard shim',
        );
        final r = Process.runSync(git, ['--version']);
        expect(r.exitCode, 0, reason: r.stderr.toString());
        expect(r.stdout.toString(), startsWith('git version'));
      },
    );
  });

  // ── gh-1299 — release lockfile gates (NG1 refresh, NG2 tag smoke) ──────
  // v1.0.515: auto_release.sh bumped both pubspecs but committed only
  // pubspec.yaml/flutter_app/pubspec.yaml/CHANGELOG.md — the committed
  // flutter_app/pubspec.lock kept pinning `flutter_agent_harness 1.0.514
  // from path ..` and #1268's repo-wide `pub get --enforce-lockfile` red
  // all 13 main legs. Owner directive (same class as #1265/#1296): a
  // release that leaves the tree --enforce-lockfile-dirty is a FAILED
  // release, and the tag/publish path must smoke the enforce-lockfile gate
  // on the release commit BEFORE tagging.
  group('gh-1299 — release lockfile gates (NG1 refresh, NG2 tag smoke)', () {
    test(
      'NG1 — the bump commit carries flutter_app/pubspec.lock refreshed to the NEW version',
      () {
        final r = runAutoReleaseDirect('lockfile-refresh');
        expect(r.exitCode, 0, reason: r.output);
        expect(r.originSubjects(1).single, 'chore(release): v0.1.496');
        final lock = r.originFile('flutter_app/pubspec.lock');
        expect(
          lock,
          contains('version: "0.1.496"'),
          reason:
              'the shipped lockfile must pin the NEW parent version — '
              'a stale pin is exactly the v1.0.515 13-leg red',
        );
        expect(
          lock,
          isNot(contains('version: "0.1.495"')),
          reason: 'the pre-bump pin must be gone from the release commit',
        );
      },
    );

    test(
      'NG1 — a failed `flutter pub get` aborts the release BEFORE the push (origin/main unchanged)',
      () {
        final r = runAutoReleaseDirect('pubget-fail', flutterFails: true);
        expect(
          r.exitCode,
          1,
          reason:
              'a release whose lockfile refresh fails must fail loud: '
              '${r.output}',
        );
        expect(r.output, contains('flutter pub get failed'));
        expect(
          r.originHeadAfter,
          r.originHeadBefore,
          reason: 'never push a bump that leaves pubspec.lock stale',
        );
        expect(
          r.originSubjects(1),
          isNot(contains('chore(release): v0.1.496')),
        );
      },
    );

    test(
      'NG1 — a committed lockfile still dirty after the refresh aborts the release (pod-install-only drift)',
      () {
        final r = runAutoReleaseDirect('dirty-pod', flutterDirty: true);
        expect(r.exitCode, 1, reason: r.output);
        expect(r.output, contains('still dirty'));
        expect(
          r.originHeadAfter,
          r.originHeadBefore,
          reason:
              'a release that leaves the tree --enforce-lockfile-dirty '
              'is a failed release (gh-1299 NG1)',
        );
        expect(
          r.originSubjects(1),
          isNot(contains('chore(release): v0.1.496')),
        );
      },
    );

    test(
      'NG1 — an EMPTY lockfile inventory (broken `check_lockfiles.sh list`) refuses to release — the dirty gate must never silently no-op',
      () {
        // PR #1304 rework threads 1+5: the inventory is consumed inside a
        // process substitution whose exit status `set -euo pipefail` cannot
        // observe — a `check_lockfiles.sh list` that fails or prints nothing
        // left `lockfiles` empty and degenerated `git status --porcelain --`
        // into an unrestricted whole-tree scan (clean right after the
        // commit), shipping releases with zero lockfile protection. The
        // precondition must be explicit: no inventory, no release.
        final r = runAutoReleaseDirect(
          'empty-inventory',
          brokenInventory: true,
        );
        expect(r.exitCode, 1, reason: r.output);
        expect(r.output, contains('lockfile inventory is EMPTY'));
        expect(
          r.originHeadAfter,
          r.originHeadBefore,
          reason:
              'refusing to release without the dirty-tree gate (gh-1299 NG1)',
        );
        expect(
          r.originSubjects(1),
          isNot(contains('chore(release): v0.1.496')),
        );
      },
    );

    test(
      'NG1 — auto_release.sh refreshes the lockfile, stages it IN the bump commit, then runs the dirty gate',
      () {
        final script = read('scripts/auto_release.sh');
        expect(
          script,
          contains('flutter pub get'),
          reason: 'the bump must regenerate flutter_app/pubspec.lock (gh-1299)',
        );
        final refresh = script.indexOf('flutter pub get');
        final add = script.indexOf('git add');
        expect(refresh, greaterThan(0));
        expect(
          add,
          greaterThan(refresh),
          reason: 'the regenerated lockfile is staged after the refresh',
        );
        expect(
          RegExp(r'git add[^\n]*flutter_app/pubspec\.lock').hasMatch(script),
          isTrue,
          reason: 'the lockfile rides the SAME commit as the bump (NG1)',
        );
        final dirtyGate = script.indexOf('check_lockfiles.sh list');
        expect(
          dirtyGate,
          greaterThan(add),
          reason:
              'the dirty-tree gate consumes the ONE inventory ('
              'scripts/check_lockfiles.sh) after staging — never a '
              'duplicated list',
        );
      },
    );

    test(
      'NG2/AC3 — tag_release.sh asserts --enforce-lockfile on the bump tree BEFORE tagging/publishing',
      () {
        final script = read('scripts/tag_release.sh');
        final smoke = script.indexOf('pub get --enforce-lockfile');
        expect(
          smoke,
          greaterThan(0),
          reason: 'the post-release smoke must exist',
        );
        final tag = script.indexOf('git tag -a');
        final create = script.indexOf('gh release create');
        expect(
          tag,
          greaterThan(smoke),
          reason: 'a red enforce-lockfile bump must never be tagged',
        );
        expect(
          create,
          greaterThan(smoke),
          reason: '... nor published (the tag fires the publish jobs)',
        );
        expect(
          script,
          contains('refusing to tag'),
          reason: 'the refusal is loud, never a silent skip',
        );
      },
    );

    test(
      'AC3 — the release workflow jobs that run the gates get flutter on PATH',
      () {
        final jobs = jobsOf('.github/workflows/ci.yml');
        for (final name in ['release', 'release-tag']) {
          final steps = jobs[name]['steps'] as YamlList;
          final flutterSteps = steps
              .whereType<YamlMap>()
              .where(
                (s) => (s['uses']?.toString() ?? '').startsWith(
                  'subosito/flutter-action',
                ),
              )
              .toList();
          expect(
            flutterSteps,
            isNotEmpty,
            reason:
                'job $name runs a gh-1299 lockfile gate — it needs flutter '
                'installed (hosted stable, same pin as every other leg)',
          );
          // PR #1304 rework thread 8: these jobs AUTHOR flutter_app/pubspec.lock
          // for every future release — the authoring SDK must be pinned to the
          // same 3.47.x the consuming (`--enforce-lockfile`) build legs pin,
          // closing the author/consumer SDK drift class for one line per step.
          for (final s in flutterSteps) {
            expect(
              (s['with'] as YamlMap?)?['flutter-version']?.toString(),
              '3.47.x',
              reason:
                  'job $name authors flutter_app/pubspec.lock — its SDK must '
                  'be pinned to the same 3.47.x the consuming build legs use',
            );
          }
        }
      },
    );
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
    test(
      'every third-party action is pinned at exactly ONE full SHA repo-wide',
      () {
        final byAction = usesByAction();
        expect(byAction, isNotEmpty);
        final drifted = <String>[];
        byAction.forEach((action, pins) {
          if (pins.length > 1) drifted.add('$action: ${pins.join(', ')}');
        });
        expect(
          drifted,
          isEmpty,
          reason:
              'a second pin for the same action means one workflow was '
              'left behind on an old version — exactly how the pty legs '
              'wedge happened (their v4-era upload-artifact uploads failed '
              'the gate\'s v8 download digest validation)',
        );
      },
    );

    test(
      'upload-artifact is pinned to the current digest-validating line everywhere',
      () {
        expect(
          usesByAction()['actions/upload-artifact'],
          {'043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'},
          reason:
              'pty-coverage-gate downloads with download-artifact v8 '
              '(strict SHA256 digest validation); every upload must come '
              'from the same current action line or the download '
              'digest-mismatches and the shard merge loses a report',
        );
      },
    );

    test(
      'pty shard coverage artifacts: upload name, download pattern and count check agree',
      () {
        // gh-1005: the consolidated leg is pty-integration-linux (the former
        // mac `pty-integration` shards merged in; there is no mac leg anymore).
        final jobs = jobsOf('.github/workflows/ci.yml');
        final integration = jobs['pty-integration-linux'] as YamlMap;
        final gate = jobs['pty-coverage-gate'] as YamlMap;

        // The matrix width is the source of truth for the expected report count.
        final shardCount =
            ((integration['strategy'] as YamlMap)['matrix'] as YamlMap)['shard']
                as YamlList;
        expect(
          shardCount.length,
          3,
          reason: 'the leg is documented as 3 shards',
        );

        // Exactly one coverage upload per shard leg, named pty-coverage-shard-N.
        // gh-1412: the gh-1412 retry steps (same artifact name, `if` keyed on
        // the primary upload's failed outcome) re-upload the SAME single
        // artifact — they must not count as a second coverage upload here.
        final uploadNames = <String>[];
        for (final step in integration['steps'] as YamlList) {
          if (step is YamlMap &&
              step['uses'].toString().startsWith('actions/upload-artifact') &&
              !(step['if']?.toString().contains("outcome == 'failure'") ??
                  false)) {
            uploadNames.add(((step['with'] as YamlMap)['name']).toString());
          }
        }
        final coverageUploads = uploadNames
            .where((n) => n.startsWith('pty-coverage-shard-'))
            .toList();
        expect(
          coverageUploads,
          hasLength(1),
          reason: 'exactly one pty-coverage-shard artifact per shard leg',
        );

        // The gate downloads the pattern; every uploaded shard name matches it.
        String? pattern;
        for (final step in gate['steps'] as YamlList) {
          if (step is YamlMap &&
              step['uses'].toString().startsWith('actions/download-artifact') &&
              step['with'] is YamlMap &&
              ((step['with'] as YamlMap)['pattern'] ?? '')
                  .toString()
                  .startsWith('pty-coverage-shard-')) {
            pattern = ((step['with'] as YamlMap)['pattern']).toString();
          }
        }
        expect(
          pattern,
          isNotNull,
          reason: 'the gate must download pty-coverage-shard-*',
        );
        final concreteName = coverageUploads.single.replaceAll(
          r'${{ matrix.shard }}',
          '0',
        );
        expect(
          globToRegExp(pattern!).hasMatch(concreteName),
          isTrue,
          reason:
              'upload name "${coverageUploads.single}" must match '
              'download pattern "$pattern"',
        );

        // The merge step's hard count check must expect the matrix width.
        final mergeRuns = <String>[];
        for (final step in gate['steps'] as YamlList) {
          if (step is YamlMap &&
              step['run'].toString().contains('pty shard coverage reports')) {
            mergeRuns.add(step['run'].toString());
          }
        }
        expect(mergeRuns, hasLength(1));
        final expected = RegExp(
          r'expected (\d+) pty shard coverage reports',
        ).firstMatch(mergeRuns.single);
        expect(expected, isNotNull);
        expect(
          int.parse(expected!.group(1)!),
          shardCount.length,
          reason:
              'the count check must expect exactly the configured shard count',
        );

        // A shard report that downloads but carries no SF: records (empty or
        // truncated upload) must fail the merge LOUDLY — the 2026-09-27
        // outage also showed a partial merge reading 7.95% against the
        // 11.00% baseline because a hollow report still satisfied the count.
        expect(
          mergeRuns.single,
          contains("'^SF:'"),
          reason:
              'merge must reject hollow per-shard lcov reports before merging',
        );
      },
    );
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
      expect(
        ci.containsKey('runner-pick'),
        isFalse,
        reason: 'the M5_POOL probe would route PR legs back onto fa-m5-1',
      );
      expect(
        ci.containsKey('pty-integration'),
        isFalse,
        reason: 'the mac shards merged into pty-integration-linux (gh-1005)',
      );
      expect(nightly.containsKey('runner-pick'), isFalse);
      // The reserved runner's only PR-time consumer stays the macOS kernel E2E.
      expect(
        (ci['cube-kernel-live'] as YamlMap)['runs-on'].toString(),
        contains('macos-m5'),
        reason:
            'cube-kernel-live keeps the genuinely macOS-only gate on fa-m5-1',
      );
    });

    test('every PR PTY leg runs on ubuntu-24.04-arm', () {
      final ci = jobsOf('.github/workflows/ci.yml');
      for (final id in [
        'pty-integration-linux',
        'pty-visual',
        'cli-visual-settings',
      ]) {
        expect(
          (ci[id] as YamlMap)['runs-on'].toString(),
          'ubuntu-24.04-arm',
          reason: '\$id must stay on the hosted linux arm64 pool',
        );
      }
      final nightly = jobsOf('.github/workflows/nightly.yml');
      expect(
        (nightly['pty-integration'] as YamlMap)['runs-on'].toString(),
        'ubuntu-24.04-arm',
      );
      expect(
        (nightly['cli-visual'] as YamlMap)['runs-on'].toString(),
        'ubuntu-24.04-arm',
      );
    });

    test(
      'the consolidated linux leg carries the coverage + duration reporting',
      () {
        final job =
            jobsOf('.github/workflows/ci.yml')['pty-integration-linux']
                as YamlMap;
        final steps = job['steps'] as YamlList;
        final runText = steps
            .whereType<YamlMap>()
            .map((s) {
              final withBlock = s['with'];
              return '${s['run'] ?? ''} ${s['uses'] ?? ''} ${withBlock ?? ''}';
            })
            .join('\n');
        expect(
          runText,
          contains('--coverage=coverage'),
          reason: 'the leg feeds the CLI coverage ratchet',
        );
        expect(
          runText,
          contains('--file-reporter'),
          reason: 'the leg feeds the #928 duration gate',
        );
        for (final artifact in [
          'pty-coverage-shard-',
          'integration-json-shard-',
        ]) {
          expect(
            runText,
            contains(artifact),
            reason:
                '\$artifact uploads must survive the consolidation '
                '(pty-coverage-gate downloads them)',
          );
        }
        // The gate consumes THIS leg, not a phantom mac leg.
        expect(
          (jobsOf('.github/workflows/ci.yml')['pty-coverage-gate']
                  as YamlMap)['needs']
              .toString(),
          contains('pty-integration-linux'),
        );
      },
    );
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
        reason:
            'scratch coverage runs must write under the ignored '
            'coverage/ dir — a WIP auto-save swept cov-raw2/ (2.8 MB of '
            'VM coverage JSON with absolute runner paths) onto the branch '
            'once already',
      );
    });

    test('.gitignore sweeps future cov-*/ scratch dirs', () {
      expect(
        read('.gitignore').split('\n').map((line) => line.trim()),
        contains('cov-*/'),
        reason:
            'next to the coverage/ entries: a stray cov-* run dir '
            'must never become committable again',
      );
    });
  });
}
