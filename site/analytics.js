/* Fa landing — click analytics on top of the gtag snippet in index.html.
   Events land in the GA4 property linked to the fa1-mobile Firebase
   project, next to the native app's analytics. Content blockers simply
   skip gtag — every call is guarded, nothing on the page depends on it. */
(function () {
  'use strict';

  function track(name, params) {
    if (typeof window.gtag === 'function') {
      window.gtag('event', name, params || {});
    }
  }

  function linkEvent(href) {
    if (!href || typeof href !== 'string') return null;
    try {
      var url = new URL(href, window.location.origin);
      var h = url.hostname;
      if (h === 'apps.apple.com') return 'appstore_click';
      if (h === 'testflight.apple.com') return 'testflight_click';
      if (h === 'github.com' && url.pathname.indexOf('/IstiN') === 0) return 'github_click';
      if (h === 'pub.dev') return 'pubdev_click';
    } catch (e) {
      // href is a relative path or anchor — not an external link.
    }
    return null;
  }

  document.addEventListener('click', function (event) {
    var el = event.target && event.target.closest
      ? event.target.closest('a[href], button.copy-btn')
      : null;
    if (!el) return;

    if (el.matches('button.copy-btn')) {
      track('install_copy_click', { target: el.getAttribute('data-copy-target') || 'unknown' });
      return;
    }

    var href = el.getAttribute('href') || '';
    var named = linkEvent(href);
    if (named) {
      // Store-referral funnel (issue #691): every store badge/link
      // carries a data-store-referral placement
      // (appstore/testflight/play/site); location stays for continuity
      // with the existing GA4 reports. The counts view is the GA4
      // Events report on appstore_click / testflight_click split by
      // placement + timestamp; the native app reports store_referral
      // with a platform param into the same property, so site vs app
      // splits join in one place.
      var placement = el.getAttribute('data-store-referral');
      var where = placement || el.className || 'link';
      track(named, { location: where, placement: where });
      return;
    }
    // The web demo full-screen links (frame bar + install card).
    if (href.indexOf('./app/') === 0) {
      track('web_fullscreen_click', { location: el.className || 'link' });
      return;
    }
    if (href === '#demo') {
      track('demo_cta_click', { location: el.className || 'link' });
    }
  });

  var method = document.getElementById('install-method');
  if (method) {
    method.addEventListener('change', function () {
      track('install_method_change', { method: method.value });
    });
  }
})();
