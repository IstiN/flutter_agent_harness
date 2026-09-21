// Issue #643 — store copy compliance gate (pure Dart, no rendering).
//
// Google Play's Metadata policy bans store-performance / ranking claims
// ("The first mobile agent harness" got the `dev.fa1.app` update
// REJECTED, Sep 17). The policy text applies the ban to title, icon,
// developer name, description, AND screenshots.
//
// This gate runs the banned-phrase regex over every TEXT store surface
// we generate:
//
//   * `kStoreCopy` (test/golden/store_marketing_frame.dart) — the five
//     story frames' headline + subtitle, en + ru, rendered into BOTH the
//     App Store goldens and the Play listing screenshots;
//   * `kPlayFeatureTagline` (test/golden/play_feature_graphic.dart) —
//     the Play feature-graphic tagline, en + ru;
//   * `fastlane/metadata/android/<locale>/{title,short_description,
//     full_description}.txt` — the Play listing texts.
//
// so the next copywriter slip fails CI red, not the Play review.
//
// The icon carries no text (checked by eye; guard test pins its pixels
// via SSIM), so it has no text surface to scan.
//
// Compound-word exception: hyphenated compounds are stripped before
// matching, so the feature wording "privacy-first" passes — a plain
// "first" / "best" / "№1" claim does not.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show LinksConfig, renderAppStoreBlockHtml;
import 'package:flutter_test/flutter_test.dart';

import 'golden/play_feature_graphic.dart';
import 'golden/store_marketing_frame.dart';

/// Banned claim words (Play Metadata policy classes: ranking, store
/// performance, superlatives).
///
/// Explicit letter classes instead of `\b`: ECMAScript `\w` is ASCII-only,
/// so `\b` never fires around Cyrillic.
const _banned = 'first|best|top|leading|most|#1|№1|первый|лучший|самый';

final _bannedPhrase = RegExp(
  '(?<![A-Za-zА-Яа-яЁё0-9])(?:$_banned)(?![A-Za-zА-Яа-яЁё0-9])',
  caseSensitive: false,
);

/// Hyphenated compounds ("privacy-first", "state-of-the-art") — the
/// sanctioned exception class.
final _compound = RegExp(r'[A-Za-zА-Яа-яЁё0-9]+(?:-[A-Za-zА-Яа-яЁё0-9]+)+');

/// The banned phrases found in [text] after stripping hyphenated
/// compounds. Empty = compliant.
List<String> bannedPhraseViolations(String text) => _bannedPhrase
    .allMatches(text.replaceAll(_compound, ' '))
    .map((m) => m.group(0)!)
    .toList();

/// Scans [text] for banned claim phrases, appending a named problem line
/// per hit to [problems] (so one run reports every surface, not the
/// first).
void _scan(String surface, String locale, String text, List<String> problems) {
  for (final phrase in bannedPhraseViolations(text)) {
    problems.add(
      '$surface [$locale]: "$phrase" — Play Metadata policy bans '
      'ranking/store-performance claims',
    );
  }
}

/// The Play listing text files every locale must carry.
const _listingFiles = [
  'title.txt',
  'short_description.txt',
  'full_description.txt',
];

void main() {
  test('sanity: the gate bans plain claims and spares the compound', () {
    expect(
      bannedPhraseViolations('The first mobile agent harness'),
      isNotEmpty,
    );
    expect(bannedPhraseViolations('Первый мобильный ИИ-агент'), isNotEmpty);
    expect(bannedPhraseViolations('privacy-first analytics'), isEmpty);
    expect(
      bannedPhraseViolations('A mobile agent harness — describe an app'),
      isEmpty,
    );
  });

  test('kStoreCopy story frames are claim-free (en + ru)', () {
    final problems = <String>[];
    kStoreCopy.forEach((screen, copyByLang) {
      copyByLang.forEach((lang, copy) {
        final (headline, subtitle) = copy;
        _scan('kStoreCopy/$screen headline', lang, headline, problems);
        _scan('kStoreCopy/$screen subtitle', lang, subtitle, problems);
      });
    });
    expect(problems, isEmpty);
  });

  test('kPlayFeatureTagline is claim-free (en + ru)', () {
    final problems = <String>[];
    kPlayFeatureTagline.forEach(
      (lang, tagline) => _scan('kPlayFeatureTagline', lang, tagline, problems),
    );
    expect(problems, isEmpty);
  });

  test('Play listing texts are claim-free (en-US + ru-RU)', () {
    final problems = <String>[];
    for (final locale in ['en-US', 'ru-RU']) {
      for (final file in _listingFiles) {
        final path = 'fastlane/metadata/android/$locale/$file';
        _scan(path, locale, File(path).readAsStringSync(), problems);
      }
    }
    expect(problems, isEmpty);
  });

  // Issue #691: the store-referral surfaces (in-app Get banner strings,
  // the site App Store block, the store-frames page) are store marketing
  // too — the compliance list applies to them exactly like to the store
  // listings.
  test('Get banner + fa1.dev store surfaces are claim-free (issue #691)', () {
    final problems = <String>[];
    for (final arb in ['lib/l10n/app_en.arb', 'lib/l10n/app_ru.arb']) {
      final text = File(arb).readAsStringSync();
      // Only the banner's own keys — one long JSON blob per line would
      // smear context across unrelated strings.
      for (final line in text.split('\n')) {
        if (line.trimLeft().startsWith('"storeBanner')) {
          _scan('$arb storeBanner*', arb, line, problems);
        }
      }
    }
    final block = renderAppStoreBlockHtml(const LinksConfig());
    _scan('site app-store block', 'en', block, problems);
    final framesPage = File('../site/app-store/index.html');
    if (framesPage.existsSync()) {
      _scan(
        'site app-store page',
        'en',
        framesPage.readAsStringSync(),
        problems,
      );
    }
    expect(problems, isEmpty);
  });
}
