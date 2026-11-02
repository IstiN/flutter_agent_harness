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
    this.checkoutV7 = false,
  });

  final Directory root;
  final String origin; // the shared bare origin
  final String name;
  final String committerDate; // distinct per minter → distinct tag objects
  final bool
  pushLands; // false → the push fails without landing (genuine failure)

  /// Persist the job token the way actions/checkout **v7** does (gh-2039,
  /// run 41393469972): no repo-local extraheader key at all — a separate
  /// `git-credentials-<uuid>.config` file under RUNNER_TEMP referenced by
  /// repo-local `includeIf.gitdir:<gitdir>.path` entries. The old ≤v6
  /// local key remains in the default fixture (older checkout pins).
  final bool checkoutV7;

  /// The credentials file the v7 fixture writes (deleted by the mint's
  /// strip, mirroring the runner post-job cleanup).
  String? credentialsFile;

  late final String work;
  late final int gitCalls;
  int ghRunListCalls = 0;
  int exitCode = -1;
  String output = '';

  String get _bin => '${root.path}/bin-$name';
  String get _ghLog => '${root.path}/gh-$name.log';
  String get _gitLog => '${root.path}/git-$name.log';

  void buildFixture(String sha) {
    withSha(sha);
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
    if (checkoutV7) {
      // checkout v7 shape: the extraheader lives ONLY in a referenced
      // credentials config file; the repo-local config carries includeIf
      // entries pointing at it. (Observed verbatim in the run
      // 41393469972 post-job cleanup: "Removing includeIf entries
      // pointing to credentials config files".)
      final credsDir = '${root.path}/runner-temp';
      Directory(credsDir).createSync(recursive: true);
      final credsFile =
          '$credsDir/git-credentials-abc12df3-99aa-4c55-9d33-77c8ee52b111.config';
      File(credsFile).writeAsStringSync(
        '[http "https://github.com/"]\n'
        '\textraheader = AUTHORIZATION: basic am9iLXRva2Vu\n',
      );
      credentialsFile = credsFile;
      git([
        'config',
        'includeIf.gitdir:$work/.git.path',
        credsFile,
      ]);
      git([
        'config',
        'includeIf.gitdir:$work/.git/worktrees/*.path',
        credsFile,
      ]);
    } else {
      git([
        'config',
        'http.https://github.com/.extraheader',
        'AUTHORIZATION: basic am9iLXRva2Vu',
      ]);
    }
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
  if [ "\${GH_STUB_PROBE_STDERR:-0}" = "1" ]; then
    echo "gh: API warning: deprecation notice for a field you never asked for" >&2
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
    final p = Process.start(
      'bash',
      [File('scripts/release_tag_mint.sh').absolute.path, tag],
      workingDirectory: work,
      environment: env(),
    );
    return p.then((proc) async {
      final out = <String>[];
      out.add(await proc.stdout.transform(systemEncoding.decoder).join());
      out.add(await proc.stderr.transform(systemEncoding.decoder).join());
      exitCode = await proc.exitCode;
      output = out.join();
      final log = File(_ghLog);
      ghRunListCalls = log.existsSync()
          ? log.readAsLinesSync().where((l) => l.contains('run list')).length
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
  );
  final b = RaceMinter(
    root: root,
    origin: origin,
    name: 'b',
    committerDate: '2026-01-01T00:00:02Z',
  );
  a.buildFixture(sha);
  b.buildFixture(sha);
  return (a, b);
}

/// A seeded single-minter fixture: bare origin with one seed commit, one
/// work clone, stubs wired. [name] namespaces the minter's dirs.
/// [attachOrigin] reuses an EXISTING fixture origin (fresh work clone
/// only) — the shape of a real re-run: same repository, same target
/// commit, new checkout. The seed commit's date is deterministic per
/// fixture name, so two independently created origins can never collide
/// on the same commit sha by wall-clock accident (that collision is
/// exactly what made a cross-origin target sha pass locally and fail in
/// CI with `fatal: bad object type`).
Future<(RaceMinter, String)> _singleMinter(
  String name, {
  String? attachOrigin,
  bool checkoutV7 = false,
}) async {
  final root = Directory.systemTemp.createTempSync('mint-$name-');
  final realGit = resolveRealGit();
  final origin = attachOrigin ?? '${root.path}/origin.git';
  if (attachOrigin == null) {
    Process.runSync(realGit, [
      'init',
      '-q',
      '--bare',
      '-b',
      'main',
      origin,
    ], workingDirectory: root.path);
  }
  final seed = '${root.path}/seed';
  void git(List<String> args, {String? cwd}) {
    final r = Process.runSync(realGit, args, workingDirectory: cwd ?? seed);
    expect(r.exitCode, 0, reason: 'fixture git $args failed: ${r.stderr}');
  }

  git(['clone', '-q', origin, seed], cwd: root.path);
  git(['config', 'user.email', 't@t']);
  git(['config', 'user.name', 't']);
  if (attachOrigin == null) {
    File('$seed/README.md').writeAsStringSync('seed\n');
    git(['add', '-A']);
    final seedR = Process.runSync(
      realGit,
      ['commit', '-q', '-m', 'seed'],
      workingDirectory: seed,
      environment: {
        'GIT_COMMITTER_DATE': _seedDate(name),
        'GIT_AUTHOR_DATE': _seedDate(name),
        ...Platform.environment,
      },
    );
    expect(seedR.exitCode, 0, reason: 'seed commit failed: ${seedR.stderr}');
  }
  git(['push', '-q', 'origin', 'HEAD:main']);
  final sha = Process.runSync(realGit, [
    'rev-parse',
    'HEAD',
  ], workingDirectory: seed).stdout.toString().trim();
  final m = RaceMinter(
    root: root,
    origin: origin,
    name: name,
    committerDate: '2026-01-01T00:00:01Z',
    pushLands: name == 'noland' ? false : true,
    checkoutV7: checkoutV7,
  );
  m.buildFixture(sha);
  return (m, sha);
}

/// Distinct deterministic commit date per fixture name — two origins
/// seeded for different names hash differently, always.
String _seedDate(String name) {
  final n = name.codeUnits.fold(0, (a, c) => a + c) % 200;
  final day = (n % 28) + 1;
  final hour = n % 24;
  return '2026-02-'
      '${day.toString().padLeft(2, '0')}T'
      '${hour.toString().padLeft(2, '0')}:00:00Z';
}

void main() {
  test('PR #2029 review: a mint that loses the push race to a sibling leg continues to train verification instead of dying on the rejected push', () async {
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
        reason:
            'the ${m.name} minter must survive the race '
            '(output: ${m.output})',
      );
    }
    // Exactly one push can land; the other must have been tolerated as
    // the raced-mint case (never a bare fatal / never a red exit).
    final raced = [
      a,
      b,
    ].where((m) => m.output.contains('minted concurrently by a sibling leg'));
    expect(raced, hasLength(1), reason: 'exactly one minter lost the push');
    expect(
      [a, b].any((m) => m.output.contains('✅ tag train for v9.9.9 started')),
      isTrue,
      reason: 'the loser continues to (and passes) train verification',
    );
  });

  test('PR #2029 review: a push that fails with the ref still missing fails loud with a self-explaining error', () async {
    // The race tolerance must not swallow genuine push failures: if the
    // push fails AND the ref is still absent, nothing minted the tag —
    // the leg must go red naming the real problem, not exit 0.
    final (m, sha) = await _singleMinter('noland');
    m.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
    await m.run('v9.9.8');
    expect(m.exitCode, isNot(0), reason: m.output);
    expect(m.output, contains('::error::'));
    expect(
      m.output,
      contains('push failed and the ref is still missing'),
      reason:
          'the error must distinguish the no-land push failure '
          'from the raced-mint case',
    );
  });

  test('PR #2029 review: a failed train verification rolls the pushed tag back so a fixed re-run re-mints instead of stranding the draft', () async {
    // The v1.0.663 / v1.0.665 recovery trap: attempt 1 pushes the tag,
    // no run appears, the mint fails loud — but the tag stays on the
    // remote. The prescribed "fix the credential and re-run" then finds
    // the tag existing, skips the mint AND its train check, and the
    // caller's plain `gh release create --draft` re-arms the exact
    // stranded-draft shape (green leg, sweep a day later). The mint
    // must roll the untrained ref back (remote + the local tag object
    // that would break a reused-workspace re-tag) before failing.
    final (m, sha) = await _singleMinter('rollback');
    m.withEnv(const {'GH_STUB_TRAIN_RUNNING': '0'});

    // Attempt 1: push lands, no run ever appears → loud failure + rollback.
    await m.run('v9.9.7');
    expect(m.exitCode, isNot(0), reason: m.output);
    expect(m.output, contains('::error::tag train did not start'));
    expect(
      m.output,
      contains('rolling back the untrained tag ref'),
      reason: 'the operator must see the rollback in the log',
    );
    final realGit = resolveRealGit();
    final remoteRef = Process.runSync(realGit, [
      'ls-remote',
      '--exit-code',
      m.origin,
      'refs/tags/v9.9.7',
    ]);
    expect(
      remoteRef.exitCode,
      2,
      reason:
          'the untrained tag ref must be rolled back on the remote '
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
    // The retry attaches to the SAME origin with a fresh work clone —
    // the real re-run shape (same repository, same target commit, new
    // checkout). A cross-origin sha here is unfaithful AND flaky: two
    // independently seeded origins only shared a commit sha when their
    // wall-clock seed commits landed in the same second, which held
    // locally and broke in CI with `fatal: bad object type` at
    // `git tag -a` (validation run 41295498327, shard 3/4).
    final (m2, sha2) = await _singleMinter(
      'rollback-retry',
      attachOrigin: m.origin,
    );
    expect(
      sha2,
      sha,
      reason:
          'the retry checkout must carry the same '
          'target commit — same repository, new checkout',
    );
    m2.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
    await m2.run('v9.9.7');
    expect(m2.exitCode, 0, reason: m2.output);
    expect(m2.output, contains('✅ tag train for v9.9.7 started'));
  });

  test('PR #2029 review: a failing train probe (403 / expired PAT) fails fast and is diagnosed as a probe failure, never as a suppressed train', () async {
    // `2>/dev/null || echo 0` used to collapse a denied/failing probe
    // into "no train": the leg burned the full 12×10s budget and then
    // blamed the push credential (CI-suppressed token) while the real
    // cause — RELEASE_PAT without Actions:read, an expired PAT, a rate
    // limit — was discarded to /dev/null. A probe failure must abort
    // the budget immediately with a distinct, self-explaining error.
    final (m, _) = await _singleMinter('probe');
    m.withEnv(const {'GH_STUB_PROBE_FAILS': '1'});
    await m.run('v9.9.6');
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
      reason:
          'a failing probe must abort immediately, not burn the '
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
  });

  test('re-review lap 6: a gh warning on a healthy probe (exit 0, stderr noise) must not corrupt the numeric check — the train is still recognized, no rollback', () async {
    // The lap-3 fix captured stdout+stderr into one value; a gh warning
    // with exit 0 made `probe_out` a non-integer → "integer expression
    // expected" inside the if → read as "no train" → the budget burned
    // and the ROLLBACK DELETED a pushed tag whose train was actually
    // running. The probe must keep stderr out of the success value.
    final (m, _) = await _singleMinter('probe-warn');
    m.withEnv(const {
      'GH_STUB_PROBE_STDERR': '1',
      'GH_STUB_TRAIN_RUNNING': '1',
    });
    await m.run('v9.9.5');
    expect(m.exitCode, 0, reason: m.output);
    expect(
      m.output,
      isNot(contains('::error::train verification probe failed')),
      reason: 'exit 0 is a healthy probe — a warning is not a failure',
    );
    expect(
      m.output.contains('rolling back the untrained tag ref'),
      isFalse,
      reason: 'a noisy-but-healthy probe must never roll back the tag '
          '(output: ${m.output})',
    );
    expect(
      m.output.contains('integer expression'),
      isFalse,
      reason: 'the numeric check must hold despite the stderr noise',
    );
    expect(
      m.output,
      contains('✅ tag train for v9.9.5 started'),
      reason: 'the train is recognized despite the stderr noise '
          '(output: ${m.output})',
    );
  });

  test('gh-2039: checkout v7 includeIf-persisted credentials are stripped — the extraheader must no longer resolve and the credentials file must be deleted', () async {
    // Run 41393469972 (v1.0.682, 2026-11-02): actions/checkout v7 no
    // longer writes the job token as a repo-local extraheader key. It
    // writes a `git-credentials-<uuid>.config` file under RUNNER_TEMP
    // and references it from repo-local `includeIf.gitdir:<gitdir>.path`
    // entries. Guard 1's `git config --local --unset-all` then had
    // nothing to unset — `--get-regexp` LISTS the key (git resolves it
    // through the include) but the key only EXISTS in the included file,
    // so the repo-local unset silently no-op'd (`|| true`), the
    // Authorization header still rode the push, GitHub classed the
    // credential as GITHUB_TOKEN, and no tag train ever fired.
    //
    // The strip must mirror the runner's post-job cleanup: remove every
    // includeIf entry pointing at a git-credentials-*.config file,
    // delete that file, and leave the effective extraheader resolving to
    // nothing. The wire-observable is `git config --get` (local +
    // includes + global) — exactly what git puts on the wire.
    final (m, _) = await _singleMinter('v7creds', checkoutV7: true);
    final realGit = resolveRealGit();
    String effectiveExtraheader() {
      final r = Process.runSync(realGit, [
        'config',
        '--get',
        'http.https://github.com/.extraheader',
      ], workingDirectory: m.work);
      return r.stdout.toString().trim();
    }

    // Fixture sanity: without any strip the header resolves through the
    // includeIf chain — the pre-fix failure shape.
    expect(
      effectiveExtraheader(),
      'AUTHORIZATION: basic am9iLXRva2Vu',
      reason: 'the v7 fixture must carry a RESOLVING extraheader '
          '(nothing stripped yet)',
    );

    m.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
    await m.run('v9.9.4');
    expect(m.exitCode, 0, reason: m.output);
    expect(m.output, contains('✅ tag train for v9.9.4 started'));
    expect(
      effectiveExtraheader(),
      isEmpty,
      reason:
          'the extraheader must no longer resolve after the strip — '
          'this is the credential GitHub sees on the wire. Residual: '
          'the mint would push as GITHUB_TOKEN and the train would '
          'never fire (gh-2039).',
    );
    expect(
      m.credentialsFile,
      isNotNull,
    );
    expect(
      File(m.credentialsFile!).existsSync(),
      isFalse,
      reason: 'the referenced credentials config file must be deleted '
          '(the runner post-job cleanup deletes it too)',
    );
    final includeKeys = Process.runSync(realGit, [
      'config',
      '--local',
      '--name-only',
      '--get-regexp',
      'includeIf\\.gitdir:',
    ], workingDirectory: m.work);
    expect(
      (includeKeys.stdout as String).trim(),
      isEmpty,
      reason: 'includeIf entries pointing at git-credentials files must '
          'be removed from the repo-local config '
          '(stderr: ${includeKeys.stderr})',
    );
    // The push must still land with the URL credentials (the strip must
    // not break the mint itself): the train check passed above AND the
    // ref exists on the shared origin.
    final ref = Process.runSync(realGit, [
      'ls-remote',
      '--exit-code',
      m.origin,
      'refs/tags/v9.9.4',
    ]);
    expect(ref.exitCode, 0, reason: 'the minted tag must be on the remote');
  });

  test('gh-2039 Guard 1c: an Authorization header that STILL resolves after the strips (global gitconfig scope) fails loud BEFORE the push — no tag is pushed, no probe runs', () async {
    // The strips can only unset the LOCAL config; a header persisted in
    // a scope the mint must not touch (the runner user's global
    // gitconfig, or a future checkout persistence shape) would ride the
    // wire exactly like the v7 include did — pushing anyway mints a
    // GITHUB_TOKEN-classed tag that rolls back only after the full
    // verification budget. The residual header must abort the mint
    // before the push, naming the residual origin.
    final (m, _) = await _singleMinter('residual');
    // Runner-user scope: a GLOBAL extraheader the local strip cannot
    // reach (HOME is the fixture root).
    File('${m.root.path}/.gitconfig').writeAsStringSync(
      '[http "https://github.com/"]\n'
      '\textraheader = AUTHORIZATION: basic am9iLXRva2Vu\n',
    );
    m.withEnv(const {'GH_STUB_TRAIN_RUNNING': '1'});
    await m.run('v9.9.3');
    expect(m.exitCode, isNot(0), reason: m.output);
    expect(
      m.output,
      contains('persisted Authorization header still resolves'),
    );
    expect(
      m.output,
      contains('.gitconfig'),
      reason: 'the error must name the residual origin (show-origin) '
          'so the operator can remove exactly that header',
    );
    expect(
      m.output,
      contains('::error::'),
    );
    final realGit = resolveRealGit();
    final ref = Process.runSync(realGit, [
      'ls-remote',
      '--exit-code',
      m.origin,
      'refs/tags/v9.9.3',
    ]);
    expect(
      ref.exitCode,
      2,
      reason: 'the mint must abort BEFORE the push — no tag on the remote',
    );
    expect(
      m.ghRunListCalls,
      0,
      reason: 'aborting before the push means no train verification budget',
    );
  });
}
