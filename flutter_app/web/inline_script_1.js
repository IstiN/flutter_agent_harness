
    (function () {
      function hideSplash(reason) {
        // Latch the boot-complete signal first: the fah-done class below is
        // transient (element removed <=500ms later), and an observer stalled
        // by the same busy main thread that delays boot (webkit canvaskit
        // shader compile on loaded CI) can miss that window entirely — the
        // e2e boot wait now reads this latch instead (issue #234).
        window.__fahBootDone = true;
        var splash = document.getElementById('fah-splash');
        if (!splash) return;
        if (reason) console.warn('[fah] splash hidden without first frame: ' + reason);
        splash.classList.add('fah-done');
        splash.addEventListener('transitionend', function () { splash.remove(); }, { once: true });
        // Fallback for reduced motion / missed transitionend.
        setTimeout(function () { splash.remove(); }, 500);
      }
      window.addEventListener('flutter-first-frame', function () { hideSplash(); });
      // Safety net: some engines (seen on Safari) run main() but never fire
      // flutter-first-frame, which left the splash up forever. If the app is
      // alive behind the splash, reveal it after a bounded wait.
      setTimeout(function () { hideSplash('timeout'); }, 12000);
    })();
  
