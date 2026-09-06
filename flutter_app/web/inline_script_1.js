
    (function () {
      function hideSplash(reason) {
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
  
