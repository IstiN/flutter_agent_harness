// gh-2042 AC2 — release_drift_check.sh: re-download every `fa-*` asset of a
// release and diff sha256 against the signed SHA256SUMS.
//
// The v1.0.680 incident shipped a manifest that no longer matched the
// attached bytes (post-publish re-attach), so `fa update` / install.sh
// provenance verification failed for every macOS-arm64 user. This check is
// the CI-side twin of bin/self_manage.dart's verifyReleaseProvenance: same
// manifest, same digest comparison — but it runs against the RELEASE, pages
// on drift, and never lingers.
//
// Behavioral tests run the script over fixture directories (FA_DRIFT_LOCAL_DIR,
// the documented test seam) with the REAL sha256sum — no gh needed.
import 'dart:io';

import 'package:test/test.dart';

String _out(ProcessResult r) => '${r.stdout}${r.stderr}';

/// Fixture dir with [assetContents] (name → bytes) plus SHA256SUMS built from
/// the REAL sha256sum over the [manifestNames] subset, and a dummy .sig.
Directory _fixture(
  String name,
  Map<String, String> assetContents,
  List<String> manifestNames,
) {
  final dir = Directory.systemTemp.createTempSync('drift-check-$name-');
  assetContents.forEach((assetName, content) {
    File('${dir.path}/$assetName').writeAsStringSync(content);
  });
  final args = ['sha256sum', ...manifestNames];
  final res = Process.runSync('sha256sum', manifestNames,
      workingDirectory: dir.path);
  if (res.exitCode != 0) fail('fixture sha256sum failed: ${res.stderr}');
  File('${dir.path}/SHA256SUMS').writeAsStringSync(res.stdout as String);
  File('${dir.path}/SHA256SUMS.sig').writeAsStringSync('dummy-signature');
  return dir;
}

ProcessResult _runCheck(Directory dir) => Process.runSync('bash', [
      'scripts/release_drift_check.sh',
      'v1.2.3',
    ], environment: {
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'FA_DRIFT_LOCAL_DIR': dir.path,
    });

void main() {
  test('missing drift-check script fails the suite loudly', () {
    expect(File('scripts/release_drift_check.sh').existsSync(), isTrue,
        reason: 'scripts/release_drift_check.sh must exist (gh-2042 AC2)');
  });

  test('every fa-* digest matches the signed manifest → exit 0', () {
    // Multi-item set (loop contract): three assets, all matching.
    final dir = _fixture('match', {
      'fa-linux-x64.tar.gz': 'linux-bytes',
      'fa-macos-arm64.tar.gz': 'mac-bytes',
      'fa-web-spa.zip': 'spa-bytes',
    }, [
      'fa-linux-x64.tar.gz',
      'fa-macos-arm64.tar.gz',
      'fa-web-spa.zip',
    ]);
    final r = _runCheck(dir);
    expect(r.exitCode, 0, reason: _out(r));
    expect(_out(r), contains('✅'));
    dir.deleteSync(recursive: true);
  });

  test('tampered asset (manifest digest no longer matches bytes) → exit 1, names the asset', () {
    final dir = _fixture('tampered', {
      'fa-linux-x64.tar.gz': 'linux-bytes',
      'fa-macos-arm64.tar.gz': 'mac-bytes',
      'fa-web-spa.zip': 'spa-bytes',
    }, [
      'fa-linux-x64.tar.gz',
      'fa-macos-arm64.tar.gz',
      'fa-web-spa.zip',
    ]);
    // The post-publish re-attach: fresh bytes under an already-signed name.
    File('${dir.path}/fa-macos-arm64.tar.gz').writeAsStringSync('REPLACED');
    final r = _runCheck(dir);
    expect(r.exitCode, isNot(0), reason: _out(r));
    expect(_out(r), contains('::error::'));
    expect(_out(r), contains('fa-macos-arm64.tar.gz'));
    dir.deleteSync(recursive: true);
  });

  test('asset on disk but NOT in the manifest (stale manifest) → exit 1', () {
    final dir = _fixture('unlisted', {
      'fa-linux-x64.tar.gz': 'linux-bytes',
      'fa-macos-arm64-mac.zip': 'attached-after-signing',
    }, [
      'fa-linux-x64.tar.gz',
    ]);
    final r = _runCheck(dir);
    expect(r.exitCode, isNot(0), reason: _out(r));
    expect(_out(r), contains('fa-macos-arm64-mac.zip'),
        reason: 'the drift report must name the uncovered asset');
    dir.deleteSync(recursive: true);
  });

  test('SHA256SUMS missing on the release → exit 1 (provenance can never be verified)', () {
    final dir = _fixture('no-manifest', {'fa-linux-x64.tar.gz': 'b'}, [
      'fa-linux-x64.tar.gz',
    ]);
    File('${dir.path}/SHA256SUMS').deleteSync();
    final r = _runCheck(dir);
    expect(r.exitCode, isNot(0), reason: _out(r));
    expect(_out(r), contains('::error::'));
    expect(_out(r), contains('SHA256SUMS'));
    dir.deleteSync(recursive: true);
  });

  test('SHA256SUMS.sig missing → exit 1 (unsigned manifest is not provenance)', () {
    final dir = _fixture('no-sig', {'fa-linux-x64.tar.gz': 'b'}, [
      'fa-linux-x64.tar.gz',
    ]);
    File('${dir.path}/SHA256SUMS.sig').deleteSync();
    final r = _runCheck(dir);
    expect(r.exitCode, isNot(0), reason: _out(r));
    expect(_out(r), contains('::error::'));
    dir.deleteSync(recursive: true);
  });

  test('manifest lists an asset the release no longer serves → exit 1', () {
    final dir = _fixture('missing-asset', {
      'fa-linux-x64.tar.gz': 'b',
    }, [
      'fa-linux-x64.tar.gz',
      'fa-windows-x64.zip',
    ]);
    File('${dir.path}/fa-windows-x64.zip').deleteSync();
    final r = _runCheck(dir);
    expect(r.exitCode, isNot(0), reason: _out(r));
    expect(_out(r), contains('fa-windows-x64.zip'));
    dir.deleteSync(recursive: true);
  });

  test('the script downloads from the release when no local dir is given', () {
    // Static guard: the production path (no FA_DRIFT_LOCAL_DIR) must
    // download BOTH the fa-* set and the manifest files.
    final script = File('scripts/release_drift_check.sh').readAsStringSync();
    expect(script, contains("gh release download"));
    expect(script, contains("'fa-*'"));
    expect(script, contains('SHA256SUMS'));
    expect(script, contains('FA_DRIFT_LOCAL_DIR'),
        reason: 'the test seam must be named in the script');
  });
}
