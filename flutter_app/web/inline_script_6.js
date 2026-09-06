
    window.litertLmReady = (async () => {
      const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.12.1/+esm');
      window.Engine = m.Engine;
      return m.Engine;
    })();
  
