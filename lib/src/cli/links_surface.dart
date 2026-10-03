/// Store-referral surfaces rendered from the `links:` config section
/// (issue #691). Two renderers share one source of truth so a link
/// changes in ONE place and propagates everywhere:
///
///  * [renderAppStoreBlockHtml] — the fa1.dev homepage App Store block.
///    The committed `site/index.html` carries the output for the
///    DEFAULT [LinksConfig] between [appStoreBlockStartMarker] and
///    [appStoreBlockEndMarker]; `scripts/regen_site_store_block.dart`
///    re-splices it, and the CI sync test fails when the two drift
///    (a default changed without regenerating the site).
///
///  * [StoreBannerView] — the view-model of the dismissible in-app Get
///    banner (web + macOS, `flutter_app`): every string and URL the
///    widget renders comes from here, so the widget test that flips the
///    config proves the app surface flips with it (AC1).
///
/// Copy on every surface obeys the store compliance gate (issue #643):
/// no ranking or superlative claims — "paid", "free", "coming soon" are
/// facts, not claims.
library;

import 'links_config.dart';

/// Marks the start of the generated App Store block in `site/index.html`.
const appStoreBlockStartMarker =
    '<!-- #app-store-block:start — generated from LinksConfig defaults; '
    'regen: dart run scripts/regen_site_store_block.dart -->';

/// Marks the end of the generated App Store block in `site/index.html`.
const appStoreBlockEndMarker = '<!-- #app-store-block:end -->';

/// Marks the start of the generated App Store header badge (`site/index.html`
/// `.nav-inner`, issue #881) — the persistent, never-hidden money link.
const appStoreHeaderStartMarker =
    '<!-- #app-store-header:start — generated from LinksConfig defaults; '
    'regen: dart run scripts/regen_site_store_block.dart -->';

/// Marks the end of the generated App Store header badge.
const appStoreHeaderEndMarker = '<!-- #app-store-header:end -->';

/// Marks the start of the generated App Store hero CTA (`site/index.html`
/// `.cta-row`, issue #881).
const appStoreHeroStartMarker =
    '<!-- #app-store-hero:start — generated from LinksConfig defaults; '
    'regen: dart run scripts/regen_site_store_block.dart -->';

/// Marks the end of the generated App Store hero CTA.
const appStoreHeroEndMarker = '<!-- #app-store-hero:end -->';

/// The Apple-logo path data shared by every store surface below — one
/// copy instead of four (review gh-881 round 2): a truncated or
/// mis-pasted duplicate only surfaces as a broken glyph in a golden.
const String _appleLogoPath =
    'M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 '
    '0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 '
    '2.43-2.48 3.87-2.48 1.28 0 2.48.88 3.29.88.78 0 2.26-1.07 3.81-.91.65.03 '
    '2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 '
    '4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 '
    '1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 '
    '1.05-3.11z';

/// The inline Apple-logo SVG used by the store buttons: [cssClass] for
/// styling, [size] in px. Adjacent siblings rely on the markup being
/// byte-stable (site sync tests + goldens pin it).
String _appleLogoSvg(String cssClass, int size) =>
    '<svg class="$cssClass" viewBox="0 0 24 24" width="$size" '
    'height="$size" aria-hidden="true"><path fill="currentColor" '
    'd="$_appleLogoPath"/></svg>';

/// Escapes [value] for safe interpolation into a double-quoted HTML
/// attribute (review gh-881 round 2): `links:` is developer-controlled
/// config, but the generator should be safe for any future consumer
/// that renders non-default links.
String _escapeAttr(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Renders the persistent App Store header badge (WITHOUT the markers) for
/// [links] — issue #881 AC2/E1/E4: a compact icon+«App Store» link that
/// stays visible on mobile with the nav collapsed (it lives OUTSIDE
/// `#nav-menu`), and carries ONLY the paid link (`links.appstore`): no
/// TestFlight, no Play, no pile-up when future links land. The per-position
/// referral value is `appstore-header` (AC3).
String renderAppStoreHeaderBadgeHtml(LinksConfig links) => '''
    <a class="store-badge" href="${_escapeAttr(links.appstore)}" target="_blank" rel="noopener" data-store-referral="appstore-header" aria-label="Fa on the App Store">
      ${_appleLogoSvg('store-badge-mark', 14)}
      <span class="store-badge-text">App Store</span>
    </a>''';

/// Renders the App Store hero CTA (WITHOUT the markers) for [links] —
/// issue #881: first in the hero CTA row, primary on mobile; the desktop
/// demotion (CLI audience lands there) is CSS, not markup. Paid link only,
/// referral value `appstore-hero` (AC3).
String renderAppStoreHeroCtaHtml(LinksConfig links) => '''
        <a class="btn btn-primary btn-store btn-store-hero" href="${_escapeAttr(links.appstore)}" target="_blank" rel="noopener" data-store-referral="appstore-hero">
          ${_appleLogoSvg('beta-mark', 15)}
          Download on the App Store
        </a>''';

/// Renders the fa1.dev homepage App Store block (the whole `<section>`
/// element, WITHOUT the markers) for [links].
///
/// AC2: App Store badge + link, paid-release vs free-forever-beta
/// messaging, and an Android slot that renders "coming soon" while
/// `links.play` is unset. AC6: zero superlative claims — the store copy
/// compliance list (issue #643) applies to the site like to the store.
String renderAppStoreBlockHtml(LinksConfig links) {
  final android = links.play == null
      ? '''
      <a class="btn btn-store btn-soon" aria-disabled="true">
        <span class="sooner">Android</span> coming soon
      </a>'''
      : '''
      <a class="btn btn-store" href="${_escapeAttr(links.play!)}" target="_blank" rel="noopener" data-store-referral="play">
        <span class="sooner">Android</span> Get it on Google Play
      </a>''';
  return '''
  <section id="app-store" class="app-store reveal">
    <p class="kicker">Mobile</p>
    <h2>Fa in your pocket.</h2>
    <p class="section-lede">
      The same agent and the same sandbox, from the App Store. The App
      Store release is paid — that is what funds development. The public
      TestFlight beta is free forever and tracks the same code; pick
      whichever fits you. See the app in the store frames on the
      <a href="./app-store/">App Store page</a>.
    </p>
    <div class="store-row">
      <a class="btn btn-primary btn-store" href="${_escapeAttr(links.appstore)}" target="_blank" rel="noopener" data-store-referral="appstore">
        ${_appleLogoSvg('beta-mark', 15)}
        Download on the App Store
      </a>
      <a class="btn btn-beta btn-store" href="${_escapeAttr(links.testflight)}" target="_blank" rel="noopener" data-store-referral="testflight">
        ${_appleLogoSvg('beta-mark', 15)}
        Join the free beta on TestFlight
      </a>
$android
      <a class="btn btn-store" href="${_escapeAttr(links.site)}" data-store-referral="site">fa1.dev</a>
    </div>
    <ul class="pills" aria-label="Release channels">
      <li>App Store — paid release</li>
      <li>TestFlight — free beta, forever</li>
      <li>Android — ${links.play == null ? 'coming soon' : 'on Google Play'}</li>
    </ul>
  </section>''';
}

/// The view-model of the in-app Get banner (AC4): every URL and label
/// the web/macOS banner renders. Built from a [LinksConfig] — the widget
/// never hard-codes a store URL.
final class StoreBannerView {
  const StoreBannerView({
    required this.appstoreUrl,
    required this.testflightUrl,
    required this.playUrl,
    required this.siteUrl,
  });

  /// Resolves the banner for [links].
  factory StoreBannerView.from(LinksConfig links) => StoreBannerView(
    appstoreUrl: links.appstore,
    testflightUrl: links.testflight,
    playUrl: links.play,
    siteUrl: links.site,
  );

  /// Where the primary CTA lands (the paid App Store release).
  final String appstoreUrl;

  /// The free-forever public beta link shown as the secondary line.
  final String testflightUrl;

  /// The Google Play release; null while Android is not live — the
  /// banner then renders "coming soon" for the Android mention.
  final String? playUrl;

  /// The product site link (the banner's "learn more" fallback).
  final String siteUrl;

  /// The Android slot label: the Play CTA while live, the coming-soon
  /// note while `links.play` is unset.
  // TODO(#691): localize the live-Play label (arb `storeBannerAndroidLive`)
  // the moment `links.play` goes live — currently hardcoded English.
  String get androidLabel =>
      playUrl == null ? 'Android: coming soon' : 'Also on Google Play';

  /// Whether the Android slot renders the localized coming-soon note
  /// (surfaces pick their own localized string, not this getter's).
  bool get androidComingSoon => playUrl == null;
}
