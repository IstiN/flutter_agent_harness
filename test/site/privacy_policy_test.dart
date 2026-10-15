// gh-1630 AC6 — the CWS privacy-policy rejection ("Omission of any
// section is not allowed", Purple Nickel): the published policy at
// site/privacy.html must carry ALL NINE mandatory sections in BOTH
// languages, the repo source text (PRIVACY.md) must stay in sync with
// it (AGENTS.md), and the store listing must link the live URL.
//
// Mechanical encoding: every mandatory section carries a data-sec="<key>"
// anchor in the HTML (both language blocks), and PRIVACY.md carries the
// matching heading marker. Keys + markers are the contract below.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// The nine CWS-mandatory sections, keyed.
const mandatorySections = {
  'collect': 'Data we collect',
  'handle': 'How we handle data',
  'storage': 'Data storage',
  'sharing': 'Data sharing',
  'retention': 'Retention & deletion',
  'security': 'Security',
  'children': "Children's privacy",
  'changes': 'Changes to this policy',
  'contact': 'Contact',
};

void main() {
  test('AC6: privacy.html carries all nine mandatory sections in EN and RU',
      () {
    final html = File('site/privacy.html').readAsStringSync();
    for (final lang in const ['en', 'ru']) {
      final block = _languageBlock(html, lang);
      for (final key in mandatorySections.keys) {
        expect(
          block,
          contains('data-sec="$key"'),
          reason: 'the $lang block is missing the mandatory '
              '"${mandatorySections[key]}" section (data-sec="$key") — '
              'CWS rejects omission of any section',
        );
      }
    }
  });

  test('PRIVACY.md (repo source text) carries the same nine sections', () {
    final md = File('PRIVACY.md').readAsStringSync();
    for (final key in mandatorySections.keys) {
      expect(
        md,
        contains('<!-- sec:$key -->'),
        reason: 'PRIVACY.md drifted from site/privacy.html — the '
            '"${mandatorySections[key]}" section marker is missing '
            '(AGENTS.md: keep both in sync)',
      );
    }
  });

  test('AC6: the store listing links the live privacy policy URL', () {
    final listing = File('browser_ext/store/listing.md').readAsStringSync();
    expect(listing, contains('https://fa1.dev/privacy.html'),
        reason: 'the store listing "Privacy policy" field must point at '
            'the live, rendering URL');
  });

  test('F2: the store privacy disclosures no longer justify the five '
      'removed permissions', () {
    final privacy = File('browser_ext/store/privacy.md').readAsStringSync();
    for (final dead in const [
      'contentSettings',
      'downloads',
      'fontSettings',
      'identity',
      'desktopCapture',
    ]) {
      expect(privacy, isNot(contains('**$dead**')),
          reason: '"$dead" is removed from the manifest (gh-1630 F2) — a '
              'justification for a permission the extension no longer '
              'requests invites review questions');
    }
  });
}

/// The text between `<section id="$lang">` and the next `</section>`.
String _languageBlock(String html, String lang) {
  final start = html.indexOf('<section id="$lang"');
  expect(start, greaterThan(-1), reason: 'language block $lang missing');
  final end = html.indexOf('</section>', start);
  expect(end, greaterThan(start), reason: 'language block $lang unterminated');
  return html.substring(start, end);
}
