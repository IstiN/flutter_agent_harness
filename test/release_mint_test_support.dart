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
  MintRun(this.exitCode, this.output, this.ghLog, this.pushes, this.gitLog);
  final int exitCode;
  final String output;
  final List<String> ghLog; // every gh invocation the script made
  final List<String> pushes; // captured token-URL push command lines
  final List<String> gitLog; // every git invocation, in order
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
  );
}
