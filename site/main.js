/* fah landing — terminal demo reel + scroll reveal. No dependencies. */
(function () {
  'use strict';

  /* ── Terminal demo reel ───────────────────────────────────────────── */
  var script = [
    { cls: 'cmd', text: 'fah "summarize the changelog for v0.1.4"', type: true },
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
})();
