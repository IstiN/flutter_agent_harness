/// gh-2209 — direct-download contract for the macOS no-sandbox DMG, pinned
/// statically (offline), mirroring the landing_deep_links discipline.
///
/// The versioned DMG names can never be stable URLs (the version is in the
/// name), and `releases/latest` follows the CLI train — so the download
/// surface is: a bounded-lookback JS resolver (`site/dl.js`) shared by the
/// landing button and the `fa1.dev/dl/macos/` redirect page, plus
/// stable-named DMG copies attached by the release leg (build-macos.yml).
/// The stable copies are lowercase `fa-` on purpose: ci.yml aggregates
/// `sha256sum fa-*` into the SIGNED SHA256SUMS, so both names ship with a
/// digest line (AC1) and drift-watch manifest coverage stays exact.
///
/// Pinned here (the behavioral half — resolution, walk, cache, redirects —
/// is exercised with recorded API fixtures in scripts/site_mobile_check.mjs,
/// the site-mobile CI leg):
///   AC1  the release leg attaches stable-named DMG copies (both arches) and
///        provenance still signs every fa-* asset;
///   AC2/AC4/AC5  the wiring exists on all three surfaces (button fallback,
///                redirect page, README) and no unguaranteed latest/download
///                deep link leaked into the landing page;
///   AC6  the extension deep link and its doctrine stay untouched.
library;

import 'dart:io';

import 'package:test/test.dart';

const repo = 'https://github.com/IstiN/flutter_agent_harness';
const dlPage = 'https://fa1.dev/dl/macos/';

String read(String path) => File(path).readAsStringSync();

void main() {
  test(
    'README routes the macOS app link through the shared resolver (AC5)',
    () {
      final readme = read('README.md');
      expect(
        readme,
        contains('[macOS app]($dlPage)'),
        reason:
            'the README macOS-app link must use the /dl/macos/ '
            'redirect (one resolver behavior on both surfaces)',
      );
      expect(
        readme,
        isNot(contains('[macOS app]($repo/releases/latest)')),
        reason: 'the old releases-page detour must be gone',
      );
    },
  );

  test(
    'landing page wires the resolver without losing the fallback (AC2/AC4)',
    () {
      final index = read('site/index.html');
      // The shared resolver is loaded (replacing the old releases/latest-only
      // inline fetch — which could never see past the CLI-only Latest).
      expect(index, contains('<script src="dl.js?v=1" defer></script>'));
      expect(
        index,
        isNot(contains('api.github.com')),
        reason:
            'the landing page must not keep its own resolver copy — '
            'dl.js is the single implementation',
      );
      // Progressive enhancement: the fallback href stays in the DOM for the
      // rate-limited / offline / no-JS paths (AC4 failure mode = the release
      // PAGE, never a broken direct link).
      expect(
        RegExp(
          'id="macos-download"[^>]*href="$repo/releases/latest"',
        ).hasMatch(index),
        isTrue,
        reason: 'the macos button keeps a guaranteed-resolvable fallback href',
      );
      expect(
        index,
        contains('id="macos-dl-sub"'),
        reason: 'the subtitle element the resolver fills must exist',
      );
    },
  );

  test(
    'landing page leaks no unguaranteed latest/download deep link (AC6)',
    () {
      final index = read('site/index.html');
      final deepLinks = RegExp(
        'https?://[^"\' <>()+,\t]*/releases/latest/download/[^"\' <>()+,\t]+',
      ).allMatches(index).map((m) => m.group(0)!).toSet();
      expect(deepLinks, isNotEmpty);
      for (final link in deepLinks) {
        expect(
          link,
          contains('fa-extension.zip'),
          reason:
              'every latest/download deep link on the landing page must '
              'stay the tag-train-guaranteed extension zip — daily-leg DMGs '
              'resolve through dl.js, never a latest/download URL',
        );
      }
    },
  );

  test(
    '/dl/macos/ redirect page shares the resolver with a static fallback',
    () {
      final page = read('site/dl/macos/index.html');
      expect(
        page,
        contains('data-fa-dl="macos"'),
        reason: 'the marker dl.js keys the redirect behavior on',
      );
      expect(
        page,
        contains('<script src="/dl.js?v=1" defer></script>'),
        reason:
            'the redirect page must load the SAME resolver as the '
            'landing button (AC5: one behavior on both surfaces)',
      );
      expect(
        page,
        contains('content="noindex"'),
        reason: 'a redirect utility page stays out of search indexes',
      );
      expect(
        page.contains('flutter_agent_harness/releases/latest'),
        isTrue,
        reason: 'the static releases-page link must survive for the no-JS path',
      );
    },
  );

  test(
    'dl.js resolver contract: bounded walk, draft skip, stable names, TTL',
    () {
      final js = read('site/dl.js');
      // ONE bounded list-releases call (the 60/h unauth API budget).
      expect(js, contains('releases?per_page=50'), reason: 'bounded lookback');
      expect(js, contains('LOOKBACK = 50'));
      // Drafts are skipped (published-only walk, gh-2209 border case).
      expect(js, contains('releases[i].draft'), reason: 'draft skip');
      // Both asset name classes match: the AC1 stable copies AND the
      // versioned twins the pipeline ships today (the resolver works before
      // the first stable-named release exists).
      expect(
        js,
        contains("'^fa-nosandbox-macos-' + arch + '\\\\.dmg\$'"),
        reason: 'stable-name matcher',
      );
      expect(
        js,
        contains("'^fa-macos-nosandbox-' + arch + '-.+\\\\.dmg\$'"),
        reason:
            'versioned-twin matcher (works before the first stable '
            'release exists)',
      );
      // AC1 headline: the stable-over-versioned preference is IMPLEMENTED
      // in the pick, never delegated to the release's asset upload order.
      expect(
        js,
        contains('return stable || versioned'),
        reason: 'the pick must state the stable-first priority explicitly',
      );
      expect(
        js,
        contains("pickDmg(assets, 'arm64')"),
        reason: 'both arches resolve through the two-pass pick',
      );
      // Stable-only names carry no version digits — the release tag fills
      // the subtitle instead of a blank version.
      expect(
        js,
        contains('|| releases[i].tag_name'),
        reason: 'subtitle version falls back to the release tag',
      );
      // A corrupted cache entry must expire, never stick forever.
      expect(
        js,
        contains("typeof hit.ts !== 'number'"),
        reason: 'non-numeric cache ts must invalidate the entry',
      );
      // 1h localStorage TTL (rate-limit budget, gh-2209 border case).
      expect(js, contains('TTL_MS = 60 * 60 * 1000'));
      expect(js, contains("'fa-dl-macos-' + arch"));
      // Failure modes never dead-end: the redirect page falls back to the
      // releases page on resolution failure and on an app-less stream.
      expect(js, contains('window.location.replace'));
      expect(js, contains("'builds: '"), reason: 'AC2 app-less subtitle');
      // Arch is a hint only — the other arch's link renders beside the
      // default (gh-2209 border case).
      expect(js, contains('archHint'));
    },
  );

  test('golden captures never race the live release resolver (REG)', () {
    final script = read('scripts/site_mobile_check.mjs');
    // dl.js resolves asynchronously and reveals #macos-dl-sub. Independent
    // bake/check page loads therefore used to capture different DOM states.
    // Golden contexts must stay on the documented progressive-enhancement
    // fallback; behavioral resolution remains covered by recorded fixtures.
    expect(
      script,
      contains(
        "await ctx.route('https://api.github.com/**', (route) => route.abort());",
      ),
      reason: 'full-page desktop goldens must block live release metadata',
    );
    expect(
      script,
      contains(
        "await ctxG.route('https://api.github.com/**', (route) => route.abort());",
      ),
      reason: 'first-viewport goldens must block live release metadata',
    );
  });

  test('release leg attaches stable-named DMG copies (AC1)', () {
    final workflow = read('.github/workflows/build-macos.yml');
    expect(
      workflow,
      contains('cp "\$dmg" "dmgs/fa-nosandbox-macos-arm64.dmg"'),
      reason: 'the arm64 stable copy must be attached by the release leg',
    );
    expect(
      workflow,
      contains('cp "\$dmg" "dmgs/fa-nosandbox-macos-x86_64.dmg"'),
      reason: 'the x86_64 stable copy must be attached by the release leg',
    );
    // The copies flow into the attach through STABLE_COPIES (the existing
    // stable-name plumbing the sandboxed zips already ride).
    expect(
      workflow,
      contains('ASSETS=(\$DMGS \$ZIPS \$MANIFEST "\${STABLE_COPIES[@]}")'),
    );
  });

  test(
    'provenance signs the stable copies too (AC1 SHA256SUMS continuity)',
    () {
      final ci = read('.github/workflows/ci.yml');
      expect(
        ci,
        contains('sha256sum fa-* > SHA256SUMS'),
        reason:
            'the stable copies are lowercase fa-* names precisely so '
            'the provenance aggregation signs both lines — narrowing this '
            'glob silently strips them from the signed manifest',
      );
    },
  );
}
