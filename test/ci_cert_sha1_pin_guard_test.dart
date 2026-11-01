// gh-1865 — identity resolution is pinned by SHA-1 FINGERPRINT everywhere,
// never by a generic certificate name, and every profile serial is
// fail-fast checked BEFORE the archive.
//
// Incident chain: the per-user keychain search list legitimately holds
// concurrent signing legs' certificates with the SAME common name and
// DIFFERENT serials (the iOS leg's and the macOS legs' distribution certs
// share the subject "… (team YP9HC3USZ3)"). Name-based resolution
// (`code_sign_identity = iPhone Distribution`, MACOS_CERTIFICATE_ID) is a
// lottery between them — xcodebuild resolved the WRONG cert at
// 05:56:14Z on run 40455401630 and the iOS archive died after ~24 min.
//
// gh-1865 model v3 (PR #1944, owner decision 2026-10-28): the per-job
// keychains are retired; ALL identities live in the persistent
// ci-signing.keychain-db managed by scripts/ci-sign (~bin/ci-sign on the
// host). The fingerprint is computed at `ci-sign install` time from the
// p12 itself, persisted per label, and threaded into every signing call.
// The distribution cert CLASS varies by issuance era (r2, v1.0.659
// regression, runs 40637547059/40637547009: iOS p12s may carry the legacy
// "iPhone Distribution:" CN, macOS legs the modern "Apple Distribution:"
// CN) — under fingerprint pinning the class is irrelevant BY CONSTRUCTION,
// which is why these asserts target the ci-sign routing instead of the
// retired inline `find-identity | grep <class>` extraction.
//
//   AC1  build-mobile.yml provisions via `ci-sign install fa-ios`, resolves
//        the fingerprint via `ci-sign sha1 fa-ios`, and threads it into
//        fastlane (IOS_SIGNING_IDENTITY).
//   AC2  build-macos.yml provisions via `ci-sign install fa-macos` and
//        resolves via `ci-sign sha1 fa-macos`; every macOS signing site signs
//        by the SHA-1 variable.
//   AC3  no workflow signs by a generic certificate NAME — no
//        `codesign --sign "<cert name>"` / `productbuild --sign`
//        name-based resolutions remain.
//   AC4  ci-sign never resolves by name: the label manifest stores the
//        sha1= line and verify matches find-identity output against THAT
//        fingerprint (a wrong/corrupt manifest cannot silently pick a
//        same-named certificate).
//   AC5  owner option B: BOTH legs fail fast on profile/cert mismatch via
//        `ci-sign doctor` before the build (the ~24-minute gym failure
//        class, run 40455401630 → v1.0.659 run 40637547009).
//   AC6  the Fastfile threads the env-provided fingerprint into both
//        update_code_signing_settings calls.
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

/// Workflow YAML carries long incident comments that legitimately mention
/// the historical name-based lookups — the guard targets EXECUTABLE lines,
/// so strip shell/Ruby `#` comments before matching.
String stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

void main() {
  test('AC1 — build-mobile.yml pins the iOS identity by SHA-1 via ci-sign '
      '(gh-1865)', () {
    final mobile =
        stripComments(read('.github/workflows/build-mobile.yml'));

    expect(
      mobile,
      contains('~/bin/ci-sign install fa-ios'),
      reason:
          'build-mobile.yml must provision/verify the iOS identity via '
          'ci-sign install fa-ios — the fingerprint is computed from the p12 '
          'at install time and persisted per label (gh-1865 option A).',
    );
    expect(
      mobile,
      contains(RegExp(r'IOS_CERT_SHA1=\$\([^)]*ci-sign sha1 fa-ios')),
      reason:
          'build-mobile.yml must resolve the identity fingerprint via '
          '`ci-sign sha1 fa-ios` — never by generic name. The per-user search '
          "list holds concurrent legs' same-CN certificates with different "
          'serials, and name resolution picked the WRONG one (run '
          '40455401630, 05:56:14Z).',
    );
    expect(
      mobile,
      contains(RegExp(r'IOS_SIGNING_IDENTITY="\$IOS_CERT_SHA1"'),
          ),
      reason:
          'the fastlane leg must receive the SHA-1 fingerprint as '
          'IOS_SIGNING_IDENTITY (the local-dev "iPhone Distribution" '
          'fallback in the Fastfile is dev-only).',
    );
  });

  test('AC2 — build-macos.yml pins every macOS signing site by SHA-1 via '
      'ci-sign (gh-1865)', () {
    final macos = stripComments(read('.github/workflows/build-macos.yml'));

    expect(
      macos,
      contains('~/bin/ci-sign install fa-macos'),
      reason:
          'build-macos.yml must provision/verify via ci-sign install fa-macos '
          '(per-arch temporary keychains are retired — their delete+create '
          'race was gh-1852).',
    );
    expect(
      macos,
      contains(RegExp(r'CERT_SHA1=\$\([^)]*ci-sign sha1 fa-macos')),
      reason:
          'build-macos.yml must resolve the fingerprint via '
          '`ci-sign sha1 fa-macos` — the name-based MACOS_CERTIFICATE_ID '
          'secret is a lottery when the iOS leg (or the sibling arch) '
          'keeps a same-CN cert visible in the shared list.',
    );
    expect(
      macos,
      contains(RegExp(r'codesign .*--sign "\$CERT_SHA1"')),
      reason:
          'every macOS codesign invocation must sign by the '
          'fingerprint variable.',
    );
  });

  test('AC3 — no workflow resolves a signing identity by a generic '
      'certificate name (gh-1865 r2: the CN class varies by era)', () {
    final nameBasedSigning = RegExp(
      r'--sign "\$(MACOS_CERTIFICATE_ID|MACOS_INSTALLER_CERT_ID)"',
    );
    for (final wf in Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))) {
      final matches =
          nameBasedSigning.allMatches(stripComments(read(wf.path)));
      expect(
        matches,
        isEmpty,
        reason:
            '${wf.path} signs by a NAME-based secret. The distribution '
            'cert class varies by issuance era (r2: legacy "iPhone '
            'Distribution:" vs modern "Apple Distribution:" CNs) and '
            'same-CN duplicates are legitimate in the shared search list — '
            'name resolution is a lottery (run 40455401630). Sign by the '
            'fingerprint from `ci-sign sha1 <label>`.',
      );
    }
  });

  test('AC4 — ci-sign resolves identities by the stored fingerprint, never '
      'by name (gh-1865)', () {
    final script = read('scripts/ci-sign');
    expect(
      script,
      contains(RegExp(r"sed -n 's/\^sha1=//p'")),
      reason:
          'ci-sign verify_label_identity must read the persisted sha1= '
          'line from the label manifest and match find-identity output '
          'against THAT fingerprint — a manifest mismatch must fail, never '
          'silently pick a same-named certificate.',
    );
    expect(
      script,
      contains(RegExp(r'find-identity -v[^\n]*grep -qi "\$sha1"')),
      reason:
          'the validity gate must check the EXACT fingerprint is a valid '
          'identity of ANY kind — codesign or productsign/installer '
          '(gh-2026: the -p codesigning policy hid installer identities; '
          'expired/revoked/mismatched key = loud '
          'abort with an install --force hint).',
    );
  });

  test('AC5 — owner option B: profile serials are asserted BEFORE the '
      'build in both legs (gh-1865, v1.0.659 regression)', () {
    final mobile =
        stripComments(read('.github/workflows/build-mobile.yml'));
    expect(
      RegExp(r'ci-sign doctor [^\n]*profile\.mobileprovision fa-ios')
          .hasMatch(mobile),
      isTrue,
      reason:
          'build-mobile.yml must fail fast via ci-sign doctor on the '
          'Runner profile BEFORE the archive (the ~24-minute gym failure '
          'class — run 40455401630 died at gym on BOTH targets).',
    );
    expect(
      RegExp(r'ci-sign doctor [^\n]*liveactivity\.mobileprovision fa-ios')
          .hasMatch(mobile),
      isTrue,
      reason:
          'the FaLiveActivity extension signs with its own profile — its '
          'mismatch must also abort BEFORE the archive.',
    );
    final macos = stripComments(read('.github/workflows/build-macos.yml'));
    expect(
      RegExp(r'ci-sign doctor [^\n]*profile\.provisionprofile fa-macos')
          .hasMatch(macos),
      isTrue,
      reason:
          'build-macos.yml must fail fast via ci-sign doctor on the macOS '
          'profile (the v1.0.659 run 40637547009 class: the precheck ran '
          'but extracted nothing and aborted a HEALTHY build — the '
          'extractor must be robust, which ci-sign doctor (plistlib) is '
          'pinned by test/ci_profile_serial_precheck_test.dart).',
    );
  });

  test('AC6 — the Fastfile threads the env-provided fingerprint into both '
      'update_code_signing_settings calls (gh-1865)', () {
    final fastfile = stripComments(read('flutter_app/fastlane/Fastfile'));
    expect(
      RegExp('signing_identity = ENV\\["IOS_SIGNING_IDENTITY"\\]').hasMatch(fastfile),
      isTrue,
      reason:
          'the Fastfile must take the identity from IOS_SIGNING_IDENTITY '
          '(the workflow passes the ci-sign SHA-1) — the bare-name default '
          'is a local-dev fallback only.',
    );
    expect(
      RegExp(r'code_sign_identity: signing_identity').allMatches(fastfile).length,
      greaterThanOrEqualTo(2),
      reason:
          'BOTH update_code_signing_settings calls (Runner + FaLiveActivity '
          'extension) must use the fingerprint-bearing signing_identity — '
          'a single name-based target would re-enter the gh-1865 lottery '
          'for the extension.',
    );
  });
}
