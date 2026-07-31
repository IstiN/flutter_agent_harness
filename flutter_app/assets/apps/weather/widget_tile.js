// Weather live tile — 4x2 launcher widget (four icon slots wide, two
// high; ~272x168 px canvas on a phone): condition glyph + city on the
// left, big temp + description on the right. Display-only: any tap opens
// the full
// Weather app. Shares storage.json with widget.js (the 'city' key), so the
// tile follows the city the user picked in the app. Refetches on the host's
// 'tile.refresh' event (manifest widget.refreshSeconds) and caches the last
// payload in storage for an instant first paint.
// All colors come from jsr.theme (follows the host's light/dark mode).
(function() {
  var city = 'London';
  var last = null; // {tempC, areaName, desc, icon}

  function iconForDesc(desc) {
    var d = desc.toLowerCase();
    if (d.indexOf('sun') >= 0 || d.indexOf('clear') >= 0) return '☀️';
    if (d.indexOf('part') >= 0) return '⛅';
    if (d.indexOf('cloud') >= 0 || d.indexOf('overcast') >= 0) return '☁️';
    if (d.indexOf('rain') >= 0 || d.indexOf('drizzle') >= 0) return '🌧️';
    if (d.indexOf('snow') >= 0 || d.indexOf('blizzard') >= 0) return '❄️';
    if (d.indexOf('thunder') >= 0) return '⛈️';
    if (d.indexOf('fog') >= 0 || d.indexOf('mist') >= 0) return '🌫️';
    return '🌡️';
  }

  function render() {
    // Read jsr.theme fresh on every render — the object is replaced when
    // the host theme changes.
    var t = jsr.theme;
    // Medium-widget structure (like the iOS weather widget): a compact
    // header row on top (glyph + city), the data row pinned to the bottom
    // (big temp left, condition right) — no dead middle space.
    jsr.render({
      type: 'container',
      padding: [16, 12, 16, 12],
      child: {
        type: 'column', crossAxisAlignment: 'stretch', children: [
          { type: 'row', crossAxisAlignment: 'center', children: [
            { type: 'text', data: last ? last.icon : '🌡️',
              style: { fontSize: 20 } },
            { type: 'sizedBox', width: 6 },
            { type: 'expanded', child: {
              type: 'text', data: last ? last.areaName : city,
              maxLines: 1, overflow: 'ellipsis',
              style: { color: t.text, fontSize: 13, fontWeight: 'w600' } } },
          ] },
          { type: 'expanded', child: { type: 'sizedBox' } },
          { type: 'row', crossAxisAlignment: 'end', children: [
            { type: 'text', data: last && last.tempC != null ? last.tempC + '°' : '—',
              style: { color: t.text, fontSize: 40, fontWeight: 'w700' } },
            { type: 'expanded', child: { type: 'sizedBox' } },
            { type: 'text', data: last ? last.desc : 'Loading…',
              maxLines: 1, overflow: 'ellipsis',
              style: { color: t.muted, fontSize: 12 } },
          ] },
        ] },
    });
  }

  function showOffline() {
    if (last) return; // keep the last good payload instead
    last = { icon: '⚠️', areaName: city, tempC: null, desc: 'Offline' };
    render();
  }

  function load() {
    var url = 'https://wttr.in/' + encodeURIComponent(city) + '?format=j1';
    var done = false;
    // The host fetch has no timeout of its own — a silently hanging
    // request must not strand the tile on 'Loading…' forever.
    setTimeout(function() {
      if (!done) { done = true; showOffline(); }
    }, 8000);
    jsr.fetchJson(url).then(function(data) {
      if (done) return;
      done = true;
      if (!data || data.__error) {
        // Never strand the tile on 'Loading…' forever: with no cached
        // payload show an honest offline state (kept on the next refresh).
        showOffline();
        return; // keep the last good payload
      }
      var cur = data.current_condition[0];
      var area = data.nearest_area[0];
      last = {
        icon: iconForDesc(cur.weatherDesc[0].value),
        areaName: area.areaName[0].value,
        tempC: cur.temp_C,
        desc: cur.weatherDesc[0].value,
      };
      jsr.storage.set('tileWeather', last);
      render();
    });
  }

  jsr.onEvent(function(actionId) {
    // The host fires 'tile.refresh' on the manifest's refreshSeconds
    // cadence — refetch and repaint.
    if (actionId === 'tile.refresh') load();
  });
  // Re-render with the new colors when the host flips light/dark mode.
  jsr._onThemeChange = function() { render(); };
  jsr.storage.get('city').then(function(saved) {
    if (saved) city = saved;
    jsr.storage.get('tileWeather').then(function(cached) {
      if (cached && cached.tempC) { last = cached; render(); }
      load();
    });
  });
  render();
})();
