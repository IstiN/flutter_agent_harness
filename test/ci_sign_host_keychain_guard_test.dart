// gh-1865 / gh-1866 — the signing model v3: ONE persistent per-host
// signing keychain managed by scripts/ci-sign (host path ~/bin/ci-sign).
//
// Incident chain that produced this design:
//
//   gh-1852 (runs 40117288269): INTRA-workflow — build-macos's two matrix
//     legs replaced each other's per-user keychain search list
//     (`security list-keychains -d user -s` REPLACES the whole list).
//     First fix: strategy.max-parallel: 1.
//   gh-1866 (runs 40165497544 → 40165498619, 2026-10-25): CROSS-workflow —
//     the concurrent build-mobile iOS job on another fa-m5 registration of
//     the SAME host/user evicted build-arm64.keychain from the search list
//     75 s after import → "No certificate for team YP9HC3USZ3 found".
//     Fix: additive union helper (scripts/keychain_searchlist_add.sh) as
//     the single allowed writer.
//   gh-1865 (run 40455401630, 2026-10-27): the AMBIGUITY flip side of the
//     additive model — the union list legitimately held BOTH the iOS and
//     the concurrent macOS leg's certificate (same subject "Apple
//     Distribution: Uladzimir Klyshevich (YP9HC3USZ3)", different
//     serials); xcodebuild resolved the generic name to the WRONG cert and
//     the iOS archive died after ~24 min ("Provisioning profile doesn't
//     include signing certificate"). PR #1928 pinned identities by SHA-1
//     and added the fail-fast profile precheck (options A+B).
//   Owner decision (2026-10-28, "чтобы такой проблемы больше не было"):
//     kill the CLASS, not the symptoms — per-job temporary keychains and
//     per-job search-list writes are retired entirely. ONE persistent
//     keychain (ci-signing.keychain-db) is provisioned idempotently by
//     ci-sign, all identities live side by side, resolution is pinned by
//     SHA-1 (ci-sign sha1 / codesign -s SHA1 --keychain), profiles are
//     fail-fast checked by `ci-sign doctor`, and no workflow ever creates
//     a keychain or writes the user-global keychain state again — which
//     also ends the interactive SecurityAgent password prompts the
//     orphaned per-job keychains produced in the owner's GUI session.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of workflow_selfhosted_legs_test.dart):
//
//   AC1  no workflow / Fastfile / helper script performs keychain
//        lifecycle or user-global keychain-state writes
//        (create-keychain, delete-keychain, `list-keychains -d user -s`,
//        `default-keychain`) — scripts/ci-sign is the ONLY writer.
//   AC2  scripts/ci-sign implements the model: idempotent install,
//        partition-list (no GUI prompts), SHA-1 identity pinning,
//        doctor precheck, additive+verified persistent search-list
//        membership, plist decode without a default keychain.
//   AC3  every signing surface routes through ci-sign: build-mobile.yml
//        (install ios + doctor on both profiles), build-macos.yml
//        (install macos), Fastfile (ci-sign unlock before gym).
//   AC4  the retired additive helper is GONE — no surface may reference
//        keychain_searchlist_add.sh (a stale reference would silently
//        reintroduce per-job search-list writes).
//   AC5  the host provisioning workflow exists: workflow_dispatch, runs
//        on the self-hosted fa-m5 pool pinned to ONE registration,
//        installs BOTH labels (ios, macos) from the repo secrets and
//        cleans up legacy per-job keychains.
//   AC6  incident-forensics breadcrumbs keep the full issue number
//        (gh-1866, gh-1865) — no truncated `gh-18*6` typo pointers.
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

/// Workflow YAML and the Fastfile carry long incident comments that
/// legitimately mention the historical commands — the guard targets
/// EXECUTABLE lines, so strip shell/Ruby `#` comments before matching.
String stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

/// Every surface that could write keychain state, ENUMERATED rather than
/// hardcoded. scripts/ci-sign is the single allowed writer (AC2 pins its
/// behavior) and is excluded from the audit.
List<String> get _keychainSurfaces => <String>[
  ...Directory('.github/workflows')
      .listSync()
      .where((f) => f is File && f.path.endsWith('.yml'))
      .map((f) => f.path),
  'flutter_app/fastlane/Fastfile',
  ...Directory('scripts')
      .listSync()
      .where((f) => f is File && f.path.endsWith('.sh'))
      .map((f) => f.path)
      .where((p) => p != 'scripts/ci-sign'),
];

/// Executable (comment-stripped) occurrences of a pattern in a file.
Iterable<RegExpMatch> executableMatches(String path, RegExp pattern) =>
    pattern.allMatches(stripComments(read(path)));

void main() {
  test('AC1 — no keychain lifecycle / user-global keychain writes outside '
      'scripts/ci-sign (gh-1865 model v3)', () {
    final forbidden = RegExp(
      r'security\s+(create-keychain|delete-keychain|'
      r'list-keychains\s+-d\s+user\s+-s|default-keychain)',
    );
    for (final path in _keychainSurfaces) {
      final matches = executableMatches(path, forbidden);
      expect(
        matches,
        isEmpty,
        reason:
            '$path performs a keychain lifecycle or user-global keychain '
            'state write. Per-job temporary keychains + per-job search-list '
            'writes caused the whole gh-1852 → gh-1866 → gh-1865 incident '
            'chain (eviction, same-subject identity ambiguity, interactive '
            'SecurityAgent prompts) on the shared fa-m5 host/user. Signing '
            'goes through ~/bin/ci-sign against the persistent '
            'ci-signing.keychain-db — nothing else may touch keychain '
            'state.',
      );
    }
  });

  test('AC2 — scripts/ci-sign implements the persistent-keychain model', () {
    final script = read('scripts/ci-sign');
    // Idempotent provisioning: create-if-missing + survival-verified
    // additive search-list membership (never a fixed-list replace).
    expect(script, contains('create-keychain'),
        reason: 'ci-sign must create the persistent keychain if missing');
    expect(script, contains(RegExp(r'list-keychains\s+-d\s+user\s+-s')),
        reason:
            'ci-sign is the single allowed search-list writer — it adds '
            'the persistent keychain idempotently, preserving concurrent '
            'entries (the gh-1866 union logic, applied once)');
    expect(script, contains(RegExp(r'grep\s+-qxF')),
        reason:
            'the search-list membership add must be survival-verified with '
            'a fixed-string whole-line match (gh-1866 review thread)');
    // No interactive keychain prompts: partition the private key.
    expect(script, contains('set-key-partition-list'),
        reason:
            'ci-sign must partition the signing key for codesign — without '
            'it SecurityAgent pops an interactive keychain-password dialog '
            'in the owner\'s GUI session (observed 2026-10-28)');
    // Deterministic identity resolution (gh-1865 option A).
    expect(script, contains('find-identity'),
        reason: 'ci-sign resolves the identity fingerprint via find-identity');
    expect(script, contains('sha1='),
        reason:
            'ci-sign persists the SHA-1 fingerprint per label — resolution '
            'is pinned by fingerprint, never by generic name (gh-1865: '
            'same-subject duplicate certificates in the search list made '
            'name resolution ambiguous)');
    // Fail-fast profile precheck (gh-1865 option B) without a default
    // keychain (default-keychain writes are part of the retired model).
    expect(script, contains('doctor'),
        reason:
            'ci-sign doctor must verify profile certificates against the '
            'keychain BEFORE the archive (the ~24-minute gym failure '
            'class, run 40455401630)');
    expect(script, contains('openssl cms -inform DER -verify -noverify'),
        reason:
            'profile decoding must not depend on `security cms -D`, which '
            'requires a default keychain (none exists on this host by '
            'design)');
  });

  test('AC3 — every signing surface routes through ci-sign', () {
    final mobile = read('.github/workflows/build-mobile.yml');
    expect(mobile, contains('ci-sign install fa-ios'),
        reason:
            'build-mobile.yml iOS leg must provision/verify its identity '
            'via ci-sign install fa-ios (persistent keychain, idempotent)');
    expect(
        RegExp(r'ci-sign doctor .*profile\.mobileprovision').hasMatch(mobile),
        isTrue,
        reason:
            'build-mobile.yml must fail fast via ci-sign doctor on the '
            'Runner profile before the archive (gh-1865 option B)');
    expect(
        RegExp(r'ci-sign doctor .*liveactivity\.mobileprovision')
            .hasMatch(mobile),
        isTrue,
        reason:
            'the FaLiveActivity extension signs with its own profile — its '
            'mismatch must also abort BEFORE the archive');

    final macos = read('.github/workflows/build-macos.yml');
    expect(macos, contains('ci-sign install fa-macos'),
        reason:
            'build-macos.yml legs must provision/verify via ci-sign install '
            'macos — per-arch temporary keychains are retired (their '
            'delete+create race was gh-1852)');

    final fastfile = read('flutter_app/fastlane/Fastfile');
    expect(fastfile, contains('sh(ci_sign, "unlock")'),
        reason:
            'the Fastfile build_only lane must explicitly unlock the '
            'persistent keychain before gym — hours can pass between the '
            'workflow\'s install step and the archive, and an unlock is '
            'cheaper and more honest than a job-length auto-lock window '
            '(the gh-1798 window hack is retired with per-job keychains)');
  });

  test('AC4 — the retired additive helper is gone (gh-1866 model v2 → v3)', () {
    expect(File('scripts/keychain_searchlist_add.sh').existsSync(), isFalse,
        reason:
            'scripts/keychain_searchlist_add.sh is retired: the additive '
            'union kept concurrent keychains but made same-subject '
            'certificates ambiguous (gh-1865, run 40455401630). The '
            'persistent-keychain model replaces it — a lingering copy '
            'would invite per-job search-list writes back.');
    for (final path in _keychainSurfaces) {
      expect(read(path), isNot(contains('keychain_searchlist_add')),
          reason:
              '$path still references the retired '
              'keychain_searchlist_add.sh helper — remove the reference '
              'and route signing through ci-sign.');
    }
  });

  test('AC5 — the host provisioning workflow exists and is dispatch-only '
      'on ONE pinned registration', () {
    const provision = '.github/workflows/host-signing-provision.yml';
    final content = read(provision);
    expect(content, contains('workflow_dispatch'),
        reason:
            '$provision must be workflow_dispatch-only — provisioning '
            'touches persistent host state and must never ride a push or '
            'schedule');
    expect(content, contains('[self-hosted, macos-m5]'),
        reason:
            'the provisioning job routes through the macos-m5 pool '
            '(gh-1906: fa-m5-* runner-NAME labels are banned from '
            'workflows — a name pin silently matches zero runners after '
            'the label cleanup). Cross-registration double-provisioning '
            'is safe by construction: ci-sign install is idempotent and '
            'serializes concurrent runs on its lock dir.');
    expect(content, contains('ci-sign install fa-ios'),
        reason: 'the iOS distribution certificate must be provisioned');
    expect(content, contains('ci-sign install fa-macos'),
        reason: 'the macOS distribution certificate must be provisioned');
    expect(content, contains('ci-sign cleanup-legacy'),
        reason:
            'provisioning must sweep the per-job keychains left by the '
            'retired workflows — orphans of those are what produced the '
            'interactive SecurityAgent prompts in the owner\'s session');
  });

  test('AC6 — incident-forensics breadcrumbs keep full issue numbers '
      '(gh-1865 / gh-1866, review thread)', () {
    final typo = RegExp('gh-18' r'6\b');
    final surfaces = <String>{
      'scripts/ci-sign',
      'flutter_app/fastlane/Fastfile',
      'test/ci_sign_host_keychain_guard_test.dart',
      'test/ci_macos_keychain_serialization_guard_test.dart',
      ..._keychainSurfaces,
    };
    for (final path in surfaces) {
      if (!File(path).existsSync()) continue;
      final content = read(path);
      expect(
        typo.allMatches(content),
        isEmpty,
        reason:
            '$path references the issue number missing its final digit '
            '(gh-18${'6'} — a typo; no such issue covers keychain '
            'publishing). Autopsies grep by issue number; a wrong pointer '
            'sends them to the wrong issue. Use gh-1865 / gh-1866.',
      );
    }
  });

  test('AC7 — every ci-sign self-provision creates \$HOME/bin first '
      '(gh-1954: install(1) does not mkdir parents, run 40822964468)', () {
    final workflows = <String>[
      '.github/workflows/build-mobile.yml',
      '.github/workflows/build-macos.yml',
      '.github/workflows/host-signing-provision.yml',
    ];
    for (final wf in workflows) {
      final f = File(wf);
      if (!f.existsSync()) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('install -m 755 scripts/ci-sign')) {
          final context = lines
              .sublist(i > 4 ? i - 4 : 0, i)
              .join('\n');
          expect(
            context,
            contains('mkdir -p "\$HOME/bin"'),
            reason: '$wf:${i + 1} installs ci-sign into \$HOME/bin — the '
                'parent directory must be created first (install(1) never '
                'mkdirs parents; on a fresh runner \$HOME/bin is absent)',
          );
        }
      }
    }
  });

  test('AC8 — every openssl pkcs12 call carries the conditional legacy '
      'provider flag (gh-1954: RC2-40-CBC P12 payloads, run 40840166571)', () {
    final script = File('scripts/ci-sign').readAsStringSync();
    expect(
      script,
      contains('OpenSSL\\ 3*'),
      reason: 'the legacy flag must be conditional on OpenSSL 3.x — '
          'LibreSSL (macOS /usr/bin/openssl) does not know -legacy',
    );
    final lines = script.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains('openssl pkcs12')) {
        expect(
          lines[i],
          contains('\$OSS_LEGACY'),
          reason: 'scripts/ci-sign:${i + 1} — RC2-40-CBC-encrypted P12 '
              '(standard for older Apple exports) is unreadable by '
              'OpenSSL 3.x without the legacy provider: '
              '"inner_evp_generic_fetch:unsupported ... Algorithm '
              '(RC2-40-CBC : 0)" (run 40840166571 probe)',
        );
      }
    }
  });

  test('AC9 — err() writes to stderr in CI too (gh-1954: diagnostics '
      'swallowed by \$(...) capture)', () {
    final script = File('scripts/ci-sign').readAsStringSync();
    final errLine = script
        .split('\n')
        .firstWhere((l) => l.startsWith('err() {'));
    expect(
      errLine,
      contains('::error::ci-sign: \$*" >&2'),
      reason: 'import_fingerprint runs inside NEW_FP="\$(...)" — err() on '
          'stdout is captured into the variable and never reaches the '
          'Actions log (three diagnostic runs printed nothing)',
    );
  });

  test('AC10 — build_only pins the user keychain search list around gym '
      '(gh-1954: xcodebuild resolves identities only via the search list, '
      'concurrent legs rewrite it mid-build, run 40843155381)', () {
    final fastfile = File('flutter_app/fastlane/Fastfile').readAsStringSync();
    final laneStart = fastfile.indexOf('lane :build_only do');
    final laneEnd = fastfile.indexOf('lane :', laneStart + 10);
    final lane = fastfile.substring(laneStart, laneEnd);
    expect(
      lane,
      contains('list-keychains'),
      reason: 'the persistent ci-signing.keychain-db must be VISIBLE to '
          'xcodebuild at gym time — provision-time doctor is not enough '
          '(a concurrent leg can rewrite the list during the 15-minute '
          'compile window)',
    );
    expect(lane, contains('ci-signing.keychain-db'));
    expect(
      lane,
      contains('saved_search_list'),
      reason: 'the pre-gym search list must be restored in ensure — the '
          'pin is a visibility window, not a permanent global change',
    );
  });
}
