// Reminders live tile — 1x1 launcher widget (~104px square canvas):
// the next 1-2 upcoming reminders from jsr.storage (the list widget.js
// maintains under the 'reminders' key). Display-only: any tap opens the
// full Reminders app. Re-reads storage on the host's 'tile.refresh' event
// (manifest widget.refreshSeconds) so countdown labels stay fresh.
// All colors come from jsr.theme (follows the host's light/dark mode).
//
// Layout note: the 1x1 canvas is TIGHT — no header row, the space goes to
// the reminder titles (they ellipsize, not the header).
(function() {
  var upcoming = []; // [{id, title, atMs}] — future only, soonest first

  function countdownLabel(atMs) {
    var seconds = Math.max(0, Math.round((atMs - Date.now()) / 1000));
    if (seconds < 60) return seconds + 's';
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + 'm';
    var hours = Math.floor(minutes / 60);
    return hours + 'h ' + (minutes % 60) + 'm';
  }

  function reminderRow(reminder) {
    var t = jsr.theme;
    return {
      type: 'row', crossAxisAlignment: 'center', children: [
        { type: 'icon', name: 'notifications', color: t.accent, size: 12 },
        { type: 'sizedBox', width: 5 },
        { type: 'expanded', child: {
          type: 'text', data: reminder.title,
          maxLines: 1, overflow: 'ellipsis',
          style: { color: t.text, fontSize: 11, fontWeight: 'w600' } } },
        { type: 'sizedBox', width: 4 },
        { type: 'text', data: countdownLabel(reminder.atMs),
          style: { color: t.muted, fontSize: 9 } },
      ] };
  }

  function render() {
    // Read jsr.theme fresh on every render — the object is replaced when
    // the host theme changes.
    var t = jsr.theme;
    var body;
    if (!upcoming.length) {
      // Empty state: one calm centered stack, no cramped header.
      body = { type: 'column', mainAxisAlignment: 'center',
        crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'notifications_none', color: t.muted,
            size: 22 },
          { type: 'sizedBox', height: 6 },
          { type: 'text', data: 'No reminders',
            maxLines: 1, overflow: 'ellipsis',
            style: { color: t.muted, fontSize: 11, textAlign: 'center' } },
        ] };
    } else {
      var rows = [];
      var shown = upcoming.slice(0, 2);
      for (var i = 0; i < shown.length; i++) {
        rows.push(reminderRow(shown[i]));
        if (i < shown.length - 1) rows.push({ type: 'sizedBox', height: 6 });
      }
      body = { type: 'column', mainAxisAlignment: 'center',
        crossAxisAlignment: 'stretch', children: rows };
    }
    jsr.render({
      type: 'container',
      padding: [10, 8, 10, 8],
      child: body,
    });
  }

  function load() {
    jsr.storage.get('reminders').then(function(saved) {
      var now = Date.now();
      var list = Array.isArray(saved) ? saved : [];
      upcoming = list
        .filter(function(r) { return r && r.atMs > now; })
        .sort(function(a, b) { return a.atMs - b.atMs; });
      render();
    });
  }

  jsr.onEvent(function(actionId) {
    // Re-read storage when the host asks for a refresh.
    if (actionId === 'tile.refresh') load();
  });
  // Re-render with the new colors when the host flips light/dark mode.
  jsr._onThemeChange = function() { render(); };
  load();
  render();
})();
