// gh-2372 — twin-draft race reproduction + self-dedupe contract.
//
// Root cause (outputs/rca.md): inside ONE build-macos.yml run the sibling
// jobs (build-macos-cli-arm64/x64 + build-extension) race
// release_lazy_draft.sh / release_attach_or_create.sh for the same tag.
// When their view→create calls interleave inside the race window (same
// second in production), BOTH `gh release create --draft` calls SUCCEED —
// GitHub does not enforce one release per tag for drafts — and two twin
// drafts are born. The tag train publishes exactly one; the twin rots
// 24h+ until the daily sweeper deletes it and re-files the recurring
// "[daily-publish] stale release drafts swept" issue (v1.0.760 swept by
// gh-2372; v1.0.763's live twin 454339915 carried ZERO assets).
//
// No existing guard covers the shape: every creating job SUCCEEDED (the
// failure-path guards never fire) and release_draft_dedupe.sh matches
// only twins stamped with the TRAIN's run id — child-run twins are
// invisible to it. The fix: after a successful draft create the creator
// self-deletes its OWN just-created draft when an OLDER pipeline-created
// release for the same tag exists (deterministic winner: lowest id =
// first created keeps the tag; the loser attaches into the winner by
// tag — the gh-1801 tolerance contract, now actually true).
//
// Fixture style follows release_mint_test_support.dart: bare origin +
// work clone (tag seeded so no mint path), a stateful `gh` stub serving
// the release roster, and a pass-through git shim.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('release-twin-');

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

/// A release object for the stub roster.
Map<String, Object> release(
  int id, {
  required String tag,
  required bool draft,
  String? marker,
  String authorLogin = 'IstiN',
  String authorType = 'User',
}) => {
  'id': id,
  'tag_name': tag,
  'draft': draft,
  'created_at': '2026-11-21T05:29:27Z',
  'author': {'login': authorLogin, 'type': authorType},
  'body':
      'Release $tag\n'
      '${marker == null ? '' : '<!-- release-draft-owner: $marker -->'}',
};

class TwinRun {
  TwinRun(this.exitCode, this.output, this.log);
  final int exitCode;
  final String output;
  final List<String> log;
}

/// Runs [script] over the twin fixture: bare origin + clone with [tag]
/// seeded (ls-remote rc 0 — the mint path is skipped), a `gh` stub whose
/// view always MISSES (the race window: the sibling's draft is not
/// visible yet) and whose create SUCCEEDS, with the post-create roster
/// served from releases.json.
TwinRun runTwinFixture(
  String script, {
  required List<String> args,
  required String name,
  required String tag,
  required List<Map<String, Object>> roster,
  String githubRunId = '222',
  String githubJob = 'build-macos-cli-arm64',
  String? identity = 'run/222/job/build-macos-cli-arm64',
  bool deleteFails = false,
  List<String> viewSeq = const [],
  String? winnerBody,
  String? releaseState,
  List<String> resolvedAssets = const [],
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/twin-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = Directory('${dir.path}/bin')..createSync(recursive: true);
  final realGit = _resolveRealGit();

  File('${dir.path}/releases.json').writeAsStringSync(_rosterJson(roster));
  if (deleteFails) File('${dir.path}/delete-fails').writeAsStringSync('x');
  // Post-create view world (gh-2372 rework): the scripted plain-view
  // sequence models the race window (missing = the pre-create view, the
  // sibling's object is not visible yet) and the structured answers model
  // the release the tag resolves to AFTER the create + dedupe (the
  // election winner — body/state/assets the fall-through attach reads).
  if (viewSeq.isNotEmpty) {
    File(
      '${dir.path}/view-seq.txt',
    ).writeAsStringSync(viewSeq.map((w) => '$w\n').join());
  }
  if (winnerBody != null) {
    File('${dir.path}/release-body.txt').writeAsStringSync(winnerBody);
  }
  if (releaseState != null) {
    File('${dir.path}/release-state.txt').writeAsStringSync(releaseState);
  }
  if (resolvedAssets.isNotEmpty) {
    File(
      '${dir.path}/asset-names.txt',
    ).writeAsStringSync(resolvedAssets.map((a) => '$a\n').join());
  }

  File('${bin.path}/gh').writeAsStringSync(r'''
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG_FILE"
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  # Scripted plain-view sequence (one word per call, popped off the top):
  # "missing" models the race window (the pre-create view), "exists" a
  # resolving release. An exhausted/absent sequence falls through to the
  # structured answers below — the post-create attach flow asks
  # body / isDraft+assets / assets about the release the tag resolves to.
  if [ -s "$GH_STUB_DIR/view-seq.txt" ]; then
    w=$(head -1 "$GH_STUB_DIR/view-seq.txt")
    sed -i.bak '1d' "$GH_STUB_DIR/view-seq.txt" && rm -f "$GH_STUB_DIR/view-seq.txt.bak"
    [ "$w" = "exists" ] && exit 0
    echo "release not found (stub: race window — the sibling's draft is not visible)" >&2
    exit 1
  fi
  case " $*" in
    *--json\ body*)
      if [ -s "$GH_STUB_DIR/release-body.txt" ]; then
        cat "$GH_STUB_DIR/release-body.txt"
      else
        echo ""
      fi
      ;;
    *--json\ isDraft,assets*)
      st="true"
      [ -s "$GH_STUB_DIR/release-state.txt" ] && st="$(cat "$GH_STUB_DIR/release-state.txt")"
      objs=""
      if [ -s "$GH_STUB_DIR/asset-names.txt" ]; then
        while IFS= read -r n; do
          [ -n "$n" ] && objs="$objs{\"name\":\"$n\"},"
        done < "$GH_STUB_DIR/asset-names.txt"
      fi
      objs="${objs%,}"
      printf '{"isDraft":%s,"assets":[%s]}\n' "$st" "$objs"
      ;;
    *--json\ assets*) cat "$GH_STUB_DIR/asset-names.txt" 2>/dev/null || echo "" ;;
    *)
      if [ -s "$GH_STUB_DIR/release-state.txt" ]; then exit 0; fi
      echo "release not found (stub: race window — the sibling's draft is not visible)" >&2
      exit 1
      ;;
  esac
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "create" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--notes-file" ] && [ -f "$a" ]; then
      cp "$a" "$GH_STUB_DIR/notes-capture.md" 2>/dev/null || true
    fi
    prev="$a"
  done
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "-X" ] && [ "$3" = "DELETE" ]; then
  if [ -f "$GH_STUB_DIR/delete-fails" ]; then
    echo "gh: HTTP 502 (stub: delete blip)" >&2
    exit 1
  fi
  exit 0
fi
if [ "$1" = "api" ]; then
  case "$*" in
    *repos/OWNER/REPO/releases*) cat "$GH_STUB_DIR/releases.json" ;;
    *) : ;;
  esac
  exit 0
fi
exit 0
''');
  Process.runSync('chmod', ['+x', '${bin.path}/gh']);

  final origin = '${dir.path}/origin.git';
  final work = '${dir.path}/work';
  void git(List<String> gitArgs, {String? cwd}) {
    final r = Process.runSync(realGit, gitArgs, workingDirectory: cwd ?? work);
    expect(r.exitCode, 0, reason: 'fixture git $gitArgs failed: ${r.stderr}');
  }

  git(['init', '-q', '--bare', '-b', 'main', origin], cwd: dir.path);
  git(['clone', '-q', origin, work], cwd: dir.path);
  git(['config', 'user.email', 't@t']);
  git(['config', 'user.name', 't']);
  File('$work/README.md').writeAsStringSync('seed\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'seed']);
  git(['push', '-q', 'origin', 'main']);
  git(['tag', '-a', tag, '-m', tag]);
  git(['push', '-q', 'origin', 'refs/tags/$tag']);
  // An attach-path asset (the zero-asset refusal demands at least one).
  File('$work/fa-fake.tar.gz').writeAsStringSync('fake\n');

  File('${bin.path}/git').writeAsStringSync(
    '#!/usr/bin/env bash\n'
    'echo "\$*" >> "\${FA_TWIN_GIT_LOG:-/dev/null}"\n'
    'exec "\$FA_REAL_GIT" "\$@"\n',
  );
  Process.runSync('chmod', ['+x', '${bin.path}/git']);

  File('${dir.path}/gh.log').writeAsStringSync('');
  // gh-2372 fixtures pass an explicit leg-suffixed identity; null falls
  // back to the script's own run/job default (mirrors production).
  final draftIdentity = identity ?? 'run/$githubRunId/job/$githubJob';
  final env = <String, String>{
    'PATH': '${bin.path}:${Platform.environment['PATH']!}',
    'HOME': dir.path,
    'GITHUB_REPOSITORY': 'OWNER/REPO',
    'GITHUB_RUN_ID': githubRunId,
    'GITHUB_JOB': githubJob,
    'GH_LOG_FILE': '${dir.path}/gh.log',
    'GH_STUB_DIR': dir.path,
    'FA_REAL_GIT': realGit,
    'FA_TWIN_GIT_LOG': '${dir.path}/git.log',
    'RELEASE_DRAFT_IDENTITY': draftIdentity,
    // This session exports a real GH_TOKEN; keep fixtures hermetic.
    'GH_TOKEN': 'pat-token-for-test',
  };
  final scriptPath = File(script).absolute.path;
  final res = Process.runSync(
    'bash',
    [scriptPath, ...args],
    workingDirectory: work,
    environment: env,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final log = File('${dir.path}/gh.log').readAsLinesSync();
  return TwinRun(res.exitCode, '${res.stdout}${res.stderr}', log);
}

String _rosterJson(List<Map<String, Object>> roster) {
  final items = roster
      .map(
        (r) =>
            '{"id":${r['id']},"tag_name":"${r['tag_name']}","draft":${r['draft']}'
            ',"created_at":"${r['created_at']}","author":{"login":"${(r['author'] as Map)['login']}","type":"${(r['author'] as Map)['type']}"}'
            ',"body":${jsonBody(r['body'] as String)}}',
      )
      .join(',');
  return '[$items]';
}

/// Minimal JSON string encoder for the fixed bodies the fixture writes.
String jsonBody(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';

void main() {
  const tag = 'v1.2.3';
  const mine = 'run/222/job/build-macos-cli-arm64';
  const winnerMarker = 'run/77/job/build-extension';

  test(
    'gh-2372: the lazy-draft LOSER self-deletes its own twin when an older pipeline draft owns the tag',
    () {
      final r = runTwinFixture(
        'scripts/release_lazy_draft.sh',
        args: const [tag],
        name: 'lazy-loser',
        tag: tag,
        roster: [
          release(500, tag: tag, draft: true, marker: winnerMarker),
          release(1001, tag: tag, draft: true, marker: mine),
        ],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.log.join('\n'),
        contains('api -X DELETE repos/OWNER/REPO/releases/1001'),
        reason: 'OUR twin (id 1001, our exact marker) is deleted by id',
      );
      expect(
        r.log.join('\n'),
        isNot(contains('releases/500')),
        reason: 'the older winner draft (id 500) is never touched',
      );
      expect(
        r.output,
        contains('✅ lazy draft ready'),
        reason:
            'the tolerant contract holds — the caller attaches into the winner',
      );
    },
  );

  test(
    'gh-2372: the WINNER (no older pipeline release on the tag) keeps its draft',
    () {
      final r = runTwinFixture(
        'scripts/release_lazy_draft.sh',
        args: const [tag],
        name: 'lazy-winner',
        tag: tag,
        roster: [release(1001, tag: tag, draft: true, marker: mine)],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.log.where((l) => l.contains('-X DELETE')),
        isEmpty,
        reason: 'no twin — nothing may be deleted',
      );
    },
  );

  test(
    'gh-2372: an older HUMAN (unmarked) draft never triggers a self-delete and is never touched (E1)',
    () {
      final r = runTwinFixture(
        'scripts/release_lazy_draft.sh',
        args: const [tag],
        name: 'lazy-human',
        tag: tag,
        roster: [
          release(900, tag: tag, draft: true, authorType: 'User'),
          release(1001, tag: tag, draft: true, marker: mine),
        ],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.log.where((l) => l.contains('-X DELETE')),
        isEmpty,
        reason:
            'human drafts never win the election (no marker) and the '
            'pipeline never deletes them — our draft stays',
      );
    },
  );

  test(
    'gh-2372: an older PUBLISHED release on the tag (the train flipped the sibling) wins — ours is deleted',
    () {
      final r = runTwinFixture(
        'scripts/release_lazy_draft.sh',
        args: const [tag],
        name: 'lazy-published',
        tag: tag,
        roster: [
          release(300, tag: tag, draft: false, marker: winnerMarker),
          release(1001, tag: tag, draft: true, marker: mine),
        ],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.log.join('\n'),
        contains('api -X DELETE repos/OWNER/REPO/releases/1001'),
        reason:
            'a draft created after the tag is already published is a '
            'proven orphan — uploads resolve the published object',
      );
    },
  );

  test(
    'gh-2372: a twin-delete API blip stays best-effort — the create path stays green',
    () {
      final r = runTwinFixture(
        'scripts/release_lazy_draft.sh',
        args: const [tag],
        name: 'lazy-delete-blip',
        tag: tag,
        roster: [
          release(500, tag: tag, draft: true, marker: winnerMarker),
          release(1001, tag: tag, draft: true, marker: mine),
        ],
        deleteFails: true,
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.output, contains('::warning::'));
      expect(
        r.output,
        contains('✅ lazy draft ready'),
        reason:
            'a cleanup blip must never red a green leg (gh-1899 convention)',
      );
    },
  );

  test(
    'gh-2372 rework: the attach-path LOSER lands its assets on the winner IN THE SAME RUN — the self-delete must not bury the create-carried uploads',
    () {
      final r = runTwinFixture(
        'scripts/release_attach_or_create.sh',
        args: const [tag, 'fa-fake.tar.gz'],
        name: 'attach-loser-same-run',
        tag: tag,
        roster: [
          release(500, tag: tag, draft: true, marker: winnerMarker),
          release(1001, tag: tag, draft: true, marker: mine),
        ],
        // The race window: the pre-create view misses (the sibling's
        // object is not visible yet), so the script takes the create path.
        viewSeq: const ['missing'],
        // After create + dedupe the tag resolves to the WINNER (sibling
        // draft, zero assets on it).
        winnerBody: 'Release $tag\n<!-- release-draft-owner: $winnerMarker -->',
        resolvedAssets: const [],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.log.join('\n'),
        contains('api -X DELETE repos/OWNER/REPO/releases/1001'),
        reason: 'our twin is self-deleted — the election loser',
      );
      expect(
        r.log.join('\n'),
        contains('release upload $tag fa-fake.tar.gz'),
        reason:
            'the create carried the assets onto OUR twin — once the twin is '
            'self-deleted they exist on the winner only if this leg '
            're-attaches them in the SAME run (the gh-1801 tolerance '
            'contract docs/ci.md claims); before the rework they silently '
            'waited for a rerun-attach',
      );
      expect(r.output, contains('lost the twin election'));
      expect(
        r.output,
        isNot(contains('✅ created draft release $tag')),
        reason: 'our draft is gone — reporting a created draft would be a lie',
      );
    },
  );

  test(
    'gh-2372 rework: the attach-path WINNER (our draft survived the dedupe) keeps the create-carried assets — no double attach',
    () {
      final r = runTwinFixture(
        'scripts/release_attach_or_create.sh',
        args: const [tag, 'fa-fake.tar.gz'],
        name: 'attach-winner-keeps',
        tag: tag,
        roster: [release(1001, tag: tag, draft: true, marker: mine)],
        viewSeq: const ['missing'],
        // The tag resolves to OUR OWN draft (its body carries our marker).
        winnerBody: 'Release $tag\n<!-- release-draft-owner: $mine -->',
        resolvedAssets: const ['fa-fake.tar.gz'],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.log.where((l) => l.contains('-X DELETE')), isEmpty);
      expect(
        r.log.where((l) => l.contains('release upload')),
        isEmpty,
        reason:
            'the create already carried the assets onto our draft — the '
            'fall-through attach must not re-run for our own release '
            '(the happy path stays free of a full asset re-upload)',
      );
      expect(r.output, contains('✅ created draft release $tag'));
    },
  );

  test(
    'gh-2372: the dedupe script alone is a no-op when our draft is already gone',
    () {
      final r = runTwinFixture(
        'scripts/release_draft_twin_dedupe.sh',
        args: const [tag],
        name: 'dedupe-noop',
        tag: tag,
        roster: [release(500, tag: tag, draft: true, marker: winnerMarker)],
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.log.where((l) => l.contains('-X DELETE')), isEmpty);
    },
  );

  test(
    'gh-2372: a malformed RELEASE_DRAFT_IDENTITY fails loud — the marker could never be matched',
    () {
      final r = runTwinFixture(
        'scripts/release_draft_twin_dedupe.sh',
        args: const [tag],
        name: 'dedupe-bad-identity',
        tag: tag,
        identity: 'run/222/job/has spaces',
        roster: [release(1001, tag: tag, draft: true, marker: mine)],
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.output, contains('::error::'));
    },
  );

  test(
    'gh-2372: both creator scripts invoke the twin dedupe right after their successful creates',
    () {
      final lazy = File('scripts/release_lazy_draft.sh').readAsStringSync();
      final attach = File(
        'scripts/release_attach_or_create.sh',
      ).readAsStringSync();
      final dedupe = File(
        'scripts/release_draft_twin_dedupe.sh',
      ).readAsStringSync();
      expect(dedupe, contains('release-draft-owner'));
      for (final entry in {'lazy': lazy, 'attach': attach}.entries) {
        final src = entry.value;
        final createIdx = src.indexOf('gh release create');
        final dedupeIdx = src.indexOf('release_draft_twin_dedupe.sh');
        expect(
          dedupeIdx,
          greaterThan(createIdx),
          reason:
              '${entry.key}: the self-dedupe must run after the create '
              '(a create that never happened has nothing of ours to clean)',
        );
        expect(
          src.indexOf('exit 0', dedupeIdx),
          greaterThan(dedupeIdx),
          reason: '${entry.key}: the dedupe runs before the create-path exit',
        );
      }
      // gh-2372 rework: the attach create CARRIED the assets — after the
      // dedupe self-deletes our lost twin, the SAME run must re-attach
      // them into the winner (the E3 upload_all block), not exit green
      // with the assets buried in the deleted draft. The E3 block's own
      // upload_all only covers a FAILED create — the fall-through must
      // live INSIDE the create-success branch (before the E3 comment).
      final attachAfterCreate = attach.substring(
        attach.indexOf('gh release create "\$tag"'),
      );
      final dedupeAt = attachAfterCreate.indexOf(
        'release_draft_twin_dedupe.sh',
      );
      final e3At = attachAfterCreate.indexOf('# E3 idempotency');
      expect(dedupeAt, greaterThan(-1));
      expect(e3At, greaterThan(dedupeAt));
      expect(
        attachAfterCreate.indexOf('upload_all', dedupeAt),
        inInclusiveRange(dedupeAt, e3At),
        reason:
            'attach: after the create-success dedupe the loser must fall '
            'through to upload_all — the assets it just uploaded die with '
            'the self-deleted twin otherwise (the E3 upload_all only '
            'covers a FAILED create)',
      );
    },
  );
}
