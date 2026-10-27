// gh-1866 — the daily-publish cli leg failed (run 40165498619, 2026-10-25):
// build-macos arm64's "Build macOS release" step died with
// `Runner.xcodeproj: error: No certificate for team 'YP9HC3USZ3' matching
// '***' found` despite `1 identity imported.` 10 minutes earlier. The
// autopsy (runs 40165498619 + 40165497544, same morning):
//
//   05:28:36Z  arm64 leg (fa-m5) imports P12 into build-arm64.keychain,
//              then REPLACES the per-user keychain search list with
//              `security list-keychains -d user -s build-arm64.keychain
//              login.keychain-db`
//   05:29:52Z  the CONCURRENT TestFlight leg's build-mobile iOS job
//              (fa-m5-3 — a DIFFERENT runner registration on the SAME
//              host under the SAME user account) imports its P12 into
//              build.keychain and REPLACES the same user-global search
//              list with [build.keychain, login] — evicting
//              build-arm64 75 s after its import
//   05:38:46Z  arm64's first codesign evaluation: "No certificate for
//              team ... found" — keychain on disk, unlocked (4h window),
//              NOT in the search list
//
// gh-1852 fixed the INTRA-workflow variant of this race (build-macos's
// own two matrix legs) with `max-parallel: 1`, but its guard test
// explicitly declared "cross-workflow stomping … out of scope"
// (test/ci_macos_keychain_serialization_guard_test.dart AC2 note) on the
// false assumption that build-mobile's iOS legs "resolve to fa-m5-1 BY
// NAME, concurrency 1 by construction". fa-m5-1/fa-m5-2/fa-m5-3 are
// three registrations on ONE host under ONE user — the daily testflight
// and cli legs dispatch CONCURRENTLY by design (#359), so the stomp
// recurred cross-workflow.
//
// `security default-keychain -s` only moves the default marker; the
// eviction weapon is `security list-keychains -d user -s <fixed list>`,
// which REPLACES the whole per-user list. The fix: the ONLY writer of
// the user search list is scripts/keychain_searchlist_add.sh, which
// UNIONs the current list with {requested keychain, login.keychain-db}
// (never dropping a concurrent job's entry) and verifies the requested
// keychain survived the write, retrying up to 5 times.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of workflow_selfhosted_legs_test.dart /
// ci_macos_keychain_serialization_guard_test.dart):
//
//   AC1  no `.github/workflows/*.yml` and not flutter_app/fastlane/
//        Fastfile may contain a fixed-list `security list-keychains
//        -d user -s` write — the only allowed writer is the additive
//        helper scripts/keychain_searchlist_add.sh.
//   AC2  the helper exists and is additive + self-verifying: it unions
//        the current list (never a literal fixed list), writes it back,
//        and re-reads to confirm the requested keychain survived
//        (retrying) — the survival verify is what turns a concurrent
//        eviction from silent corruption into a loud bounded retry.
//   AC3  every former fixed-list site still maintains the search list
//        THROUGH the helper (nobody "fixed" the guard by deleting the
//        search-list maintenance entirely).
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

/// Workflow YAML and the Fastfile carry long incident comments that
/// legitimately mention the evicting command — the guard targets
/// EXECUTABLE writes, so strip shell/Ruby `#` comments before matching.
String stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

/// Every surface that can write the user-global keychain search list,
/// ENUMERATED rather than hardcoded (gh-1866 review: a hardcoded 3-file
/// list goes green the moment a NEW workflow/script publishes a keychain
/// with a fixed-list write, and the gh-1866 race is back). The additive
/// helper is the sole allowed writer and is therefore excluded from the
/// audit.
List<String> get _searchListSurfaces => <String>[
  ...Directory('.github/workflows')
      .listSync()
      .where((f) => f is File && f.path.endsWith('.yml'))
      .map((f) => f.path),
  'flutter_app/fastlane/Fastfile',
  ...Directory('scripts')
      .listSync()
      .where((f) => f is File && f.path.endsWith('.sh'))
      .map((f) => f.path)
      .where((p) => p != 'scripts/keychain_searchlist_add.sh'),
];

void main() {
  test('AC1 — no fixed-list `security list-keychains -d user -s` writer '
      'outside the additive helper (gh-1866)', () {
    final fixedListWrite = RegExp(r'list-keychains\s+-d\s+user\s+-s');
    for (final path in _searchListSurfaces) {
      final content = stripComments(read(path));
      final matches = fixedListWrite.allMatches(content);
      expect(
        matches,
        isEmpty,
        reason:
            '$path still REPLACES the per-user keychain search list with '
            '`security list-keychains -d user -s ...`. A fixed-list write '
            'evicts every other signing job\'s keychain on the shared '
            'fa-m5 host/user (gh-1866: the concurrent build-mobile iOS '
            'job evicted build-arm64.keychain 75 s after import → '
            '"No certificate for team YP9HC3USZ3 matching ... found"). '
            'Route the write through '
            'scripts/keychain_searchlist_add.sh, which unions the '
            'current list instead of replacing it.',
      );
    }
  });

  test('AC2 — the helper is the single writer and is additive + '
      'self-verifying (gh-1866)', () {
    const helper = 'scripts/keychain_searchlist_add.sh';
    final content = read(helper);

    // It performs the write (it is the ONE allowed writer)…
    expect(
      content,
      contains(RegExp(r'list-keychains\s+-d\s+user\s+-s')),
      reason:
          '$helper must perform the user search-list write — AC1 makes '
          'it the only allowed writer, so if it stops writing the '
          'workflows have no way to publish their keychain.',
    );

    // …additively: the write is fed from the CURRENT list (read back via
    // `security list-keychains -d user`), never from a literal
    // two-element [job-keychain, login] list.
    expect(
      content,
      contains('list_user_keychains'),
      reason:
          '$helper must read the CURRENT search list back '
          '(list_user_keychains) and union with it — a literal fixed '
          'list would re-introduce the gh-1866 eviction.',
    );

    // …and self-verifying: after the write it re-reads and confirms the
    // requested keychain survived, retrying — the survival check is what
    // converts a concurrent eviction into a bounded loud retry instead
    // of a silent codesign death 10 minutes later.
    expect(
      content,
      contains(RegExp(r'grep\s+(-qFx|-qF)\b')),
      reason:
          '$helper must verify its keychain survived the write with a '
          'FIXED-STRING whole-line match (grep -qFx) — the re-read list '
          'entries are literal keychain paths containing `.` chars, and '
          'a regex match would treat those as wildcards (gh-1866 review '
          'thread: the verify is the sole defense against a silent '
          'eviction, so it must not be able to false-positive). It must '
          'also retry on eviction — the gh-1866 failure was silent '
          'until codesign, 10 minutes later.',
    );
    expect(
      content,
      contains(RegExp(r'for attempt in')),
      reason:
          '$helper must retry the union+verify (bounded loop) so two '
          'concurrent writers converge instead of last-writer-wins.',
    );
  });

  test('AC3 — every former fixed-list site still maintains the search '
      'list through the helper (gh-1866)', () {
    // build-macos.yml: import step + TestFlight-PKG re-assert.
    final macos = read('.github/workflows/build-macos.yml');
    expect(
      RegExp('keychain_searchlist_add\\.sh').allMatches(macos).length,
      greaterThanOrEqualTo(2),
      reason:
          'build-macos.yml must call scripts/keychain_searchlist_add.sh '
          'in BOTH the signing-import step and the TestFlight-PKG '
          're-assert block (gh-1866 AC3 — the guard must not be satisfied '
          'by deleting search-list maintenance).',
    );
    // build-mobile.yml: iOS import step.
    final mobile = read('.github/workflows/build-mobile.yml');
    expect(
      mobile,
      contains('keychain_searchlist_add.sh'),
      reason:
          'build-mobile.yml iOS import step must call '
          'scripts/keychain_searchlist_add.sh (it was the evicting '
          'writer in the gh-1866 autopsy — run 40165497544, 05:29:52Z).',
    );
    // Fastfile: lane start, both branches.
    final fastfile = read('flutter_app/fastlane/Fastfile');
    expect(
      RegExp('keychain_searchlist_add\\.sh').allMatches(fastfile).length,
      greaterThanOrEqualTo(2),
      reason:
          'flutter_app/fastlane/Fastfile must call '
          'scripts/keychain_searchlist_add.sh in BOTH the '
          'build.keychain-present and the absent branch of the '
          'build_only lane (both branches replaced the user search '
          'list, gh-1866).',
    );
  });

  test('AC4 — incident-forensics breadcrumbs point at gh-1866, not the '
      'truncated issue number missing its final digit (gh-1866 review '
      'thread 1)', () {
    // These comments/test names are exactly what a future autopsy greps
    // for — a reference to the issue number missing its final digit
    // (no such issue; #186 is ancient and unrelated to keychain
    // publishing) sends it to the wrong issue. The pattern is built by
    // concatenation and this file's prose avoids the contiguous token
    // on purpose: AC4 scans THIS test file too, and a literal would
    // self-match. The trailing \b keeps legitimate gh-1866 / gh-1852 /
    // gh-1798 references legal.
    final typo = RegExp(
      'gh-18'
      r'6\b',
    );
    final surfaces = <String>{
      'scripts/keychain_searchlist_add.sh',
      'flutter_app/fastlane/Fastfile',
      'test/ci_keychain_searchlist_union_guard_test.dart',
      'test/ci_macos_keychain_serialization_guard_test.dart',
      ..._searchListSurfaces,
    };
    for (final path in surfaces) {
      final content = read(path);
      expect(
        typo.allMatches(content),
        isEmpty,
        reason:
            '$path references the issue number missing its final digit '
            '(gh-18${'6'} — a typo for gh-1866, the issue this fix '
            'closes). Incident-forensics comments are grepped by issue '
            'number during future autopsies; a wrong pointer sends the '
            'autopsy to the wrong issue. Use gh-1866 (the word-boundary '
            'regex keeps gh-1866/gh-1852/gh-1798 references legal).',
      );
    }
  });
}
