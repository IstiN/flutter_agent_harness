// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/cli/links_config.dart';
import 'package:flutter_agent_harness/src/cli/links_surface.dart';
import 'package:test/test.dart';

void main() {
  group('renderAppStoreBlockHtml', () {
    test('default config renders all three surfaces and the APK downloads', () {
      final html = renderAppStoreBlockHtml(const LinksConfig());
      expect(html, contains(defaultAppStoreUrl));
      expect(html, contains(defaultTestFlightUrl));
      expect(html, contains(defaultSiteUrl));
      // Android is live via direct APK downloads (issue #1864): two
      // buttons (god + standard), each link once, no coming-soon slot.
      expect(html, contains('href="$defaultApkGodUrl"'));
      expect(html, contains('href="$defaultApkStandardUrl"'));
      expect(html, contains('God mode APK'));
      expect(html, contains('Standard APK'));
      expect(html, contains('data-store-referral="apk-god"'));
      expect(html, contains('data-store-referral="apk-standard"'));
      expect(html, isNot(contains('coming soon')));
      expect(html, isNot(contains('btn-soon')));
      expect(html, isNot(contains('aria-disabled')));
      expect(html, isNot(contains('Get it on Google Play')));
    });

    test('a live play link replaces the APK slot', () {
      const play = 'https://play.google.com/store/apps?id=dev.fa';
      final html = renderAppStoreBlockHtml(const LinksConfig(play: play));
      expect(html, contains(play));
      expect(html, contains('Get it on Google Play'));
      expect(html, contains('on Google Play'));
      expect(html, isNot(contains('app-god-release.apk')));
      expect(html, isNot(contains('app-store-release.apk')));
      expect(html, isNot(contains('btn-soon')));
    });

    test('config values are attribute-escaped — a hostile link cannot '
        'break out of the href', () {
      const hostile = 'https://x.test/a?b=1&c="><script>alert(1)</script>';
      final html = renderAppStoreBlockHtml(
        const LinksConfig(appstore: hostile),
      );
      expect(html, contains('&amp;'));
      expect(html, contains('&quot;&gt;&lt;script&gt;'));
      expect(html, isNot(contains('"><script')));
    });
  });

  group('header badge and hero CTA', () {
    test('the header badge carries ONLY the paid link (no TestFlight)', () {
      final html = renderAppStoreHeaderBadgeHtml(const LinksConfig());
      expect(html, contains(defaultAppStoreUrl));
      expect(html, contains('data-store-referral="appstore-header"'));
      expect(html, isNot(contains(defaultTestFlightUrl)));
    });

    test('the hero CTA carries the paid link with its referral value', () {
      final html = renderAppStoreHeroCtaHtml(const LinksConfig());
      expect(html, contains(defaultAppStoreUrl));
      expect(html, contains('data-store-referral="appstore-hero"'));
      expect(html, isNot(contains(defaultTestFlightUrl)));
    });
  });

  group('StoreBannerView', () {
    test('carries every URL from the config (the widget hard-codes none)', () {
      final view = StoreBannerView.from(
        const LinksConfig(
          appstore: 'https://apps.test/a',
          testflight: 'https://tf.test/j',
          play: 'https://play.test/p',
          site: 'https://site.test',
        ),
      );
      expect(view.appstoreUrl, 'https://apps.test/a');
      expect(view.testflightUrl, 'https://tf.test/j');
      expect(view.playUrl, 'https://play.test/p');
      expect(view.siteUrl, 'https://site.test');
    });

    test('android slot: coming soon while unset, live label after', () {
      final before = StoreBannerView.from(const LinksConfig());
      expect(before.androidComingSoon, isTrue);
      expect(before.androidLabel, 'Android: coming soon');

      final after = StoreBannerView.from(
        const LinksConfig(play: 'https://play.test/p'),
      );
      expect(after.androidComingSoon, isFalse);
      expect(after.androidLabel, 'Also on Google Play');
    });
  });
}
