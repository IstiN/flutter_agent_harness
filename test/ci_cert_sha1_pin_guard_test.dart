// gh-1865 — the daily iOS leg failed (run 40455401630 / child
// 40455519923, 2026-10-27): `1 identity imported.` into build.keychain,
// yet the archive (~24 min in) rejected the cert on BOTH targets —
// `Provisioning profile "Fa Profile" / "FaLiveActivity Profile" doesn't
// include signing certificate "Apple Distribution: Uladzimir Klyshevich
// (YP9HC3USZ3)"`. Owner-verified host timeline:
//
//   05:31:23Z  build-macos arm64 (fa-m5-2, same host/user) additively
//              publishes build-arm64.keychain-db and imports its macOS
//              cert — SAME common name, SAME team, DIFFERENT serial
//   05:31:35Z  iOS leg (fa-m5-1) runs keychain_searchlist_add.sh → the
//              union list now holds BOTH keychains with two same-named
//              identities (this is by design: gh-1866's additive union
//              fixed eviction but created ambiguity resolution)
//   05:56:14Z  xcodebuild resolves the identity BY NAME → picks the
//              wrong (macOS) one → its serial is not in the iOS profile
//              → the archive is dead
//
// The generic `IOS_SIGNING_IDENTITY="iPhone Distribution"` (and the
// name-based `MACOS_CERTIFICATE_ID` secret on the macOS legs) made every
// codesign a lottery whose odds depend on leg concurrency. The fix
// (owner option A): read the SHA-1 fingerprint from THIS job's OWN
// keychain right after import, fail fast when it is ambiguous, and
// thread the fingerprint into every signing call — resolution becomes
// deterministic even with duplicates in the search list. Plus owner
// option B: a fail-fast precheck that decodes each provisioning profile
// and asserts it embeds the imported cert's serial BEFORE the build.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of ci_keychain_searchlist_union_guard_test.dart):
//
//   AC1  build-mobile.yml extracts the SHA-1 right after the p12 import
//        and threads it into IOS_SIGNING_IDENTITY — no generic
//        name-based identity assignment remains in the workflow.
//   AC2  build-macos.yml extracts the SHA-1 in the signing step, exposes
//        identity_sha1/identity_name outputs, and every `codesign
//        --sign` / FA_CODE_SIGN_IDENTITY site uses the fingerprint (the
//        already-signed skip check keys on the NAME via `codesign -dv`,
//        which never prints a SHA-1).
//   AC3  across EVERY workflow, no `codesign ... --sign X` resolves by
//        name: X must be ad-hoc (`-`) or a SHA-1-pinned variable.
//   AC4  both workflows refuse to pick silently: the extraction guards
//        the exactly-one-identity invariant with a loud ::error::.
//   AC5  owner option B: both workflows decode the profiles
//        (DeveloperCertificates) and compare serials against the
//        imported identity BEFORE the build step (ordering asserted).
//   AC6  flutter_app/fastlane/Fastfile threads the env-provided
//        fingerprint into BOTH update_code_signing_settings calls (Runner
//        + the manually-signed FaLiveActivity extension) and into
//        export_options.signingCertificate (what Xcode itself writes —
//        a SHA-1 — into exportOptions plists).
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

/// Workflow YAML, Ruby, and shell carry long incident comments that
/// legitimately mention the old name-based invocations — the guard
/// targets EXECUTABLE lines, so strip `#` comments before matching.
String stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

/// Every workflow that could sign — ENUMERATED like the gh-1866 union
/// guard's surfaces, so a NEW workflow with a name-based `--sign` fails
/// this guard instead of silently reviving the gh-1865 lottery.
List<String> get _workflowSurfaces => <String>[
  ...Directory('.github/workflows')
      .listSync()
      .where((f) => f is File && f.path.endsWith('.yml'))
      .map((f) => f.path),
];

void main() {
  test('AC1 — build-mobile.yml pins the iOS identity by SHA-1, never by '
      'generic name (gh-1865)', () {
    final mobile = stripComments(read('.github/workflows/build-mobile.yml'));

    // The fingerprint is read from THIS job's own keychain right after
    // the p12 import (an explicit keychain argument keeps the lookup
    // immune to whatever else the shared per-user search list holds).
    expect(
      mobile,
      contains(
        RegExp(r'find-identity\s+-v\s+-p\s+codesigning\s+build\.keychain'),
      ),
      reason:
          'build-mobile.yml must read the signing identity SHA-1 from '
          'build.keychain right after the import (gh-1865 option A). A '
          'generic name ("iPhone Distribution") is a lottery: the additive '
          'per-user search list (gh-1866) legitimately holds concurrent '
          "signing legs' same-CN certs with different serials, and "
          'xcodebuild resolved the WRONG one (owner timeline, run '
          '40455401630: 05:56:14Z) — its serial is not in the iOS profile.',
    );

    // The fingerprint rides to fastlane (which writes it into
    // CODE_SIGN_IDENTITY for Runner AND the FaLiveActivity extension).
    expect(
      mobile,
      contains(r'IOS_SIGNING_IDENTITY="$IOS_CERT_SHA1"'),
      reason:
          'build-mobile.yml must pass the extracted SHA-1 as '
          'IOS_SIGNING_IDENTITY into `fastlane ios build_only` — a '
          'name-based value re-opens the gh-1865 same-CN shadowing '
          'lottery.',
    );
    expect(
      mobile,
      contains('id: ios_signing'),
      reason:
          'build-mobile.yml must expose the iOS import step as '
          '`id: ios_signing` so the Build IPA step can consume its '
          'identity_sha1 output (gh-1865 option A).',
    );
    expect(
      mobile,
      contains(
        r'IOS_CERT_SHA1: ${{ steps.ios_signing.outputs.identity_sha1 }}',
      ),
      reason:
          'build-mobile.yml Build IPA step must consume '
          'steps.ios_signing.outputs.identity_sha1 (gh-1865 option A) — '
          'without the thread, the extraction is dead code and the build '
          'still resolves by name.',
    );

    // The generic assignments are GONE (not merely shadowed).
    expect(
      mobile.contains('IOS_SIGNING_IDENTITY="iPhone Distribution"') ||
          mobile.contains('IOS_SIGNING_IDENTITY="Apple Distribution"'),
      isFalse,
      reason:
          'build-mobile.yml still assigns a GENERIC signing identity name. '
          'gh-1865: a generic name resolves by search-list order and loses '
          'to a concurrent leg\'s same-CN cert. Thread the SHA-1 extracted '
          'from the job\'s own keychain instead.',
    );
  });

  test('AC2 — build-macos.yml pins every macOS signing site by SHA-1 '
      '(gh-1865)', () {
    final macos = stripComments(read('.github/workflows/build-macos.yml'));

    expect(
      macos,
      contains(RegExp(r'find-identity\s+-v\s+-p\s+codesigning\s+build-')),
      reason:
          'build-macos.yml must read the signing identity SHA-1 from the '
          "job's own per-arch keychain right after the import (gh-1865 "
          'option A) — MACOS_CERTIFICATE_ID is name-based and the same '
          'lottery exists both ways on the macOS legs.',
    );
    expect(
      macos,
      contains('identity_sha1='),
      reason:
          'build-macos.yml signing step must publish identity_sha1 as '
          'a step output so the Build/Package/no-sandbox steps can pin '
          '(gh-1865 option A).',
    );
    expect(
      macos,
      contains('identity_name='),
      reason:
          'build-macos.yml signing step must publish identity_name — '
          'the already-signed skip check keys on the CN because `codesign '
          '-dv` prints the Authority name, never the SHA-1 (gh-1865 '
          'review: signing by fingerprint and grepping -dv by fingerprint '
          'would never match).',
    );
    expect(
      macos,
      contains(r'export FA_CODE_SIGN_IDENTITY="$CERT_SHA1"'),
      reason:
          'build-macos.yml must export FA_CODE_SIGN_IDENTITY as the pinned '
          'SHA-1 for the xcodebuild manual-signing build (gh-1865 option '
          'A) — the name-based MACOS_CERTIFICATE_ID loses to a concurrent '
          "leg's same-CN cert.",
    );
    expect(
      macos,
      contains(
        r'FA_CODE_SIGN_IDENTITY: ${{ steps.signing.outputs.identity_sha1 }}',
      ),
      reason:
          'build-macos.yml no-sandbox packaging must consume '
          'steps.signing.outputs.identity_sha1 — build_macos_nosandbox.sh '
          'hands that value straight to `codesign --sign` (gh-1865 option '
          'A).',
    );
    expect(
      macos,
      contains(r'codesign --force --deep --sign "$CERT_SHA1"'),
      reason:
          'build-macos.yml .app seal (codesign_app) must sign by the '
          'pinned SHA-1, not by MACOS_CERTIFICATE_ID (gh-1865 option A).',
    );
    expect(
      macos,
      contains(RegExp(r'grep\s+-qF\s+"\$CERT_NAME"')),
      reason:
          'build-macos.yml already-signed skip check must grep `codesign '
          '-dv` output by the identity NAME (-dv prints the Authority CN, '
          'never the SHA-1) and with -F — the CN contains regex metas '
          "like the team parens, and a regex match could false-positive "
          'on any same-CN cert (gh-1865).',
    );

    // The name-based signing sites are GONE.
    expect(
      macos.contains(r'--sign "$MACOS_CERTIFICATE_ID"') ||
          macos.contains(r'FA_CODE_SIGN_IDENTITY="$MACOS_CERTIFICATE_ID"'),
      isFalse,
      reason:
          'build-macos.yml still signs by the name-based '
          'MACOS_CERTIFICATE_ID. gh-1865: name resolution is a lottery '
          'under the additive search list — sign by the SHA-1 read from '
          "the job's own keychain.",
    );
  });

  test('AC3 — no workflow resolves `codesign --sign` by a generic name '
      '(gh-1865)', () {
    final signUse = RegExp(r'codesign[^#\n]*--sign\s+("[^"]*"|\S+)');
    for (final path in _workflowSurfaces) {
      final content = stripComments(read(path));
      for (final match in signUse.allMatches(content)) {
        final target = match.group(1)!;
        final ok =
            target == '-' ||
            target.toUpperCase().contains('SHA1') ||
            target.toUpperCase().contains('SHA_1');
        expect(
          ok,
          isTrue,
          reason:
              '$path signs with `--sign $target`, which is neither ad-hoc '
              '("-") nor a SHA-1-pinned variable. gh-1865: a name-based '
              '--sign resolves against the shared additive per-user '
              'keychain search list and can pick a concurrent signing '
              "leg's same-CN/different-serial cert. Read the fingerprint "
              "from the job's own keychain right after import and sign by "
              'it.',
        );
      }
    }
  });

  test('AC4 — the extraction refuses to pick silently when ambiguous '
      '(gh-1865)', () {
    for (final path in <String>[
      '.github/workflows/build-mobile.yml',
      '.github/workflows/build-macos.yml',
    ]) {
      final content = stripComments(read(path));
      expect(
        content,
        contains('IDENT_COUNT'),
        reason:
            '$path must COUNT the "Apple Distribution" matches before '
            'using them (gh-1865: two same-CN identities in one search '
            'list is the failure mode; two in ONE keychain — e.g. a p12 '
            'with a renewed cert — must fail loud too, never pick '
            'silently).',
      );
      expect(
        content,
        contains('-ne 1'),
        reason:
            '$path must enforce exactly-one identity: 0 matches means the '
            'import produced no codesigning identity (wrong p12/password), '
            '>1 means an ambiguous keychain — both must abort before any '
            'signing (gh-1865).',
      );
      expect(
        content,
        contains('Refusing to pick silently'),
        reason:
            "$path's ambiguity error must say what it refuses to do — the "
            'gh-1865 class is silent wrong-identity resolution, and the '
            'autopsy greps for the failure semantics.',
      );
    }
  });

  test('AC5 — owner option B: profile serials are asserted BEFORE the '
      'build in both legs (gh-1865)', () {
    // mobile: the precheck (Import step) must sit BEFORE the fastlane
    // build call in the file — file order == execution order here.
    final mobile = stripComments(read('.github/workflows/build-mobile.yml'));
    expect(
      mobile,
      contains('DeveloperCertificates'),
      reason:
          'build-mobile.yml must decode the provisioning profiles and '
          'compare DeveloperCertificates serials against the imported '
          "identity's serial (gh-1865 option B) — run 40455519923 burned "
          'a ~24-minute archive to discover exactly this mismatch on BOTH '
          'targets.',
    );
    expect(
      mobile,
      contains('find-certificate'),
      reason:
          "build-mobile.yml must read the imported identity's serial via "
          "`security find-certificate` + `openssl x509 -noout -serial` — "
          'the same toolchain that prints the profile certs, so the '
          'comparison cannot drift on formatting (gh-1865 option B).',
    );
    expect(
      mobile,
      contains(r'grep -qxF "$IOS_CERT_SERIAL"'),
      reason:
          'build-mobile.yml must compare profile serials to the imported '
          'serial with an exact fixed-string match (gh-1865 option B) — '
          'a loose match would defeat the precheck.',
    );
    final precheckIdx = mobile.indexOf('DeveloperCertificates');
    final buildIdx = mobile.indexOf('bundle exec fastlane ios build_only');
    expect(
      precheckIdx,
      greaterThan(-1),
      reason: 'build-mobile.yml precheck must exist (see above).',
    );
    expect(
      buildIdx,
      greaterThan(precheckIdx),
      reason:
          'build-mobile.yml must run the profile-serial precheck BEFORE '
          '`fastlane ios build_only` (gh-1865 option B: abort in seconds, '
          'not after a ~24-minute archive). File order is execution order '
          'for these steps.',
    );

    // macOS: the profile block must assert before `flutter build macos`.
    final macos = stripComments(read('.github/workflows/build-macos.yml'));
    expect(
      macos,
      contains('DeveloperCertificates'),
      reason:
          'build-macos.yml must decode its provisioning profile and '
          'compare DeveloperCertificates serials against the imported '
          "identity's serial (gh-1865 option B) — the same lottery class "
          'kills the macOS legs symmetrically.',
    );
    expect(
      macos,
      contains(r'grep -qxF "$CERT_SERIAL"'),
      reason:
          'build-macos.yml must compare profile serials to the imported '
          'serial with an exact fixed-string match (gh-1865 option B).',
    );
    final macPrecheckIdx = macos.indexOf('DeveloperCertificates');
    final macBuildIdx = macos.indexOf('flutter build macos --release');
    expect(
      macBuildIdx,
      greaterThan(macPrecheckIdx),
      reason:
          'build-macos.yml must run the profile-serial precheck BEFORE '
          '`flutter build macos --release` (gh-1865 option B: abort before '
          'the multi-10-minute build).',
    );
  });

  test('AC6 — the Fastfile threads the env-provided fingerprint into both '
      'manual-signing targets and the export (gh-1865)', () {
    final fastfile = read('flutter_app/fastlane/Fastfile');
    expect(
      RegExp(
        r'code_sign_identity: signing_identity',
      ).allMatches(fastfile).length,
      greaterThanOrEqualTo(2),
      reason:
          'flutter_app/fastlane/Fastfile must pass the (SHA-1-pinned) '
          'IOS_SIGNING_IDENTITY into BOTH update_code_signing_settings '
          'calls — the Runner target AND the manually-signed FaLiveActivity '
          'extension (gh-1865 option A: the owner-specified '
          '`codesign --keychain build.keychain -s "\$SHA1"` surface is '
          "this extension's manual signing configuration; no bare codesign "
          'call exists for it).',
    );
    expect(
      fastfile,
      contains('signingCertificate: signing_identity'),
      reason:
          'flutter_app/fastlane/Fastfile must pin export_options '
          'signingCertificate to the same fingerprint — -exportArchive '
          'resolves the export cert independently of the project settings, '
          'and a SHA-1 there is exactly what Xcode itself writes into '
          'exportOptions plists (gh-1865 option A).',
    );
    expect(
      fastfile,
      contains('ENV["IOS_SIGNING_IDENTITY"]'),
      reason:
          'flutter_app/fastlane/Fastfile must read the fingerprint from '
          'IOS_SIGNING_IDENTITY — the CI workflow injects the SHA-1 it '
          'extracted from the job\'s own keychain (gh-1865 option A).',
    );
  });
}
