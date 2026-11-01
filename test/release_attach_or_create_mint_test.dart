// Behavioral mint-path tests for scripts/release_attach_or_create.sh
// (PR #1783 review, gh-2026): when the release tag is DEFINITELY missing
// (`git ls-remote --exit-code` rc 2), the script mints an annotated tag
// and pushes it through the GH_TOKEN URL. Guards:
//  - GH_TOKEN unset → fail fast with a self-explaining ::error:: BEFORE
//    the push (the push URL would collapse to '' — git's cryptic
//    `fatal: bad repository ''`, run 39766453580 / v1.0.626 mobile leg);
//  - GH_TOKEN set → the push rides the token URL and the release create
//    follows. The static call-site env contract lives in
//    release_hygiene_test.dart ('every release_attach_or_create.sh call
//    site exports GH_TOKEN …').
//
// gh-2026 (v1.0.663 / v1.0.665 stale drafts): two more guards on the same
// mint, because the creating runs were GREEN while the tag train never
// started:
//  - actions/checkout persists the job token as
//    `http.<host>/.extraheader` in the local git config; that header
//    outranks the URL-embedded PAT on the wire, so the push authenticated
//    as GITHUB_TOKEN and GitHub never fired workflows for it (GITHUB_TOKEN
//    pushes are trigger-suppressed). The mint must strip the persisted
//    extraheader(s) BEFORE the push;
//  - the mint must verify the train actually started (any workflow run on
//    the tag ref) within a bounded budget, and fail loud otherwise — a
//    green run + no train is exactly the stranded-draft shape the daily
//    sweeper kept sweeping.
import 'dart:io';

import 'package:test/test.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('release-mint-');

/// The real git binary (session PATH can carry a push-guard shim — skip
/// it, same as release_hygiene_test.dart).
String _resolveRealGit() {
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

/// A local bare origin whose refs answer but lack the release tag (the
/// definite-missing rc 2 verdict), a work clone, the gh stub (release
/// always missing → the mint + create path; `run list` answers per
/// [trainRunning]) and a git shim that captures the token-URL push and
/// logs every git invocation instead of contacting github.com.
({
  int exitCode,
  String output,
  List<String> ghLogLines,
  List<String> capturedPushLines,
  List<String> gitLogLines,
})
_runMint(
  String name, {
  required String? ghToken,
  bool seedExtraheader = false,
  bool trainRunning = true,
  Map<String, String> extraEnv = const {},
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/mint-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = Directory('${dir.path}/bin')..createSync(recursive: true);
  File('${bin.path}/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ "\$1" = "release" ] && [ "\$2" = "view" ]; then
  echo "release not found (stub)" >&2
  exit 1
fi
if [ "\$1" = "run" ] && [ "\$2" = "list" ]; then
  # Simulate the Actions run row the push event should have created.
  if [ "\${GH_STUB_TRAIN_RUNNING:-0}" = "1" ]; then echo 1; fi
  exit 0
fi
exit 0
''');
  Process.runSync('chmod', ['+x', '${bin.path}/gh']);
  final origin = '${dir.path}/origin.git';
  final work = '${dir.path}/work';
  final realGit = _resolveRealGit();
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
    'GITHUB_RUN_ID': '111',
    'GITHUB_JOB': 'release-macos',
    'GITHUB_SHA': sha,
    'FA_MINT_PUSH_LOG': '${dir.path}/push.log',
    'FA_MINT_GIT_LOG': '${dir.path}/git.log',
    'FA_REAL_GIT': realGit,
    'GH_STUB_TRAIN_RUNNING': trainRunning ? '1' : '0',
    ...extraEnv,
  };
  // Explicit override both ways: Process.runSync merges the parent env by
  // default, and a review host can carry a real GH_TOKEN (this session
  // does) — the 'unset' leg must stay credential-less, the 'set' leg must
  // see exactly the fixture token.
  env['GH_TOKEN'] = ghToken ?? '';
  final res = Process.runSync(
    'bash',
    [
      File('scripts/release_attach_or_create.sh').absolute.path,
      'v1.2.3',
      'a.zip',
    ],
    workingDirectory: work,
    environment: env,
  );
  List<String> lines(String path) => File(path).existsSync()
      ? File(path).readAsLinesSync().where((l) => l.isNotEmpty).toList()
      : <String>[];
  return (
    exitCode: res.exitCode,
    output: '${res.stdout}${res.stderr}',
    ghLogLines: lines('${dir.path}/gh.log'),
    capturedPushLines: lines('${dir.path}/push.log'),
    gitLogLines: lines('${dir.path}/git.log'),
  );
}

void main() {
  test(
    'tag mint with GH_TOKEN unset fails fast: ::error:: names the env gap, no empty-URL push',
    () {
      // PR #1783 review: the root symptom of run 39766453580 was git's
      // cryptic `fatal: bad repository ''` — the push URL collapses to ''
      // when GH_TOKEN is unset. The script must self-explain BEFORE the
      // push.
      final (:exitCode, :output, :capturedPushLines) = _runMint(
        'no-token',
        ghToken: null,
      );
      expect(exitCode, isNot(0));
      expect(
        output,
        contains('::error::'),
        reason: 'the failure must be a self-explaining Actions error',
      );
      expect(output, contains('GH_TOKEN is not set'));
      expect(
        capturedPushLines,
        isEmpty,
        reason: 'no push may be attempted without a credential',
      );
    },
  );

  test(
    'tag mint with GH_TOKEN set pushes the annotated tag through the token URL, then creates the release',
    () {
      final (:exitCode, :output, :ghLogLines, :capturedPushLines) = _runMint(
        'with-token',
        ghToken: 'pat-token-for-test',
      );
      expect(exitCode, 0, reason: output);
      expect(capturedPushLines, hasLength(1));
      expect(capturedPushLines.single, contains('x-access-token:'));
      expect(capturedPushLines.single, contains('pat-token-for-test'));
      expect(capturedPushLines.single, contains('@github.com/OWNER/REPO.git'));
      expect(capturedPushLines.single, contains('refs/tags/v1.2.3'));
      expect(
        ghLogLines.where((l) => l.contains('release create v1.2.3')),
        hasLength(1),
        reason: 'the mint ends in the release create',
      );
    },
  );

  test(
    'gh-2026: the mint strips the persisted checkout extraheader BEFORE the push',
    () {
      // actions/checkout persists GITHUB_TOKEN as
      // http.https://github.com/.extraheader; that Authorization outranks
      // the URL's PAT, so GitHub saw the push as a GITHUB_TOKEN push and
      // suppressed the tag train (v1.0.663 / v1.0.665 — green runs, zero
      // workflow runs on the tag refs, drafts swept 24h later). The mint
      // must unset the persisted extraheader(s) before pushing.
      final (:exitCode, :output, :capturedPushLines, :gitLogLines) = _runMint(
        'strip-header',
        ghToken: 'pat-token-for-test',
        seedExtraheader: true,
      );
      expect(exitCode, 0, reason: output);
      expect(capturedPushLines, hasLength(1), reason: output);
      final configIdx = gitLogLines.indexWhere(
        (l) =>
            l.contains('config') &&
            l.contains('--unset-all') &&
            l.contains('http.https://github.com/.extraheader'),
      );
      final pushIdx = gitLogLines.indexWhere((l) => l.startsWith('push '));
      expect(configIdx, greaterThanOrEqualTo(0), reason: output);
      expect(
        configIdx < pushIdx,
        isTrue,
        reason:
            'the extraheader strip must precede the push (git log: '
            '$gitLogLines)',
      );
    },
  );

  test(
    'gh-2026: the mint verifies the tag train started before creating the draft',
    () {
      final (:exitCode, :output, :ghLogLines, :gitLogLines) = _runMint(
        'verify-happy',
        ghToken: 'pat-token-for-test',
        trainRunning: true,
        extraEnv: const {
          'RELEASE_TRAIN_VERIFY_TRIES': '2',
          'RELEASE_TRAIN_VERIFY_SLEEP': '0',
        },
      );
      expect(exitCode, 0, reason: output);
      expect(
        gitLogLines.any((l) => l.startsWith('push ')),
        isTrue,
        reason: 'the push precedes the verification',
      );
      expect(
        ghLogLines.any(
          (l) =>
              l.contains('run list') &&
              l.contains('--branch v1.2.3') &&
              l.contains('OWNER/REPO'),
        ),
        isTrue,
        reason:
            'the mint must poll for a workflow run on the tag ref '
            '(gh log: $ghLogLines)',
      );
      expect(
        ghLogLines.where((l) => l.contains('release create v1.2.3')),
        hasLength(1),
        reason: 'the draft create follows a verified train',
      );
    },
  );

  test(
    'gh-2026: a mint whose push fired no workflow run fails loud and never creates the draft',
    () {
      // The v1.0.663 / v1.0.665 shape: the push succeeds, no tag run ever
      // appears, the leg stays green, and the draft is swept a day later.
      // The mint must fail the step instead — the caller's draft lifecycle
      // guard and the red leg then own the failure.
      final (:exitCode, :output, :ghLogLines, :capturedPushLines) = _runMint(
        'verify-silent',
        ghToken: 'pat-token-for-test',
        trainRunning: false,
        extraEnv: const {
          'RELEASE_TRAIN_VERIFY_TRIES': '2',
          'RELEASE_TRAIN_VERIFY_SLEEP': '0',
        },
      );
      expect(exitCode, isNot(0), reason: output);
      expect(output, contains('::error::'));
      expect(output, contains('v1.2.3'));
      expect(
        output.contains('no workflow run'),
        isTrue,
        reason: 'the error must name the suppressed-train failure shape',
      );
      expect(
        ghLogLines.where((l) => l.contains('release create v1.2.3')),
        isEmpty,
        reason: 'no draft may be created for a tag with no train',
      );
      expect(pushes, hasLength(1), reason: 'the push itself was attempted');
    },
  );
}
