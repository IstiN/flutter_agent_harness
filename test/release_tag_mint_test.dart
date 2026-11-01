// Behavioral tests for scripts/release_tag_mint.sh — the shared mint both
// draft-capable create paths delegate to (release_attach_or_create.sh,
// release_lazy_draft.sh). This file owns the MINT-LEVEL cases the caller
// suites cannot express — concurrency and recovery semantics:
//
//  - the raced mint (PR #2029 review): build-macos-cli is a 2-arch matrix
//    whose legs run in parallel, build-extension / release-macos /
//    release-mobile race the same fresh tag — `git push` is not
//    race-idempotent (tags never fast-forward), so the loser's rejected
//    push used to kill the mint under `set -euo pipefail` with a bare
//    `fatal: tag already exists` and a spurious red required leg. The
//    mint must re-probe after a failed push and continue when a sibling
//    leg won the race;
//  - the orphan-tag rollback (PR #2029 review): when the train
//    verification fails, the pushed tag must be rolled back (remote ref
//    + local tag object) so the prescribed "fix the credential and
//    re-run" actually re-mints instead of silently re-arming the
//    stranded-draft shape (gh-2026);
//  - the loud probe failure (PR #2029 review): `gh run list` failing
//    (403 without Actions:read, expired PAT, rate limit) is NOT evidence
//    of a suppressed train — the mint must fail fast with a distinct
//    self-explaining error instead of blaming the push credential.
//
// Single-minter happy paths live in the caller suites
// (release_attach_or_create_mint_test.dart / release_lazy_draft_mint_test.dart).
import 'dart:io';

import 'package:test/test.dart';

import 'release_mint_test_support.dart';

/// One minter over a SHARED bare origin: unlike the caller-suite fixture
/// (pushes intercepted, never landed), the git shim here routes token-URL
/// pushes to the real bare origin, so two concurrent minters exercise
/// real git race semantics (one push lands, the loser is rejected).
class RaceMinter {
  RaceMinter({
    required this.root,
    required this.origin,
    required this.name,
    required this.committerDate,
    this.pushLands = true,
  });

  final Directory root;
  final String origin; // the shared bare origin
  final String name;
  final String committerDate; // distinct per minter → distinct tag objects
  final bool pushLands; // false → the push fails without landing (genuine failure)

  late final String work;
  late final int gitCalls;
  int ghRunListCalls = 0;
  int exitCode = -1;
  String output = '';

  String get _bin => '${root.path}/bin-$name';
  String get _ghLog => '${root.path}/gh-$name.log';
  String get _gitLog => '${root.path}/git-$name.log';

  void buildFixture(String sha) {
    work = '${root.path}/work-$name';
    Directory(_bin).createSync(recursive: true);
    final realGit = resolveRealGit();
    void git(List<String> args, {String? cwd}) {
      final r = Process.runSync(realGit, args, workingDirectory: cwd ?? work);
      expect(r.exitCode, 0, reason: 'fixture git $args failed: ${r.stderr}');
    }

    git(['clone', '-q', origin, work], cwd: root.path);
    git(['config', 'user.email', 't@t']);
    git(['config', 'user.name', 't']);
    // What actions/checkout persists (both CI legs carry it): the job
    // token extraheader the mint must strip before its push.
    git([
      'config',
      'http.https://github.com/.extraheader',
      'AUTHORIZATION: basic am9iLXRva2Vu',
    ]);
    // gh stub: release always missing, `run list` answers per
    // GH_STUB_TRAIN_RUNNING (or fails, for the probe-failure case).
    File('$_bin/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ "\$1" = "run" ] && [ "\$2" = "list" ]; then
  if [ "\${GH_STUB_PROBE_FAILS:-0}" = "1" ]; then
    echo "gh: Resource not accessible by integration (HTTP 403)" >&2
    exit 7
  fi
  if [ "\${GH_STUB_TRAIN_RUNNING:-0}" = "1" ]; then echo 1; fi
  exit 0
fi
exit 0
''');
    // git shim: capture invocations; route token-URL pushes to the shared
    // bare origin with REAL git semantics (the race), or fail them
    // without landing (pushLands=false → genuine push failure).
    File('$_bin/git').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$FA_MINT_GIT_LOG"
if [ "\$1" = "push" ]; then
  case "\$2" in
    https://*)
      if [ "\${FA_RACE_PUSH_LANDS:-1}" != "1" ]; then
        echo "! [remote rejected] (pre-receive hook declined)" >&2
        exit 1
      fi
      exec "\$FA_REAL_GIT" push "\$FA_RACE_ORIGIN" "\$3"
      ;;
  esac
fi
exec "\$FA_REAL_GIT" "\$@"
''');
    Process.runSync('chmod', ['+x', '$_bin/gh', '$_bin/git']);
  }

  Map<String, String> env() => {
    'PATH': '$_bin:${Platform.environment['PATH']}',
    'HOME': root.path,
    'GITHUB_REPOSITORY': 'OWNER/REPO',
    'GH_TOKEN': 'pat-token-for-test',
    'GITHUB_RUN_ID': '111',
    'GITHUB_JOB': 'build-macos-cli',
    'GITHUB_SHA': _sha,
    'RELEASE_TARGET_SHA': _sha,
    'RELEASE_TRAIN_VERIFY_TRIES': '2',
    'RELEASE_TRAIN_VERIFY_SLEEP': '0',
    'GH_LOG_FILE': _ghLog,
    'FA_MINT_GIT_LOG': _gitLog,
    'FA_REAL_GIT': resolveRealGit(),
    'FA_RACE_ORIGIN': origin,
    'FA_RACE_PUSH_LANDS': pushLands ? '1' : '0',
    // Distinct tag objects per minter — git tag -a stamps the committer
    // date into the annotated object, so same-second tag creations would
    // hash identically and the loser's push would be a silent no-op
    // instead of the deterministic rejection the race produces.
    'GIT_COMMITTER_DATE': committerDate,
    'GIT_AUTHOR_DATE': committerDate,
    ..._extraEnv,
  };

  Map<String, String> _extraEnv = const {};
  late String _sha;

  void withSha(String sha) => _sha = sha;

  void withEnv(Map<String, String> extra) => _extraEnv = extra;

  Future<void> run(String tag) {
    final p = Process.start('bash', [
      File('scripts/release_tag_mint.sh').absolute.path,
      tag,
    ], workingDirectory: work, environment: env());
    return p.then((proc) async {
      final out = <String>[];
      out.add(await proc.stdout.transform(systemEncoding.decoder).join());
      out.add(await proc.stderr.transform(systemEncoding.decoder).join());
      exitCode = await proc.exitCode;
      output = out.join();
      final log = File(_ghLog);
      ghRunListCalls = log.existsSync()
          ? log
                .readAsLinesSync()
                .where((l) => l.contains('run list'))
                .length
          : 0;
      final g = File(_gitLog);
      gitCalls = g.existsSync() ? g.readAsLinesSync().length : 0;
    });
  }
}

Future<(RaceMinter, RaceMinter)> _racePair(String tag) async {
  final root = Directory.systemTemp.createTempSync('mint-race-');
  final realGit = resolveRealGit();
  final origin = '${root.path}/origin.git';
  Process.runSync(realGit, [
    'init',
    '-q',
    '--bare',
    '-b',
    'main',
    origin,
  ], workingDirectory: root.path);
  // Seed the shared origin from a throwaway clone so both minters fetch
  // the same target commit (the tag target).
  final seed = '${root.path}/seed';
  void git(List<String> args, {String? cwd}) {
    final r = Process.runSync(realGit, args, workingDirectory: cwd ?? seed);
    expect(r.exitCode, 0, reason: 'fixture git $args failed: ${r.stderr}');
  }

  git(['clone', '-q', origin, seed], cwd: root.path);
  git(['config', 'user.email', 't@t']);
  git(['config', 'user.name', 't']);
  File('$seed/README.md').writeAsStringSync('seed\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'seed']);
  git(['push', '-q', 'origin', 'main']);
  final sha = Process.runSync(realGit, [
    'rev-parse',
    'HEAD',
  ], workingDirectory: seed).stdout.toString().trim();

  final a = RaceMinter(
    root: root,
    origin: origin,
    name: 'a',
    committerDate: '2026-01-01T00:00:01Z',
  )..withSha(sha);
  final b = RaceMinter(
    root: root,
    origin: origin,
    name: 'b',
    committerDate: '2026-01-01T00:00:02Z',
  )..withSha(sha);
  a.buildFixture(sha);
  b.buildFixture(sha);
  return (a, b);
}

void main() {
  test(
    'PR #2029 review: a mint that loses the push race to a sibling leg continues to train verification instead of dying on the rejected push',
    () async {
      // build-macos-cli runs both arch legs in parallel on hosted
      // runners; on the daily flow the tag is definitely missing when
      // they arrive, so both enter the mint at nearly the same instant.
      // Tags never fast-forward: the loser's push is rejected and, under
      // `set -euo pipefail`, the mint used to die with a bare
      // `fatal: tag 'v9.9.9' already exists` — a spurious red required
      // leg on the very flow this PR fixes. The mint must re-probe the
      // ref after a failed push and continue when a sibling leg won.
      final (a, b) = await _racePair('v9.9.9');
      a.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
      b.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
      // True concurrency: both minters are mid-flight simultaneously —
      // the exact shape the 2-arch matrix produces on the daily flow.
      await Future.wait([a.run('v9.9.9'), b.run('v9.9.9')]);
      for (final m in [a, b]) {
        expect(
          m.exitCode,
          0,
          reason: 'the ${m.name} minter must survive the race '
              '(output: ${m.output})',
        );
      }
      // Exactly one push can land; the other must have been tolerated as
      // the raced-mint case (never a bare fatal / never a red exit).
      final raced = [a, b].where(
        (m) => m.output.contains('minted concurrently by a sibling leg'),
      );
      expect(raced, hasLength(1), reason: 'exactly one minter lost the push');
      expect(
        [a, b].any(
          (m) => m.output.contains(
            '✅ tag train for v9.9.9 started',
          ),
        ),
        isTrue,
        reason: 'the loser continues to (and passes) train verification',
      );
    },
  );

  test(
    'PR #2029 review: a push that fails with the ref still missing fails loud with a self-explaining error',
    () {
      // The race tolerance must not swallow genuine push failures: if the
      // push fails AND the ref is still absent, nothing minted the tag —
      // the leg must go red naming the real problem, not exit 0.
      final root = Directory.systemTemp.createTempSync('mint-noland-');
      final realGit = resolveRealGit();
      final origin = '${root.path}/origin.git';
      Process.runSync(realGit, [
        'init',
        '-q',
        '--bare',
        '-b',
        'main',
        origin,
      ], workingDirectory: root.path);
      final m = RaceMinter(
        root: root,
        origin: origin,
        name: 'noland',
        committerDate: '2026-01-01T00:00:01Z',
        pushLands: false,
      );
      m.buildFixture('');
      final sha = Process.runSync(realGit, [
        'rev-parse',
        'HEAD',
      ], workingDirectory: m.work).stdout.toString().trim();
      m.withSha(sha);
      m.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
      final done = m.run('v9.9.8');
      // The mint is fully synchronous (Process.runSync inside); the
      // future completes on the next microtask.
      return done.then((_) {
        expect(m.exitCode, isNot(0), reason: m.output);
        expect(m.output, contains('::error::'));
        expect(
          m.output,
          contains('push failed and the ref is still missing'),
          reason: 'the error must distinguish the no-land push failure '
              'from the raced-mint case',
        );
      });
    },
  );

  test(
    'PR #2029 review: a failed train verification rolls the pushed tag back so a fixed re-run re-mints instead of stranding the draft',
    () {
      // The v1.0.663 / v1.0.665 recovery trap: attempt 1 pushes the tag,
      // no run appears, the mint fails loud — but the tag stays on the
      // remote. The prescribed "fix the credential and re-run" then finds
      // the tag existing, skips the mint AND its train check, and the
      // caller's plain `gh release create --draft` re-arms the exact
      // stranded-draft shape (green leg, sweep a day later). The mint
      // must roll the untrained ref back (remote + the local tag object
      // that would break a reused-workspace re-tag) before failing.
      final root = Directory.systemTemp.createTempSync('mint-rollback-');
      final realGit = resolveRealGit();
      final origin = '${root.path}/origin.git';
      Process.runSync(realGit, [
        'init',
        '-q',
        '--bare',
        '-b',
        'main',
        origin,
      ], workingDirectory: root.path);
      final m = RaceMinter(
        root: root,
        origin: origin,
        name: 'rollback',
        committerDate: '2026-01-01T00:00:01Z',
      );
      m.buildFixture('');
      final sha = Process.runSync(realGit, [
        'rev-parse',
        'HEAD',
      ], workingDirectory: m.work).stdout.toString().trim();
      m.withSha(sha);
      m.withEnv(const {'GH_STUB_TRAIN_RUNNING': '0'});

      // Attempt 1: push lands, no run ever appears → loud failure + rollback.
      m.run('v9.9.7');
      expect(m.exitCode, isNot(0), reason: m.output);
      expect(m.output, contains('::error::tag train did not start'));
      expect(
        m.output,
        contains('rolling back the untrained tag ref'),
        reason: 'the operator must see the rollback in the log',
      );
      final remoteRef = Process.runSync(realGit, [
        'ls-remote',
        '--exit-code',
        origin,
        'refs/tags/v9.9.7',
      ]);
      expect(
        remoteRef.exitCode,
        2,
        reason: 'the untrained tag ref must be rolled back on the remote '
            '(stdout: ${remoteRef.stdout})',
      );
      // Local tag object must be gone too (a reused self-hosted workspace
      // would otherwise die at `git tag -a` on the re-run).
      final localTags = Process.runSync(realGit, [
        'tag',
        '-l',
      ], workingDirectory: m.work).stdout.toString().trim();
      expect(localTags, isEmpty, reason: 'the local tag must be dropped');

      // Attempt 2 ("fix the credential and re-run"): the ref is absent
      // again, so the mint re-mints and — with the train now visible —
      // succeeds. This is the recovery path the orphan tag used to break.
      final m2 = RaceMinter(
        root: root,
        origin: origin,
        name: 'rollback-retry',
        committerDate: '2026-01-01T00:00:03Z',
      );
      m2.buildFixture('');
      m2.withSha(sha);
      m2.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
      m2.run('v9.9.7');
      expect(m2.exitCode, 0, reason: m2.output);
      expect(m2.output, contains('✅ tag train for v9.9.7 started'));
    },
  );

  test(
    'PR #2029 review: a failing train probe (403 / expired PAT) fails fast and is diagnosed as a probe failure, never as a suppressed train',
    () {
      // `2>/dev/null || echo 0` used to collapse a denied/failing probe
      // into "no train": the leg burned the full 12×10s budget and then
      // blamed the push credential (CI-suppressed token) while the real
      // cause — RELEASE_PAT without Actions:read, an expired PAT, a rate
      // limit — was discarded to /dev/null. A probe failure must abort
      // the budget immediately with a distinct, self-explaining error.
      final root = Directory.systemTemp.createTempSync('mint-probe-');
      final realGit = resolveRealGit();
      final origin = '${root.path}/origin.git';
      Process.runSync(realGit, [
        'init',
        '-q',
        '--bare',
        '-b',
        'main',
        origin,
      ], workingDirectory: root.path);
      final m = RaceMinter(
        root: root,
        origin: origin,
        name: 'probe',
        committerDate: '2026-01-01T00:00:01Z',
      );
      m.buildFixture('');
      final sha = Process.runSync(realGit, [
        'rev-parse',
        'HEAD',
      ], workingDirectory: m.work).stdout.toString().trim();
      m.withSha(sha);
      m.withEnv(const {'GH_STUB_PROBE_FAILS': '1'});
      m.run('v9.9.6');
      expect(m.exitCode, isNot(0), reason: m.output);
      expect(m.output, contains('::error::train verification probe failed'));
      expect(
        m.output,
        contains('HTTP 403'),
        reason: 'the probe failure detail must surface (it is the RCA)',
      );
      expect(
        m.ghRunListCalls,
        1,
        reason: 'a failing probe must abort immediately, not burn the '
            'verification budget',
      );
      expect(
        m.output.contains('tag train did not start'),
        isFalse,
        reason: 'a probe failure is NOT evidence of a suppressed train',
      );
      expect(
        m.output.contains('CI-suppressed token'),
        isFalse,
        reason: 'the misleading push-credential diagnosis must not fire',
      );
    },
  );
}
