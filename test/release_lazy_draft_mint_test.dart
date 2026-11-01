// Behavioral missing-ref tests for scripts/release_lazy_draft.sh
// (gh-2026): `gh release create --draft` for a MISSING tag REST-mints a
// lightweight API tag with NO push event — the v0.1.408 silent class
// (issue #597). When the fast build-macos.yml legs (build-extension /
// build-macos-cli, ubuntu/hosted, ~10 min) beat the attach legs
// (release-macos / release-mobile), the silent mint wins the race, every
// attach leg finds the tag existing and skips the CI-firing annotated
// push, and the draft is stranded forever (swept by the daily sweeper —
// the gh-2026 recurrence). The lazy create must mint the missing tag
// through the same CI-firing annotated push the attach path uses
// (scripts/release_tag_mint.sh) BEFORE creating the draft.
import 'package:test/test.dart';

import 'release_mint_test_support.dart';

void main() {
  test(
    'gh-2026: a lazy draft for a MISSING tag mints it via the CI-firing annotated push first',
    () {
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-with-token',
        ghToken: 'pat-token-for-test',
        seedExtraheader: true,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          // Keep the mint's train verification off the wall clock.
          'RELEASE_TRAIN_VERIFY_TRIES': '2',
          'RELEASE_TRAIN_VERIFY_SLEEP': '0',
        },
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.pushes, hasLength(1));
      expect(r.pushes.single, contains('x-access-token:'));
      expect(r.pushes.single, contains('pat-token-for-test'));
      expect(r.pushes.single, contains('refs/tags/v1.2.3'));
      // The silent REST mint would let `gh release create` create the tag;
      // the annotated push must precede the draft create.
      final pushIdx = r.gitLog.indexWhere((l) => l.startsWith('push '));
      final createIdx = r.ghLog.indexWhere(
        (l) => l.contains('release create v1.2.3'),
      );
      expect(pushIdx, greaterThanOrEqualTo(0));
      expect(createIdx, greaterThanOrEqualTo(0));
      expect(
        r.ghLog.take(createIdx).where((l) => l.contains('run list')).isNotEmpty,
        isTrue,
        reason: 'the train verification runs before the draft create',
      );
    },
  );

  test(
    'gh-2026: a lazy draft whose mint fired no workflow run fails loud, no draft',
    () {
      final r = runReleaseMintFixture(
        'scripts/release_lazy_draft.sh',
        args: const ['v1.2.3'],
        name: 'lazy-silent-train',
        ghToken: 'pat-token-for-test',
        seedExtraheader: true,
        trainRunning: false,
        githubRunId: '222',
        githubJob: 'build-extension',
        extraEnv: const {
          'RELEASE_TRAIN_VERIFY_TRIES': '2',
          'RELEASE_TRAIN_VERIFY_SLEEP': '0',
        },
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.output, contains('::error::'));
      expect(
        r.ghLog.where((l) => l.contains('release create v1.2.3')),
        isEmpty,
        reason: 'no draft may be created for a tag with no train',
      );
      expect(r.pushes, hasLength(1));
    },
  );
}
