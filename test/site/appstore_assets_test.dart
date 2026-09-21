/// The fa1.dev App Store surfaces (issue #691) — CI pins so the site can
/// never drift from the single source of truth:
///
///  * the homepage App Store block (between the generated markers in
///    site/index.html) is byte-equal to what `renderAppStoreBlockHtml`
///    emits for the DEFAULT `links:` config — change a default without
///    running `dart run scripts/regen_site_store_block.dart` and this
///    fails (AC1: one change, every surface);
///  * the store-frames page (site/app-store/index.html) links the same
///    default URLs and carries store-referral placements;
///  * the frames page shows EXACTLY the committed en/ios store goldens —
///    no hand-copied PNGs, no stray images, none missing (AC3), and the
///    Pages deploy copies them from the golden tree (pinned below);
///  * no superlative claims on either surface (AC6 — the issue #643
///    compliance list applies to the site and banners too).
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  final index = File('site/index.html').readAsStringSync();
  final framesPage = File('site/app-store/index.html').readAsStringSync();
  final pagesWorkflow = File('.github/workflows/pages.yml').readAsStringSync();
  final goldenDir = Directory('flutter_app/test/goldens/store/en/ios');

  /// The banned-claim list from the store copy gate (issue #643) —
  /// applied here to the site surfaces. Hyphenated compounds
  /// (`margin-top` in the page CSS) are stripped first, exactly like
  /// the store gate.
  final compound = RegExp(r'[A-Za-zА-Яа-яЁё0-9]+(?:-[A-Za-zА-Яа-яЁё0-9]+)+');
  final banned = RegExp(
    '(?<![A-Za-zА-Яа-яЁё0-9])(first|best|top|leading|most|#1|№1|'
    'первый|лучший|самый)(?![A-Za-zА-Яа-яЁё0-9])',
    caseSensitive: false,
  );

  List<String> violations(String text) => banned
      .allMatches(text.replaceAll(compound, ' '))
      .map((m) => m.group(0)!)
      .toList();

  test('the committed homepage block is the generated one (AC1)', () {
    final start = index.indexOf(appStoreBlockStartMarker);
    final end = index.indexOf(appStoreBlockEndMarker);
    expect(start, greaterThan(0), reason: 'start marker missing');
    expect(end, greaterThan(start), reason: 'end marker missing');
    final committed = index
        .substring(start + appStoreBlockStartMarker.length, end)
        .trim();
    expect(
      committed,
      renderAppStoreBlockHtml(const LinksConfig()).trim(),
      reason:
          'site/index.html App Store block drifted from the defaults — '
          'run `dart run scripts/regen_site_store_block.dart`',
    );
  });

  test('the frames page links the default store URLs (AC2)', () {
    expect(framesPage, contains('href="$defaultAppStoreUrl"'));
    expect(framesPage, contains('href="$defaultTestFlightUrl"'));
    expect(framesPage, contains('coming soon'));
    expect(framesPage, isNot(contains('play.google.com')));
  });

  test('store-referral placements ride every badge (AC5)', () {
    expect(framesPage, contains('data-store-referral="appstore"'));
    expect(framesPage, contains('data-store-referral="testflight"'));
    expect(
      renderAppStoreBlockHtml(const LinksConfig()),
      contains('data-store-referral="appstore"'),
    );
  });

  test('the frames page shows exactly the en/ios goldens (AC3)', () {
    final goldens = goldenDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(goldens, isNotEmpty, reason: 'golden tree missing');
    final shown = RegExp(
      r'src="img/([^"]+)"',
    ).allMatches(framesPage).map((m) => m.group(1)!).toSet();
    expect(shown, goldens, reason: 'site frames and store goldens differ');
  });

  test('the Pages deploy regenerates the frames from the goldens (AC3)', () {
    expect(
      pagesWorkflow,
      contains('flutter_app/test/goldens/store/en/ios'),
      reason:
          'the assemble step must copy the store goldens into the site '
          'artifact — hand-copied PNGs are how the site drifts',
    );
    expect(pagesWorkflow, contains('build/pages/root/app-store/img'));
  });

  test('no superlative claims on the store surfaces (AC6)', () {
    expect(violations(framesPage), isEmpty);
    expect(violations(renderAppStoreBlockHtml(const LinksConfig())), isEmpty);
  });
}
