// gh-2209 — direct download resolution for the no-sandbox macOS DMG.
//
// The app DMGs ride their own daily release leg while the "Latest" badge
// follows the CLI train, so GitHub's releases/latest/download/… 404s most
// days and the versioned asset names can never be a stable URL. This script
// is the one resolver both surfaces share:
//   - site/index.html   → swaps #macos-download's fallback href (the
//     releases page) for the newest release that actually carries a
//     no-sandbox DMG and renders the resolved version + the other arch's
//     link in the button subtitle;
//   - site/dl/macos/    → the README-facing redirect page ([data-fa-dl]):
//     same resolution, then location.replace to the DMG; on any failure the
//     releases page — the failure mode is never a broken direct link.
//
// Bounded lookback over ONE list-releases call (per_page=50; the unauth API
// budget is 60 req/h per IP), skipped drafts, and a 1h localStorage TTL so
// a page view costs at most one request. Every failure path degrades to
// today's fallback behavior — the fallback href / fallback link are always
// in the DOM first (progressive enhancement; the pre-resolution render
// stays pixel-identical, which the REG goldens pin).
(function () {
  'use strict';

  var REPO = 'IstiN/flutter_agent_harness';
  var RELEASES_PAGE = 'https://github.com/' + REPO + '/releases/latest';
  var API =
    'https://api.github.com/repos/' + REPO + '/releases?per_page=50';
  var LOOKBACK = 50;
  var TTL_MS = 60 * 60 * 1000; // 1h — an unauthenticated 60/h IP budget

  // Stable name first (the AC1 copies the release leg attaches alongside
  // the versioned twin), versioned name second — both carry the same bytes.
  function dmgRe(arch) {
    return new RegExp(
      '^fa-nosandbox-macos-' + arch + '\\.dmg$' +
      '|^fa-macos-nosandbox-' + arch + '-.+\\.dmg$',
      'i',
    );
  }

  // Hint only — both arch links stay visible once resolved (gh-2209 border
  // case). Intel GPUs advertise "Intel …"; Apple Silicon, headless and
  // anything unknown default to arm64 (the majority desktop Mac).
  function archHint() {
    try {
      var gl = document.createElement('canvas').getContext('webgl');
      var ext = gl && gl.getExtension('WEBGL_debug_renderer_info');
      var r = ext ? String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)) : '';
      if (/intel/i.test(r)) return 'x86_64';
    } catch (_) { /* no webgl — keep the arm64 default */ }
    return 'arm64';
  }

  function versionOf(name) {
    var m = /(\d+\.\d+\.\d+)/.exec(name);
    return m ? 'v' + m[1] : '';
  }

  function readCache(arch) {
    try {
      var hit = JSON.parse(localStorage.getItem('fa-dl-macos-' + arch) || 'null');
      if (!hit || !hit.url || Date.now() - hit.ts > TTL_MS) return null;
      return hit;
    } catch (_) {
      return null;
    }
  }

  function writeCache(arch, hit) {
    try {
      localStorage.setItem('fa-dl-macos-' + arch, JSON.stringify(hit));
    } catch (_) { /* private mode — every view resolves live */ }
  }

  // Newest release that carries any no-sandbox DMG, with per-arch download
  // URLs. The unauthenticated list never contains drafts and is newest-
  // first, so the walk IS the bounded lookback (gh-2209 AC4).
  function fetchResolution() {
    return fetch(API).then(function (res) {
      if (!res.ok) throw new Error('releases list HTTP ' + res.status);
      return res.json();
    }).then(function (releases) {
      for (var i = 0; i < releases.length && i < LOOKBACK; i++) {
        if (releases[i].draft) continue;
        var assets = releases[i].assets || [];
        var url = { arm64: '', x86_64: '' };
        var named = '';
        for (var j = 0; j < assets.length; j++) {
          var a = assets[j];
          if (dmgRe('arm64').test(a.name) && !url.arm64) {
            url.arm64 = a.browser_download_url;
            named = named || a.name;
          }
          if (dmgRe('x86_64').test(a.name) && !url.x86_64) {
            url.x86_64 = a.browser_download_url;
            named = named || a.name;
          }
        }
        if (url.arm64 || url.x86_64) {
          return { url: url, version: versionOf(named), ts: 0 };
        }
      }
      return null; // answered, but no app build in the lookback window
    });
  }

  function wire() {
    var btn = document.getElementById('macos-download');
    var sub = document.getElementById('macos-dl-sub');
    var redirect = document.querySelector('[data-fa-dl="macos"]');
    if (!btn && !redirect) return;

    var arch = archHint();
    var cached = readCache(arch);
    var live = cached
      ? Promise.resolve(cached)
      : fetchResolution().then(function (res) {
          if (res) {
            res.ts = Date.now();
            writeCache(arch, res);
          }
          return res;
        });

    live.then(function (res) {
      var alt = arch === 'arm64' ? 'x86_64' : 'arm64';
      var mainUrl = res && (res.url[arch] || res.url[alt]);
      if (res && mainUrl) {
        if (btn) btn.href = mainUrl;
        if (redirect) window.location.replace(mainUrl);
        if (sub) {
          // DOM nodes, not innerHTML — the URLs come off the API response.
          sub.textContent = '';
          sub.append(res.version + ' \u00b7 ' + arch);
          if (res.url[alt] && res.url[alt] !== mainUrl) {
            var a = document.createElement('a');
            a.href = res.url[alt];
            a.textContent = alt === 'x86_64' ? 'Intel build' : 'Apple Silicon build';
            sub.append(' \u00b7 ', a);
          }
          sub.hidden = false;
        }
      } else {
        // The API answered and no recent release carries the app.
        if (redirect) window.location.replace(RELEASES_PAGE);
        if (sub) {
          var link = document.createElement('a');
          link.href = RELEASES_PAGE;
          link.textContent = 'see releases';
          sub.textContent = '';
          sub.append('builds: ', link);
          sub.hidden = false;
        }
      }
    }).catch(function () {
      // Rate-limited, offline, proxy-blocked: keep today's fallback exactly —
      // the releases-page href/link is already in the DOM.
      if (redirect) window.location.replace(RELEASES_PAGE);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', wire);
  } else {
    wire();
  }
})();
