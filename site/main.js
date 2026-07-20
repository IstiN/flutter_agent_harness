/* Fa landing — terminal demo reel + scroll reveal. No dependencies. */
(function () {
  'use strict';

  /* ── Terminal demo reel ───────────────────────────────────────────── */
  var script = [
    { cls: 'cmd', text: 'fa "summarize the changelog for v0.1.4"', type: true },
    { cls: 'tool', text: '▸ bash    curl -sL …/CHANGELOG.md -o /tmp/cl.md', delay: 550 },
    { cls: 'tool', text: '▸ bash    rg -n "^## \\[0\\.1\\.4\\]" /tmp/cl.md', delay: 750 },
    { cls: 'tool', text: '▸ bash    python3 /tmp/summarize.py', delay: 750 },
    { cls: 'out', text: 'v0.1.4 — prompts extracted to Markdown, 3 fixes, docs.', delay: 950 },
    { cls: 'ok', text: '✓ done — 4 tool calls, 0 servers involved', delay: 650 }
  ];

  var term = document.getElementById('term-lines');
  var reduced = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function lineEl(cls, text) {
    var div = document.createElement('div');
    div.className = cls;
    div.textContent = text;
    return div;
  }

  function renderAll() {
    term.textContent = '';
    script.forEach(function (l) { term.appendChild(lineEl(l.cls, l.text)); });
  }

  function playReel() {
    term.textContent = '';
    var line = script[0];
    var el = lineEl(line.cls, '');
    term.appendChild(el);
    var i = 0;
    (function typeChar() {
      if (i < line.text.length) {
        el.textContent += line.text.charAt(i++);
        setTimeout(typeChar, 34 + Math.random() * 40);
      } else {
        revealNext(1);
      }
    })();
  }

  function revealNext(idx) {
    if (idx >= script.length) {
      setTimeout(playReel, 6000);
      return;
    }
    var line = script[idx];
    setTimeout(function () {
      term.appendChild(lineEl(line.cls, line.text));
      revealNext(idx + 1);
    }, line.delay);
  }

  if (term) {
    if (reduced) { renderAll(); } else { playReel(); }
  }

  /* ── Reveal on scroll ─────────────────────────────────────────────── */
  var revealEls = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window) || reduced) {
    revealEls.forEach(function (el) { el.classList.add('visible'); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08 });
    revealEls.forEach(function (el) { io.observe(el); });
  }

  /* ── Copy buttons ─────────────────────────────────────────────────── */
  function flash(btn, label) {
    btn.textContent = label;
    btn.classList.add('copied');
    setTimeout(function () {
      btn.textContent = 'Copy';
      btn.classList.remove('copied');
    }, 1500);
  }

  function copyText(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { done(true); },
        function () { done(legacyCopy(text)); }
      );
    } else {
      done(legacyCopy(text));
    }
  }

  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { /* no-op */ }
    document.body.removeChild(ta);
    return ok;
  }

  document.querySelectorAll('[data-copy-target]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var target = document.getElementById(btn.getAttribute('data-copy-target'));
      if (!target) { return; }
      copyText(target.textContent.trim(), function (ok) {
        flash(btn, ok ? 'Copied ✓' : 'Failed');
      });
    });
  });

  // Install method dropdown
  var installCommands = {
    'sh-install': { title: 'macOS / Linux / WSL — install', cmd: 'curl -fsSL https://fa1.dev/install.sh | sh' },
    'sh-setup': { title: 'macOS / Linux / WSL — setup wizard', cmd: 'curl -fsSL https://fa1.dev/setup.sh | sh' },
    'ps-install': { title: 'Windows PowerShell — install', cmd: 'irm https://fa1.dev/install.ps1 | iex' },
    'ps-setup': { title: 'Windows PowerShell — setup wizard', cmd: 'irm https://fa1.dev/setup.ps1 | iex' },
    'pub': { title: 'pub.dev direct', cmd: 'dart pub global activate flutter_agent_harness' }
  };
  var installSelect = document.getElementById('install-method');
  var installTitle = document.getElementById('install-command-title');
  var installText = document.getElementById('install-command-text');
  if (installSelect && installTitle && installText) {
    installSelect.addEventListener('change', function () {
      var choice = installCommands[installSelect.value];
      if (!choice) { return; }
      installTitle.textContent = choice.title;
      installText.textContent = choice.cmd;
    });
  }
})();
