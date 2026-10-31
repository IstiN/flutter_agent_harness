// gh-1899 — post-publish orphan-draft twin cleanup.
//
// The daily sweep kept filing "[daily-publish] stale release drafts swept"
// (gh-1899) because the lazy draft create's tolerated view→create race is
// NOT rejected by GitHub: run 40163369302 (v1.0.641, fully green) created
// TWO draft releases for the same tag 87 ms apart — both binaries legs
// logged "✅ lazy draft ready for v1.0.641" (duplicate-tag precedent in
// the repo: v0.1.120 ids 363745676/363745677, created the same second).
// release-provenance flips exactly ONE object to --draft=false --latest;
// the twin stays a draft forever — no failure-path guard can fire because
// every creating leg SUCCEEDED — so the only reclaimer was the 24h
// sweeper, which deleted the twin and filed the recurring sweep issue.
//
// scripts/release_draft_dedupe.sh is the missing lifecycle guard (issue
// #282): called AFTER the publish flip, when the tag's release is
// published and servable, it deletes every leftover DRAFT for the same
// tag stamped with THIS run's ownership marker (a proven orphan twin —
// unpublished-only assets, issue #282 E2). Foreign-run and unmarked
// drafts keep the ownership discipline of scripts/release_draft_guard.sh
// (left for the 24h sweeper); a tag with NO published release is left
// untouched (the recovery window for `gh run rerun --failed`).
//
// These tests pin the behavior against a stubbed `gh` (same style as
// release_hygiene_test.dart) plus static wiring lints over ci.yml and
// release_attach_or_create.sh.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

final _fixtureRoot = Directory.systemTemp.createTempSync('release-dedupe-');

/// One release object per entry; [draft]/[body] default to a published
/// empty-bodied release.
String releasesJson(List<Map<String, Object?>> releases, {int perPage = 100}) {
  // The real script pages with `gh api --paginate` (one JSON array per
  // page); emit the same shape so the jq per-page filter sees reality,
  // including a multi-page run for the multi-item case.
  final pages = <List<Map<String, Object?>>>[];
  for (var i = 0; i < releases.length; i += perPage) {
    pages.add(
      releases.sublist(
        i,
        i + perPage > releases.length ? releases.length : i + perPage,
      ),
    );
  }
  return pages.map(jsonEncode).join('\n');
}

class DedupeRun {
  DedupeRun(this.exitCode, this.out, this.log);
  final int exitCode;
  final String out;
  final List<String> log;
}

/// Runs scripts/release_draft_dedupe.sh against a stubbed `gh` whose
/// `gh api --paginate repos/OWNER/REPO/releases` serves [releasesJson]
/// and logs every invocation.
DedupeRun runDedupe(
  String name, {
  required String releasesJsonText,
  String tag = 'v1.2.3',
  String runId = '111',
  String job = 'release-provenance',
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = '${dir.path}/bin';
  Directory(bin).createSync();
  File('$bin/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ "\$1" = "api" ]; then
  if [ "\$2" = "-X" ] && [ "\$3" = "DELETE" ]; then
    exit 0
  fi
  cat "\$GH_STUB_DIR/releases.json"
fi
exit 0
''');
  Process.runSync('chmod', ['+x', '$bin/gh']);
  File('${dir.path}/releases.json').writeAsStringSync(releasesJsonText);
  File('${dir.path}/log').writeAsStringSync('');
  final res = Process.runSync(
    'bash',
    [File('scripts/release_draft_dedupe.sh').absolute.path, tag],
    workingDirectory: Directory.current.path,
    environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GITHUB_RUN_ID': runId,
      'GITHUB_JOB': job,
    },
  );
  return DedupeRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/log').readAsLinesSync(),
  );
}

Map<String, Object?> release({
  required int id,
  required String tag,
  bool draft = false,
  String? owner,
}) => {
  'id': id,
  'tag_name': tag,
  'draft': draft,
  'created_at': '2026-10-25T04:50:47Z',
  'author': {'login': 'github-actions[bot]', 'type': 'Bot'},
  'body': owner == null
      ? 'notes'
      : 'notes\n<!-- release-draft-owner: $owner -->\n',
};

/// Runs scripts/release_attach_or_create.sh against a stubbed `gh` where
/// the tag's release EXISTS and is fa-update-servable (SHA256SUMS on it),
/// so `upload_all` reaches the publish flip and then the dedupe. When
/// [dedupeDeleteFails] is set, the stub's `gh api -X DELETE` exits 1 —
/// the cleanup-only API blip AFTER the flip from the review thread.
DedupeRun runAttachServable(
  String name, {
  required String releasesJsonText,
  bool dedupeDeleteFails = false,
  String tag = 'v1.2.3',
  String runId = '111',
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/attach-$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = '${dir.path}/bin';
  Directory(bin).createSync();
  File('$bin/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ "\$1" = "release" ]; then
  case "\$2" in
    view)
      # Both call shapes: `gh release view <tag> --repo R` (existence) and
      # `gh release view <tag> --repo R --json assets --jq ...`
      # (servability probe — must report the signed checksums).
      case "\$*" in
        *--json*) echo "SHA256SUMS" ;;
      esac
      exit 0 ;;
    upload|edit)
      exit 0 ;;
  esac
fi
if [ "\$1" = "api" ]; then
  if [ "\$2" = "-X" ] && [ "\$3" = "DELETE" ]; then
    [ "\$GH_STUB_DELETE_FAIL" = "1" ] && exit 1
    exit 0
  fi
  cat "\$GH_STUB_DIR/releases.json"
fi
exit 0
''');
  Process.runSync('chmod', ['+x', '$bin/gh']);
  File('${dir.path}/releases.json').writeAsStringSync(releasesJsonText);
  File('${dir.path}/log').writeAsStringSync('');
  final res = Process.runSync(
    'bash',
    [File('scripts/release_attach_or_create.sh').absolute.path, tag, 'a.zip'],
    workingDirectory: Directory.current.path,
    environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir.path,
      'GH_STUB_DELETE_FAIL': dedupeDeleteFails ? '1' : '0',
      'GH_LOG_FILE': '${dir.path}/log',
      'GITHUB_RUN_ID': runId,
      'GITHUB_JOB': 'binaries-linux-arm64',
    },
  );
  return DedupeRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('${dir.path}/log').readAsLinesSync(),
  );
}

void main() {
  group('release_draft_dedupe.sh — reclaims own-run twin drafts', () {
    test('two own-run twin drafts of the published tag are deleted by id; nothing else is touched', () {
      final run = runDedupe(
        'twins',
        releasesJsonText: releasesJson([
          release(id: 1, tag: 'v1.2.3'), // the published release
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/111/job/binaries-linux-arm64',
          ),
          release(
            id: 3,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/111/job/binaries-macos-arm64',
          ),
          release(id: 4, tag: 'v9.9.9', draft: true, owner: 'run/111/job/x'),
        ]),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(
        run.log,
        contains('api -X DELETE repos/OWNER/REPO/releases/2'),
        reason: 'the first own-run twin must be deleted',
      );
      expect(
        run.log,
        contains('api -X DELETE repos/OWNER/REPO/releases/3'),
        reason: 'the second own-run twin must be deleted too (2+ items)',
      );
      expect(
        run.log.where((l) => l.contains('-X DELETE')),
        hasLength(2),
        reason:
            'exactly the two twins — the published release and the '
            'other tag\'s draft must survive',
      );
      expect(run.out, contains('gh-1899'));
    });

    test('foreign-run and unmarked drafts are never deleted (ownership discipline)', () {
      final run = runDedupe(
        'foreign',
        releasesJsonText: releasesJson([
          release(id: 1, tag: 'v1.2.3'),
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/999/job/binaries-linux-arm64',
          ),
          release(id: 3, tag: 'v1.2.3', draft: true),
        ]),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(
        run.log.where((l) => l.contains('-X DELETE')),
        isEmpty,
        reason:
            'a sibling run\'s mid-upload draft and an unmarked legacy '
            'draft are left for the 24h sweeper — the exact rule '
            'release_draft_guard.sh enforces',
      );
    });

    test('no published release for the tag → nothing deleted (recovery window stays open)', () {
      // A red provenance (e.g. the gh-1832 gate) leaves the draft on
      // purpose so `gh run rerun --failed` can recover it — the dedupe
      // guard must NOT take that draft away just because it carries
      // this run's marker.
      final run = runDedupe(
        'unpublished',
        releasesJsonText: releasesJson([
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/111/job/binaries-linux-arm64',
          ),
        ]),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(
        run.log.where((l) => l.contains('-X DELETE')),
        isEmpty,
        reason:
            'post-publish guard: without a published release the draft '
            'is the recovery vessel, never sweep food',
      );
      expect(run.out, contains('no published release'));
    });

    test('no drafts at all → clean no-op', () {
      final run = runDedupe(
        'clean',
        releasesJsonText: releasesJson([release(id: 1, tag: 'v1.2.3')]),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(run.log.where((l) => l.contains('-X DELETE')), isEmpty);
      expect(run.out, contains('nothing to reclaim'));
    });

    test('run-id prefix trap: run/1111 is not run/111', () {
      final run = runDedupe(
        'prefix',
        releasesJsonText: releasesJson([
          release(id: 1, tag: 'v1.2.3'),
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/1111/job/binaries-linux-arm64',
          ),
        ]),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(
        run.log.where((l) => l.contains('-X DELETE')),
        isEmpty,
        reason: 'run id 1111 must not be mistaken for 111',
      );
    });

    test('multi-page listing still finds and deletes the twin', () {
      final run = runDedupe(
        'paged',
        releasesJsonText: releasesJson([
          for (var i = 10; i < 30; i++) release(id: i, tag: 'v0.0.$i'),
          release(id: 1, tag: 'v1.2.3'),
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/111/job/binaries-linux-arm64',
          ),
        ], perPage: 10),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(run.log, contains('api -X DELETE repos/OWNER/REPO/releases/2'));
    });
  });

  group('wiring — the dedupe runs at every publish flip', () {
    test('ci.yml release-provenance reclaims twins AFTER the publish flip', () {
      final jobs =
          loadYaml(read('.github/workflows/ci.yml'))['jobs'] as YamlMap;
      final provenance = jobs['release-provenance'] as YamlMap;
      final steps = (provenance['steps'] as YamlList)
          .map((s) => s as YamlMap)
          .toList();
      final flipIdx = steps.indexWhere(
        (s) => s['run']?.toString().contains('--draft=false --latest') ?? false,
      );
      expect(
        flipIdx,
        isNot(-1),
        reason:
            'the provenance publish flip must exist (the dedupe guard is '
            'meaningful only after it)',
      );
      final dedupeIdx = steps.indexWhere(
        (s) =>
            s['run']?.toString().contains('release_draft_dedupe.sh') ?? false,
      );
      expect(
        dedupeIdx,
        isNot(-1),
        reason:
            'gh-1899: the provenance job must reclaim own-run twin drafts '
            'once the tag is published (v1.0.641 left one to rot 24h)',
      );
      expect(
        dedupeIdx,
        greaterThan(flipIdx),
        reason:
            'the dedupe must run AFTER the flip — before it, a leftover '
            'draft is the recovery vessel, not an orphan',
      );
      expect(
        steps[dedupeIdx]['if']?.toString() ?? '',
        isNot(contains('always()')),
        reason:
            'cleanup only on the success path — a red provenance keeps '
            'the draft for rerun --failed recovery (gh-1832)',
      );
    });

    test('release_attach_or_create.sh reclaims twins after its servable-recovery flip', () {
      final script = read('scripts/release_attach_or_create.sh');
      final flip = script.indexOf(
        'gh release edit "\$tag" --draft=false --latest',
      );
      expect(flip, isNot(-1), reason: 'the recovery flip must exist');
      final dedupe = script.indexOf('release_draft_dedupe.sh');
      expect(
        dedupe,
        isNot(-1),
        reason:
            'the daily legs\' servable-recovery publish must reclaim '
            'twin drafts too — the race is in the shared lazy create, '
            'not the train only',
      );
      expect(
        dedupe,
        greaterThan(flip),
        reason: 'dedupe only after the publish flip',
      );
    });

    test('draft lifecycle roster: guard (failure) + dedupe (post-publish)', () {
      // The two halves of the issue #282 invariant, next to each other:
      // a run ends with its draft published or deleted — never orphaned.
      // The failure half lives in release_draft_guard.sh (AC1-pinned);
      // gh-1899 adds the success half.
      final guard = read('scripts/release_draft_guard.sh');
      expect(guard, contains('release-draft-owner'));
      final dedupe = read('scripts/release_draft_dedupe.sh');
      expect(dedupe, contains('release-draft-owner'));
      expect(dedupe, contains('GITHUB_RUN_ID'));
      expect(
        dedupe,
        isNot(contains('gh release delete "\$tag"')),
        reason:
            'delete by release id via the API (the sweeper\'s rule) — '
            'a tag-based delete is ambiguous under duplicate releases, '
            'the very class this guard exists for',
      );
    });
  });

  group(
    'best-effort failure mode — a dedupe blip never reds a published release',
    () {
      test('failing DELETE after a successful flip keeps the attach leg green with a ::warning:: (review thread 1)', () {
        // RED-first pin for the review finding: upload_all runs under
        // `set -euo pipefail`, so a cleanup-only API failure AFTER the
        // publish flip used to propagate as a red leg for a release that
        // is published and servable. Best-effort: warn, stay green — the
        // 24h sweeper remains the backstop.
        final run = runAttachServable(
          'dedupe-fails',
          releasesJsonText: releasesJson([
            release(id: 1, tag: 'v1.2.3'),
            release(
              id: 2,
              tag: 'v1.2.3',
              draft: true,
              owner: 'run/111/job/binaries-macos-arm64',
            ),
          ]),
          dedupeDeleteFails: true,
        );
        expect(
          run.exitCode,
          0,
          reason:
              'the flip already succeeded — the release is published and '
              'servable; a transient DELETE failure is notification noise, '
              'not a leg failure (gh-1899 review, IMPORTANT)',
        );
        expect(
          run.out,
          contains('::warning::'),
          reason: 'the swallowed failure must still surface as a warning',
        );
        expect(
          run.log,
          contains(
            'release edit v1.2.3 --draft=false --latest --repo OWNER/REPO',
          ),
          reason: 'the publish flip ran BEFORE the failing dedupe',
        );
        expect(
          run.log,
          contains('api -X DELETE repos/OWNER/REPO/releases/2'),
          reason: 'the dedupe really attempted the twin delete',
        );
      });

      test('wiring lints: BOTH dedupe call sites are best-effort (review threads 1 + 2)', () {
        // release_attach_or_create.sh — the call must be guarded with
        // `|| echo "::warning::…"` so `set -euo pipefail` cannot turn a
        // cleanup blip into a red leg after the flip.
        final attachLines = read('scripts/release_attach_or_create.sh')
            .split('\n');
        final attachIdx = attachLines.indexWhere(
          (l) => l.contains('release_draft_dedupe.sh'),
        );
        expect(attachIdx, isNot(-1), reason: 'the dedupe call site must exist');
        final attachCall = attachLines
            .sublist(attachIdx, attachIdx + 2)
            .join('\n');
        expect(
          attachCall,
          contains('||'),
          reason:
              'best-effort guard: the call must not propagate its exit '
              'code into the `set -euo pipefail` upload_all',
        );
        expect(
          attachCall,
          contains('::warning::'),
          reason: 'the swallowed failure must surface as an Actions warning',
        );
        expect(
          attachCall,
          contains('gh-1899'),
          reason: 'the warning must be traceable to this guard',
        );

        // ci.yml release-provenance — same best-effort contract at the
        // provenance call site: a red dedupe there would skip
        // release-asset-smoke (it gates on the provenance result) for a
        // release that is actually fine.
        final ciLines = read('.github/workflows/ci.yml').split('\n');
        final ciIdx = ciLines.indexWhere(
          (l) => l.contains('release_draft_dedupe.sh'),
        );
        expect(ciIdx, isNot(-1), reason: 'the dedupe step must exist');
        expect(
          ciLines[ciIdx],
          contains('|| echo "::warning::'),
          reason:
              'best-effort at the provenance call site too — a cleanup '
              'blip after the flip must not fail the job and silently '
              'skip release-asset-smoke',
        );
      });
    },
  );
}
