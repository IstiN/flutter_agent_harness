// Behavioral missing-ref tests for scripts/release_lazy_draft.sh
// (gh-2026): `gh release create --draft` for a MISSING tag REST-mints a
// lightweight API tag with NO push event — the v0.1.408 silent class
// (issue #597). When the fast ci.yml-adjacent legs (build-macos.yml
// build-extension / build-macos-cli, ubuntu/hosted, ~10 min) beat the
// attach legs (release-macos / release-mobile), the silent mint wins the
// race, every attach leg finds the tag existing and skips the
// CI-firing annotated push, and the draft is stranded forever (swept by
// the daily sweeper, gh-2026 recurrence). The lazy create must mint the
// missing tag through the same CI-firing annotated push the attach path
// uses (scripts/release_tag_mint.sh) BEFORE creating the draft.
import 'dart:io';

import 'package:test/test.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('lazy-mint-');

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

/// Fixture in the shape the build-macos.yml lazy-draft call sites run:
/// a work clone whose origin lacks the tag, the persisted checkout
/// extraheader present, `gh release view` answering "missing" (the lazy
/// create path) and `gh run list` answering per [trainRunning].
({
  int exitCode,
  String output,
  List<String> ghLogLines,
  List<String> capturedPushLines,
  List<String> gitLogLines,
})
_runLazyMint(String name, {required bool trainRunning}) {
  final dir = Directory(
    '${_fixtureRoot.path}/lazy-$name-${DateTime.now().microsecondsSinceEpoch}',
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
  // actions/checkout's persisted job token.
  git([
    'config',
    'http.https://github.com/.extraheader',
    'AUTHORIZATION: basic am9iLXRva2Vu',
  ]);
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
    'GITHUB_RUN_ID': '222',
    'GITHUB_JOB': 'build-extension',
    'GITHUB_SHA': sha,
    'FA_MINT_PUSH_LOG': '${dir.path}/push.log',
    'FA_MINT_GIT_LOG': '${dir.path}/git.log',
    'FA_REAL_GIT': realGit,
    'GH_STUB_TRAIN_RUNNING': trainRunning ? '1' : '0',
    // Keep the mint's train verification off the wall clock.
    'RELEASE_TRAIN_VERIFY_TRIES': '2',
    'RELEASE_TRAIN_VERIFY_SLEEP': '0',
    'GH_TOKEN': 'pat-token-for-test',
  };
  final res = Process.runSync(
    'bash',
    [
      File('scripts/release_lazy_draft.sh').absolute.path,
      'v1.2.3',
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
    'gh-2026: a lazy draft for a MISSING tag mints it via the CI-firing annotated push first',
    () {
      final (:exitCode, :output, :ghLogLines, :capturedPushLines, :gitLogLines) =
          _runLazyMint('with-token', trainRunning: true);
      expect(exitCode, 0, reason: output);
      expect(capturedPushLines, hasLength(1));
      expect(capturedPushLines.single, contains('x-access-token:'));
      expect(capturedPushLines.single, contains('pat-token-for-test'));
      expect(capturedPushLines.single, contains('refs/tags/v1.2.3'));
      // The silent REST mint would let `gh release create` create the tag;
      // the annotated push must precede the draft create.
      final pushIdx = gitLogLines.indexWhere((l) => l.startsWith('push '));
      final createIdx = ghLogLines.indexWhere(
        (l) => l.contains('release create v1.2.3'),
      );
      expect(pushIdx, greaterThanOrEqualTo(0));
      expect(createIdx, greaterThanOrEqualTo(0));
      expect(
        ghLogLines
            .take(createIdx)
            .where((l) => l.contains('run list'))
            .isNotEmpty,
        isTrue,
        reason: 'the train verification runs before the draft create',
      );
    },
  );

  test(
    'gh-2026: a lazy draft whose mint fired no workflow run fails loud, no draft',
    () {
      final (:exitCode, :output, :ghLogLines, :capturedPushLines) =
          _runLazyMint('silent-train', trainRunning: false);
      expect(exitCode, isNot(0), reason: output);
      expect(output, contains('::error::'));
      expect(
        ghLogLines.where((l) => l.contains('release create v1.2.3')),
        isEmpty,
        reason: 'no draft may be created for a tag with no train',
      );
      expect(capturedPushLines, hasLength(1));
    },
  );
}
