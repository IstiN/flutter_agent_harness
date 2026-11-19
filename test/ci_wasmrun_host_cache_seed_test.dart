// fa-m5 WasmRun host warm cache — the owner provisioned persistent
// CI-authentic zips in ~/vendor-cache/ on the runner box (launchd
// refresher). These asserts pin how the workflows consume that cache
// WITHOUT breaking the incident guards that predate it:
//
//   gh-2233 (wasmrun_restore_temp_race_test): the arch-less shared
//     /tmp/WasmRun.xcframework.zip path must not appear ANYWHERE in the
//     iOS step — so the seed source is ONLY ~/vendor-cache/, never /tmp.
//   gh-1759 (wasmrun_restore_budget_test): build-macos.yml must not
//     contain `rm -f "$ZIP"` before the download loop, and its first
//     occurrence must be the post-loop self-heal purge — so the seed
//     verifies a CANDIDATE file and only `mv`s it onto "$ZIP" when the
//     pinned sha256 matches; a bad candidate is discarded by its own
//     name, never by touching the partial.
//
//   AC1  iOS seeds from ~/vendor-cache/ only (no /tmp reference), via
//        the candidate+mv pattern, before the digest-valid skip.
//   AC2  iOS keeps $RUNNER_TEMP as the only download target.
//   AC3  macOS keeps per-arch /tmp partials and seeds cold ones from
//        ~/vendor-cache/$(basename "$ZIP") via the same candidate+mv
//        pattern (no `rm -f "$ZIP"` in the seed hunk).
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final mobile = File('.github/workflows/build-mobile.yml').readAsStringSync();
  final macos = File('.github/workflows/build-macos.yml').readAsStringSync();

  group('WasmRun host warm cache', () {
    test('AC1 iOS seeds from vendor-cache via digest-verified candidate+mv', () {
      final seed = mobile.indexOf('SEED="\$HOME/vendor-cache/WasmRun.xcframework.zip"');
      expect(seed, greaterThan(-1), reason: 'iOS vendor-cache seed missing');
      final mobileStep = mobile.substring(mobile.indexOf('Restore vendored WasmRun'));
      expect(mobileStep.contains('/tmp/WasmRun.xcframework.zip'), isFalse,
          reason: 'gh-2233: the arch-less /tmp path must not appear at all');
      expect(mobile, contains('SEED_CANDIDATE="\$ZIP.host-seed"'));
      expect(mobile, contains('mv "\$SEED_CANDIDATE" "\$ZIP"'),
          reason: 'only a digest-valid candidate lands on \$ZIP');
      expect(mobile, contains('rm -f "\$SEED_CANDIDATE"'),
          reason: 'bad candidates are discarded by their own name');
      final skip = mobile.indexOf('Complete, digest-valid \$ZIP already present');
      expect(skip, greaterThan(seed),
          reason: 'seed must land before the digest-valid skip check');
    });

    test('AC2 iOS never writes a shared /tmp path', () {
      final step = mobile.substring(mobile.indexOf('Restore vendored WasmRun'));
      expect(step, contains('ZIP="\$RUNNER_TEMP/WasmRun.xcframework.zip"'));
      expect(step, isNot(contains('-o "/tmp/')),
          reason: 'curl output must stay job-private (gh-2233)');
    });

    test('AC3 macOS keeps per-arch partials + candidate+mv vendor-cache seed', () {
      expect(macos, contains('ZIP="/tmp/WasmRun.xcframework-\${{ matrix.arch }}.zip"'),
          reason: 'per-arch resume paths (gh-1759) must stay');
      expect(macos, contains('SEED="\$HOME/vendor-cache/\$(basename "\$ZIP")"'),
          reason: 'cold-/tmp vendor-cache seed fallback missing');
      expect(macos, contains('mv "\$SEED_CANDIDATE" "\$ZIP"'));
      final seedHunk = macos.substring(macos.indexOf('SEED="\$HOME/vendor-cache/'));
      final loopStart = macos.indexOf('for attempt in 1 2 3 4');
      final seedBeforeLoop = seedHunk.substring(0, seedHunk.length > 900 ? 900 : seedHunk.length);
      expect(loopStart, greaterThan(0));
      expect(seedBeforeLoop, isNot(contains(r'rm -f "$ZIP"')),
          reason: 'gh-1759: the seed hunk must never rm the partial itself');
    });
  });
}
