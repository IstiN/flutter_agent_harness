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
String releasesJson(
  List<Map<String, Object?>> releases, {
  int perPage = 100,
}) {
  // The real script pages with `gh api --paginate` (one JSON array per
  // page); emit the same shape so the jq per-page filter sees reality,
  // including a multi-page run for the multi-item case.
  final pages = <List<Map<String, Object?>>>[];
  for (var i = 0; i < releases.length; i += perPage) {
    pages.add(
      releases.sublist(i, i + perPage > releases.length ? releases.length : i + perPage),
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
  'body': owner == null ? 'notes' : 'notes\n<!-- release-draft-owner: $owner -->\n',
};

void main() {
  group('release_draft_dedupe.sh — reclaims own-run twin drafts', () {
    test(
      'two own-run twin drafts of the published tag are deleted by id; nothing else is touched',
      () {
        final run = runDedupe('twins', releasesJsonText: releasesJson([
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
        ]));
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
          reason: 'exactly the two twins — the published release and the '
              'other tag\'s draft must survive',
        );
        expect(run.out, contains('gh-1899'));
      },
    );

    test(
      'foreign-run and unmarked drafts are never deleted (ownership discipline)',
      () {
        final run = runDedupe('foreign', releasesJsonText: releasesJson([
          release(id: 1, tag: 'v1.2.3'),
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/999/job/binaries-linux-arm64',
          ),
          release(id: 3, tag: 'v1.2.3', draft: true),
        ]));
        expect(run.exitCode, 0, reason: run.out);
        expect(
          run.log.where((l) => l.contains('-X DELETE')),
          isEmpty,
          reason:
              'a sibling run\'s mid-upload draft and an unmarked legacy '
              'draft are left for the 24h sweeper — the exact rule '
              'release_draft_guard.sh enforces',
        );
      },
    );

    test(
      'no published release for the tag → nothing deleted (recovery window stays open)',
      () {
        // A red provenance (e.g. the gh-1832 gate) leaves the draft on
        // purpose so `gh run rerun --failed` can recover it — the dedupe
        // guard must NOT take that draft away just because it carries
        // this run's marker.
        final run = runDedupe('unpublished', releasesJsonText: releasesJson([
          release(
            id: 2,
            tag: 'v1.2.3',
            draft: true,
            owner: 'run/111/job/binaries-linux-arm64',
          ),
        ]));
        expect(run.exitCode, 0, reason: run.out);
        expect(
          run.log.where((l) => l.contains('-X DELETE')),
          isEmpty,
          reason:
              'post-publish guard: without a published release the draft '
              'is the recovery vessel, never sweep food',
        );
        expect(run.out, contains('no published release'));
      },
    );

    test('no drafts at all → clean no-op', () {
      final run = runDedupe('clean', releasesJsonText: releasesJson([
        release(id: 1, tag: 'v1.2.3'),
      ]));
      expect(run.exitCode, 0, reason: run.out);
      expect(run.log.where((l) => l.contains('-X DELETE')), isEmpty);
      expect(run.out, contains('nothing to reclaim'));
    });

    test('run-id prefix trap: run/1111 is not run/111', () {
      final run = runDedupe('prefix', releasesJsonText: releasesJson([
        release(id: 1, tag: 'v1.2.3'),
        release(
          id: 2,
          tag: 'v1.2.3',
          draft: true,
          owner: 'run/1111/job/binaries-linux-arm64',
        ),
      ]));
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
        releasesJsonText: releasesJson(
          [
            for (var i = 10; i < 30; i++) release(id: i, tag: 'v0.0.$i'),
            release(id: 1, tag: 'v1.2.3'),
            release(
              id: 2,
              tag: 'v1.2.3',
              draft: true,
              owner: 'run/111/job/binaries-linux-arm64',
            ),
          ],
          perPage: 10,
        ),
      );
      expect(run.exitCode, 0, reason: run.out);
      expect(
        run.log,
        contains('api -X DELETE repos/OWNER/REPO/releases/2'),
      );
    });
  });

  group('wiring — the dedupe runs at every publish flip', () {
    test('ci.yml release-provenance reclaims twins AFTER the publish flip', () {
      final jobs = loadYaml(read('.github/workflows/ci.yml'))['jobs'] as YamlMap;
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
        (s) => s['run']?.toString().contains('release_draft_dedupe.sh') ?? false,
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
        reason: 'cleanup only on the success path — a red provenance keeps '
            'the draft for rerun --failed recovery (gh-1832)',
      );
    });

    test(
      'release_attach_or_create.sh reclaims twins after its servable-recovery flip',
      () {
        final script = read('scripts/release_attach_or_create.sh');
        final flip = script.indexOf('gh release edit "\$tag" --draft=false --latest');
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
      },
    );

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
      expect(dedupe, isNot(contains('gh release delete "\$tag"')),
          reason:
              'delete by release id via the API (the sweeper\'s rule) — '
              'a tag-based delete is ambiguous under duplicate releases, '
              'the very class this guard exists for');
    });
  });
}
