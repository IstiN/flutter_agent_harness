// gh-2372 — sweeper backstop for orphaned twin drafts + hygiene
// classification, split from release_stale_draft_reclaim_test.dart to keep
// both suites below the whole-tree 2800-line loc ratchet.
//
// A MARKED pipeline draft whose tag ALREADY carries a PUBLISHED release is
// a proven orphan twin (the same-run sibling view→create race won — gh-2372:
// v1.0.760 was swept after 43h, v1.0.763's twin rotted while "fresh"): no
// run can ever publish or attach into it — uploads resolve the published
// object by tag. The sweep reclaims such drafts IMMEDIATELY (fresh or
// stale) as routine hygiene (gh-236 convention: visible, never a
// stale-draft finding), so a residual twin can never re-file the recurring
// sweep issue. Everything else keeps current semantics: unmarked/author-bot
// drafts stay in the bot bucket (finding + issue), the gh-2318
// failed-train fresh reclaim is untouched, human drafts stay listed+kept.
import 'dart:convert';

import 'package:test/test.dart';

import 'release_hygiene_test_support.dart';

void main() {
  final freshDate = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 1))
      .toIso8601String()
      .substring(0, 19);
  final staleDate = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 30))
      .toIso8601String()
      .substring(0, 19);

  Map<String, Object> markedDraft(
    String tag,
    int id, {
    required String created,
    required String marker,
  }) => {
    'tag_name': tag,
    'id': id,
    'draft': true,
    'created_at': '${created}Z',
    'author': {'login': 'IstiN', 'type': 'User'},
    'body':
        'Release $tag\n'
        '<!-- release-draft-owner: $marker -->',
  };

  Map<String, Object> publishedRelease(String tag, int id, String marker) => {
    'tag_name': tag,
    'id': id,
    'draft': false,
    'created_at': '${staleDate}Z',
    'published_at': '${staleDate}Z',
    'author': {'login': 'IstiN', 'type': 'User'},
    'body':
        'Release $tag\n'
        '<!-- release-draft-owner: $marker -->',
  };

  test(
    'gh-2372: a FRESH marked twin whose tag is already published is reclaimed NOW as hygiene — no finding, no issue',
    () {
      final run = runSweeper('twin-fresh', {
        'issues.tsv': '',
        'runs.tsv': '',
        'releases.json': jsonEncode([
          publishedRelease(
            'v1.0.763',
            454339894,
            'run/45007933749/job/build-macos-cli-arm64',
          ),
          markedDraft(
            'v1.0.763',
            454339915,
            created: freshDate,
            marker: 'run/45007933749/job/build-extension',
          ),
        ]),
      });
      final logText = run.log.join('\n');
      expect(
        logText,
        contains('api -X DELETE repos/OWNER/REPO/releases/454339915'),
        reason:
            'the twin is a proven orphan (the tag is already published) — '
            'reclaimed immediately, not at 24h',
      );
      expect(
        logText,
        isNot(contains('releases/454339894')),
        reason: 'the published winner release is never touched',
      );
      expect(
        run.body,
        isNull,
        reason:
            'the twin class is lifecycle-managed hygiene (gh-236 '
            'convention) — it must NOT re-file the recurring sweep issue',
      );
      expect(
        run.stdoutText,
        contains('twins=v1.0.763'),
        reason: 'the job summary line names the twin reclaims',
      );
      expect(
        run.stdoutText,
        contains('issue=none needed'),
        reason: 'no finding → no issue lifecycle action',
      );
    },
  );

  test(
    'gh-2372: a STALE marked twin whose tag is published is reclaimed as hygiene — never the misleading bot-bucket prose',
    () {
      final run = runSweeper('twin-stale', {
        'issues.tsv': '',
        'runs.tsv': '',
        'releases.json': jsonEncode([
          publishedRelease(
            'v1.0.760',
            453463937,
            'run/44870476733/job/build-extension',
          ),
          markedDraft(
            'v1.0.760',
            453463040,
            created: staleDate,
            marker: 'run/44870476733/job/build-macos-cli-arm64',
          ),
        ]),
      });
      final logText = run.log.join('\n');
      expect(
        logText,
        contains('api -X DELETE repos/OWNER/REPO/releases/453463040'),
      );
      expect(
        run.body,
        isNull,
        reason:
            'the swept gh-2372 shape (creating run SUCCEEDED, the twin '
            'rotted) must not file the sweep issue at all — the '
            '"gh release create step died" prose misdirected the RCA',
      );
      expect(run.stdoutText, contains('twins=v1.0.760'));
    },
  );

  test(
    'gh-2372: when an open sweep issue exists, the clean-sweep auto-close names the twin reclaims',
    () {
      final run = runSweeper('twin-close', {
        'issues.tsv': '13\t[daily-publish] stale release drafts swept\n',
        'runs.tsv': '',
        'releases.json': jsonEncode([
          publishedRelease(
            'v1.0.763',
            454339894,
            'run/45007933749/job/build-macos-cli-arm64',
          ),
          markedDraft(
            'v1.0.763',
            454339915,
            created: freshDate,
            marker: 'run/45007933749/job/build-extension',
          ),
        ]),
      });
      final logText = run.log.join('\n');
      expect(
        logText,
        contains('issue close 13'),
        reason: 'only twins were reclaimed (not a finding) — auto-close',
      );
      expect(
        logText,
        contains('orphaned twin draft(s)'),
        reason: 'the close comment names the twin reclaim for visibility',
      );
      expect(run.stdoutText, contains('auto-closed #13'));
    },
  );

  test(
    'gh-2372: a FRESH marked draft whose tag is NOT published is untouched (an in-flight run may own it)',
    () {
      final run = runSweeper('twin-keep-unpublished', {
        'issues.tsv': '',
        'runs.tsv': '',
        'train-runs.json': jsonEncode([]),
        'releases.json': jsonEncode([
          markedDraft(
            'v1.0.999',
            999001,
            created: freshDate,
            marker: 'run/427501287/job/release-macos',
          ),
        ]),
      });
      expect(
        run.log.where((l) => l.contains('-X DELETE')),
        isEmpty,
        reason:
            'no published release on the tag → the twin rule does not apply',
      );
      expect(run.body, isNull);
    },
  );

  test(
    'gh-2372: an UNMARKED author-bot stale draft on a published tag keeps the bot-bucket finding (ownership unproven)',
    () {
      final run = runSweeper('twin-bot-unmarked', {
        'issues.tsv': '',
        'runs.tsv': '',
        'releases.json': jsonEncode([
          publishedRelease('v0.1.190', 111, 'run/1/job/release-macos'),
          {
            'tag_name': 'v0.1.190',
            'id': 222,
            'draft': true,
            'created_at': '${staleDate}Z',
            'author': {'login': 'github-actions[bot]', 'type': 'Bot'},
            'body': 'Release v0.1.190\n',
          },
        ]),
      });
      final logText = run.log.join('\n');
      expect(
        logText,
        contains('api -X DELETE repos/OWNER/REPO/releases/222'),
        reason: 'the bot bucket still deletes it (existing behavior)',
      );
      expect(
        run.body,
        isNotNull,
        reason: 'unmarked drafts have no ownership proof → still a finding',
      );
      expect(
        run.body,
        contains('died between asset upload and publish'),
        reason: 'the generic bot-bucket prose is unchanged for unmarked drafts',
      );
    },
  );
}
