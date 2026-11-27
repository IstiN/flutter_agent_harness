// Shared harness for the release-mint behavioral tests (gh-2026): the
// bare-origin + work-clone + gh-stub + git-shim fixture used by
// release_attach_or_create_mint_test.dart (scripts/release_attach_or_create.sh)
// and release_lazy_draft_mint_test.dart (scripts/release_lazy_draft.sh).
// Extracted verbatim from the twins the similarity gate flagged — the
// scripts differ, the fixture around them does not.
import 'dart:io';

import 'package:test/test.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('release-mint-');

/// The real git binary (session PATH can carry a push-guard shim — skip
/// it, same as release_hygiene_test.dart).
String resolveRealGit() {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final cand = '$dir/git';
    if (!File(cand).existsSync()) continue;
    final resolved = File(cand).resolveSymbolicLinksSync();
    if (resolved.endsWith('git-push-guard.sh')) continue;
    return resolved;
  }
  return '/usr/bin/git';
}

/// One scripted run over the mint fixture.
class MintRun {
  MintRun(
    this.exitCode,
    this.output,
    this.ghLog,
    this.pushes,
    this.gitLog, {
    this.notesCapture = '',
    this.rosterIds = const [],
  });
  final int exitCode;
  final String output;
  final List<String> ghLog; // every gh invocation the script made
  final List<String> pushes; // captured token-URL push command lines
  final List<String> gitLog; // every git invocation, in order

  /// The body of the `--notes-file` the script passed to `gh release
  /// create` (empty when the stub never captured one) — gh-237 body-cap
  /// evidence.
  final String notesCapture;

  /// The ids of the release objects still on the stub roster after the
  /// run (gh-2432 rework: every landed create — a 500 that landed
  /// server-side or a success — records an object; a dedupe DELETE
  /// removes it). Empty when nothing landed.
  final List<String> rosterIds;
}

/// A local bare origin whose refs answer but lack the release tag (the
/// definite-missing rc 2 verdict), a work clone, the gh stub (release
/// always missing → the mint + create path; `run list` answers per
/// [trainRunning]) and a git shim that captures the token-URL push and
/// logs every git invocation instead of contacting github.com — then
/// runs [script] over it.
MintRun runReleaseMintFixture(
  String script, {
  required List<String> args,
  required String name,
  required String? ghToken,
  bool seedExtraheader = false,
  bool trainRunning = true,
  String githubRunId = '111',
  String githubJob = 'release-macos',
  Map<String, String> extraEnv = const {},
  bool seedTag = false,
  bool ghCreateFails = false,
  bool viewFoundAfterFirst = false,
  bool seedReleaseNotes = false,
  bool seedOversizeChangelog = false,
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/mint-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = Directory('${dir.path}/bin')..createSync(recursive: true);
  File('${bin.path}/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ "\$1" = "release" ] && [ "\$2" = "view" ]; then
  if [ "\${GH_STUB_VIEW_FOUND_AFTER_FIRST:-0}" = "1" ] && [ -f "\$GH_STUB_STATE/view-seen" ]; then
    exit 0
  fi
  touch "\$GH_STUB_STATE/view-seen"
  echo "release not found (stub)" >&2
  exit 1
fi
if [ "\$1" = "run" ] && [ "\$2" = "list" ]; then
  # Simulate the Actions run row the push event should have created.
  if [ "\${GH_STUB_TRAIN_RUNNING:-0}" = "1" ]; then echo 1; fi
  exit 0
fi
if [ "\$1" = "release" ] && [ "\$2" = "create" ]; then
  # Capture the notes body the create carried (gh-237 body-cap evidence).
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "--notes-file" ] && [ -f "\$a" ]; then
      cp "\$a" "\$GH_NOTES_CAPTURE" 2>/dev/null || true
    fi
    prev="\$a"
  done
  if [ "\${GH_STUB_CREATE_FAILS:-0}" = "1" ]; then
    echo "HTTP 422: Validation Failed (stub)" >&2
    echo "body is too long (maximum is 125000 characters)" >&2
    exit 1
  fi
  # gh-2432: fail the FIRST N creates with a TRANSIENT GitHub API 5xx —
  # the exact v1.0.778 shape (HTTP 500 from POST /releases on every
  # hosted binaries leg while the release still materialised minutes
  # later). The counter counts create ATTEMPTS, so the retry under test
  # answers 500 for attempts ≤ N and succeeds afterwards. The v1.0.778
  # twist the landed-500 tests pin: a 500'd attempt may still CREATE the
  # draft server-side (it resolved minutes later to the macOS legs), so
  # EVERY landed create — a 500'd one or a success — records a roster
  # object the twin dedupe can list and delete by id.
  record_draft() {
    rid="\$(cat "\$GH_STUB_STATE/roster-next-id" 2>/dev/null || echo 100)"
    printf '%s' "\$((rid + 1))" > "\$GH_STUB_STATE/roster-next-id"
    printf '{"id":%s,"tag_name":"%s","draft":true,"created_at":"2026-11-26T00:00:00Z","author":{"login":"ai-teammate","type":"Bot"},"body":"<!-- release-draft-owner: %s -->"}\\n' \\
      "\$rid" "\$1" "\${RELEASE_DRAFT_IDENTITY:-run/\$GITHUB_RUN_ID/job/\$GITHUB_JOB}" \\
      >> "\$GH_STUB_STATE/roster.jsonl"
  }
  n5xx="\${GH_STUB_CREATE_FAILS_5XX_N:-0}"
  if [ "\$n5xx" -gt 0 ]; then
    n=\$(( \$(cat "\$GH_STUB_STATE/creates-attempted" 2>/dev/null || echo 0) + 1 ))
    echo "\$n" > "\$GH_STUB_STATE/creates-attempted"
    if [ "\$n" -le "\$n5xx" ]; then
      record_draft "\$3"
      echo "HTTP 500 (https://api.github.com/repos/OWNER/REPO/releases) (stub)" >&2
      exit 1
    fi
  fi
  record_draft "\$3"
  exit 0
fi
if [ "\$1" = "api" ]; then
  case "\$*" in
    *repos/OWNER/REPO/releases*)
      if [ "\$2" = "-X" ] && [ "\$3" = "DELETE" ]; then
        rid="\${4##*/}"
        grep -v "\\"id\\":\$rid," "\$GH_STUB_STATE/roster.jsonl" \\
          > "\$GH_STUB_STATE/roster.jsonl.tmp" 2>/dev/null || :
        mv "\$GH_STUB_STATE/roster.jsonl.tmp" "\$GH_STUB_STATE/roster.jsonl" 2>/dev/null || :
        exit 0
      fi
      # A JSON stream of objects (jq -s collects them) — `[]` when the
      # roster is empty or nothing ever landed.
      if [ -s "\$GH_STUB_STATE/roster.jsonl" ]; then
        cat "\$GH_STUB_STATE/roster.jsonl"
      else
        echo "[]"
      fi
      exit 0
      ;;
  esac
  exit 0
fi
exit 0
''');
  Process.runSync('chmod', ['+x', '${bin.path}/gh']);
  final origin = '${dir.path}/origin.git';
  final work = '${dir.path}/work';
  final realGit = resolveRealGit();
  void git(List<String> args, {String? cwd}) {
    final r = Process.runSync(realGit, args, workingDirectory: cwd ?? work);
    expect(r.exitCode, 0, reason: 'fixture git $args failed: ${r.stderr}');
  }

  git(['init', '-q', '--bare', '-b', 'main', origin], cwd: dir.path);
  git(['clone', '-q', origin, work], cwd: dir.path);
  git(['config', 'user.email', 't@t']);
  git(['config', 'user.name', 't']);
  File('$work/README.md').writeAsStringSync('seed\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'seed']);
  git(['push', '-q', 'origin', 'main']);
  final sha = Process.runSync(realGit, [
    'rev-parse',
    'HEAD',
  ], workingDirectory: work).stdout.toString().trim();
  // gh-237: seed the release tag so `git ls-remote --exit-code` answers
  // rc 0 and the script skips the whole mint path — the body-cap and
  // loud-failure tests exercise the create handling, not the mint.
  if (seedTag) {
    final tag = args.first;
    git(['tag', '-a', tag, '-m', tag]);
    git(['push', '-q', 'origin', 'refs/tags/$tag']);
  }
  // gh-237: an over-cap release-notes.md (a curated body larger than
  // GitHub's 125,000-character release-body cap) prepared by the caller.
  if (seedReleaseNotes) {
    File(
      '$work/release-notes.md',
    ).writeAsStringSync('${'x' * 130_000}\ntrailing curated line\n');
  }
  // gh-237 rework: an over-cap curated `## Unreleased` CHANGELOG body
  // (the production shape — the v1.0.756 curated section was ~131 KB),
  // which release_notes.sh preference 1b returns as the lazy draft's
  // notes; the cap helper must bound it before the owner marker is
  // stamped or the truncation strips the marker.
  if (seedOversizeChangelog) {
    File('$work/CHANGELOG.md').writeAsStringSync(
      '## Unreleased\n${'${'x' * 220}\n' * 600}', // ~132 KB curated body
    );
  }
  // What actions/checkout leaves behind (persist-credentials defaults
  // true): the job token as an http extraheader on the host's URL.
  if (seedExtraheader) {
    git([
      'config',
      'http.https://github.com/.extraheader',
      'AUTHORIZATION: basic am9iLXRva2Vu',
    ]);
  }
  // Capture every git invocation (ordering evidence) and the token-URL
  // push (the mint would otherwise contact github.com); a credential-less
  // push (empty URL) still goes to the real git and fails — exactly the
  // bug this guards.
  File('${bin.path}/git').writeAsStringSync(
    '#!/usr/bin/env bash\n'
    'echo "\$*" >> "\${FA_MINT_GIT_LOG:-/dev/null}"\n'
    'if [ "\$1" = "push" ]; then\n'
    '  case "\$2" in\n'
    '    https://*) echo "\$*" >> "\$FA_MINT_PUSH_LOG"; exit 0 ;;\n'
    '  esac\n'
    'fi\n'
    'exec "\$FA_REAL_GIT" "\$@"\n',
  );
  Process.runSync('chmod', ['+x', '${bin.path}/git']);
  final env = <String, String>{
    'PATH': '${bin.path}:${Platform.environment['PATH']}',
    'HOME': dir.path,
    'GITHUB_REPOSITORY': 'OWNER/REPO',
    'GH_LOG_FILE': '${dir.path}/gh.log',
    'GITHUB_RUN_ID': githubRunId,
    'GITHUB_JOB': githubJob,
    'GITHUB_SHA': sha,
    'FA_MINT_PUSH_LOG': '${dir.path}/push.log',
    'FA_MINT_GIT_LOG': '${dir.path}/git.log',
    'FA_REAL_GIT': realGit,
    'GH_STUB_TRAIN_RUNNING': trainRunning ? '1' : '0',
    'GH_STUB_CREATE_FAILS': ghCreateFails ? '1' : '0',
    'GH_STUB_VIEW_FOUND_AFTER_FIRST': viewFoundAfterFirst ? '1' : '0',
    'GH_STUB_STATE': dir.path,
    'GH_NOTES_CAPTURE': '${dir.path}/notes-capture.md',
    // The mint's train-verify loop sleeps BEFORE its first probe, so even
    // the happy path (stub answers a run row instantly) paid one full
    // 10s production sleep per run (the negative-path tests already set
    // these; the positive ones forgot). Probe immediately in the fixture
    // — production keeps the 10s/12-try budget. Caller overrides win.
    'RELEASE_TRAIN_VERIFY_SLEEP': '0.05',
    'RELEASE_TRAIN_VERIFY_TRIES': '4',
    ...extraEnv,
  };
  // Explicit override both ways: Process.runSync merges the parent env by
  // default, and a review host can carry a real GH_TOKEN (this session
  // does) — the 'unset' leg must stay credential-less, the 'set' leg must
  // see exactly the fixture token.
  env['GH_TOKEN'] = ghToken ?? '';
  final res = Process.runSync(
    'bash',
    [File(script).absolute.path, ...args],
    workingDirectory: work,
    environment: env,
  );
  List<String> lines(String path) => File(path).existsSync()
      ? File(path).readAsLinesSync().where((l) => l.isNotEmpty).toList()
      : <String>[];
  return MintRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    lines('${dir.path}/gh.log'),
    lines('${dir.path}/push.log'),
    lines('${dir.path}/git.log'),
    notesCapture: File('${dir.path}/notes-capture.md').existsSync()
        ? File('${dir.path}/notes-capture.md').readAsStringSync()
        : '',
    rosterIds: _rosterIds('${dir.path}/roster.jsonl'),
  );
}

/// The ids still on the stub roster (one JSON object per line, created
/// in ascending-id order) — the twin-dedupe survival evidence.
List<String> _rosterIds(String path) {
  if (!File(path).existsSync()) return const [];
  return File(path)
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .map((l) => RegExp(r'"id":(\d+),').firstMatch(l)?.group(1))
      .whereType<String>()
      .toList();
}
