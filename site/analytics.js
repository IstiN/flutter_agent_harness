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
    if (!href) return null;
    if (href.indexOf('testflight.apple.com') !== -1) return 'testflight_click';
    if (href.indexOf('github.com/IstiN') !== -1) return 'github_click';
    if (href.indexOf('pub.dev') !== -1) return 'pubdev_click';
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
      track(named, { location: el.className || 'link' });
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
