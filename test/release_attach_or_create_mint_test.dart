// Behavioral mint-path tests for scripts/release_attach_or_create.sh
// (PR #1783 review): when the release tag is DEFINITELY missing
// (`git ls-remote --exit-code` rc 2), the script mints an annotated tag
// and pushes it through the GH_TOKEN URL. Two guards:
//  - GH_TOKEN unset → fail fast with a self-explaining ::error:: BEFORE
//    the push (the push URL would collapse to '' — git's cryptic
//    `fatal: bad repository ''`, run 39766453580 / v1.0.626 mobile leg);
//  - GH_TOKEN set → the push rides the token URL and the release create
//    follows. The static call-site env contract lives in
//    release_hygiene_test.dart ('every release_attach_or_create.sh call
//    site exports GH_TOKEN …').
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
/// always missing → the mint + create path) and a git shim that captures
/// the token-URL push instead of contacting github.com. Returns
/// (exitCode, combinedOutput, ghLogLines, capturedPushLines).
(int, String, List<String>, List<String>) _runMint(
  String name, {
  required String? ghToken,
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
  // Capture only the token-URL push (the mint would otherwise contact
  // github.com); a credential-less push (empty URL) still goes to the
  // real git and fails — exactly the bug this guards.
  File('${bin.path}/git').writeAsStringSync(
    '#!/usr/bin/env bash\n'
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
    'FA_REAL_GIT': realGit,
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
  final pushes = File('${dir.path}/push.log').existsSync()
      ? File('${dir.path}/push.log').readAsLinesSync()
      : <String>[];
  return (
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/gh.log').readAsLinesSync(),
    pushes,
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
      final (code, out, _, pushes) = _runMint('no-token', ghToken: null);
      expect(code, isNot(0));
      expect(
        out,
        contains('::error::'),
        reason: 'the failure must be a self-explaining Actions error',
      );
      expect(out, contains('GH_TOKEN is not set'));
      expect(
        pushes,
        isEmpty,
        reason: 'no push may be attempted without a credential',
      );
    },
  );

  test(
    'tag mint with GH_TOKEN set pushes the annotated tag through the token URL, then creates the release',
    () {
      final (code, out, ghLog, pushes) = _runMint(
        'with-token',
        ghToken: 'pat-token-for-test',
      );
      expect(code, 0, reason: out);
      expect(pushes, hasLength(1));
      expect(pushes.single, contains('x-access-token:'));
      expect(pushes.single, contains('pat-token-for-test'));
      expect(pushes.single, contains('@github.com/OWNER/REPO.git'));
      expect(pushes.single, contains('refs/tags/v1.2.3'));
      expect(
        ghLog.where((l) => l.contains('release create v1.2.3')),
        hasLength(1),
        reason: 'the mint ends in the release create',
      );
    },
  );
}
