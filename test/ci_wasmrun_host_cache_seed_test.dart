// fa-m5 WasmRun host warm cache — the owner provisioned persistent
// CI-authentic zips in ~/vendor-cache/ on the runner box with a launchd
// refresher keeping /tmp stocked. These asserts pin how the workflows
// consume that cache WITHOUT reintroducing the gh-2233 race (concurrent
// legs writing one shared /tmp path produced a patchwork zip):
//
//   AC1  build-mobile.yml (iOS leg) seeds its job-private $RUNNER_TEMP zip
//        from the host cache (/tmp, then ~/vendor-cache/) BEFORE the
//        download loop, and re-verifies the pinned sha256 after the copy
//        (a mid-refresh partial seed is discarded, never unzipped).
//   AC2  the iOS leg never WRITES to a shared /tmp path — the only curl
//        output target stays "$ZIP" ($RUNNER_TEMP, job-private).
//   AC3  build-macos.yml keeps its per-arch /tmp partial paths (gh-1759
//        cross-run resume) and adds the ~/vendor-cache seed fallback for
//        a cold /tmp, with the same post-copy digest re-verification.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final mobile = File('.github/workflows/build-mobile.yml').readAsStringSync();
  final macos = File('.github/workflows/build-macos.yml').readAsStringSync();

  group('WasmRun host warm cache', () {
    test('AC1 iOS seeds job-private zip from host cache before downloading', () {
      final seed = mobile.indexOf('for SEED in "/tmp/WasmRun.xcframework.zip" '
          '"\$HOME/vendor-cache/WasmRun.xcframework.zip"');
      expect(seed, greaterThan(-1), reason: 'iOS host-cache seed loop missing');
      final skip = mobile.indexOf('Complete, digest-valid \$ZIP already present');
      expect(skip, greaterThan(seed),
          reason: 'seed must land before the digest-valid skip check');
      expect(mobile, contains('cp "\$SEED" "\$ZIP"'));
      expect(mobile, contains('rm -f "\$ZIP" # bad/partial seed'),
          reason: 'post-copy digest re-verification must drop bad seeds');
    });

    test('AC2 iOS never writes a shared /tmp path', () {
      final step = mobile.substring(mobile.indexOf('Restore vendored WasmRun'));
      expect(step, contains('ZIP="\$RUNNER_TEMP/WasmRun.xcframework.zip"'));
      expect(step, isNot(contains('-o "/tmp/')),
          reason: 'curl output must stay job-private (gh-2233)');
      expect(step, isNot(contains('cp "\$ZIP" "/tmp/')),
          reason: 'no writes back into the shared cache from CI legs');
    });

    test('AC3 macOS keeps per-arch /tmp partials + vendor-cache seed fallback', () {
      expect(macos, contains('ZIP="/tmp/WasmRun.xcframework-\${{ matrix.arch }}.zip"'),
          reason: 'per-arch resume paths (gh-1759) must stay');
      expect(macos, contains('SEED="\$HOME/vendor-cache/\$(basename "\$ZIP")"'),
          reason: 'cold-/tmp vendor-cache seed fallback missing');
      expect(macos, contains('cp "\$SEED" "\$ZIP"'));
      expect(macos, contains('rm -f "\$ZIP" # bad/partial seed'));
    });
  });
}
